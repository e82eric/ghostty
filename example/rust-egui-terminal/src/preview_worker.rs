//! A configuration-owned Lua state, accessed only by its preview thread.
use mlua::{Lua, LuaSerdeExt};
use nfm_egui::Cancellation;
use nfm_preview_file::resolved::PreviewPlan;
use std::{collections::BTreeMap, sync::mpsc, time::Duration};

#[derive(Clone)]
pub(crate) struct ConfigSource(pub String, pub String);
#[derive(Clone)]
pub(crate) struct FactoryContext(pub serde_json::Value);
#[derive(Clone)]
struct RequestContext(Cancellation, usize, usize);

#[derive(serde::Serialize)]
pub(crate) struct DirectoryItem {
    name: String,
    is_directory: bool,
}

pub(crate) fn directory_items(
    path: &std::path::Path,
    limit: usize,
    cancelled: impl Fn() -> bool,
) -> Result<Option<Vec<DirectoryItem>>, String> {
    let check = || {
        if cancelled() {
            Err("Directory preview cancelled".to_owned())
        } else {
            Ok(())
        }
    };
    check()?;
    let metadata = std::fs::metadata(path).map_err(|error| error.to_string())?;
    if !metadata.is_dir() {
        return Ok(None);
    }
    let mut items = Vec::new();
    let mut bytes = 0usize;
    for entry in std::fs::read_dir(path).map_err(|error| error.to_string())? {
        check()?;
        let entry = entry.map_err(|error| error.to_string())?;
        let name = entry.file_name().to_string_lossy().into_owned();
        bytes = bytes.saturating_add(name.len() + 2);
        if bytes > limit || items.len() >= 100_000 {
            return Err("Directory listing exceeds preview limits".into());
        }
        items.push(DirectoryItem {
            name,
            is_directory: entry
                .file_type()
                .map_err(|error| error.to_string())?
                .is_dir(),
        });
    }
    check()?;
    items.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(Some(items))
}
// Bound outstanding jobs, including jobs whose OS process creation has not
// returned yet. Cancellation releases Lua without abandoning child cleanup.
static COMMAND_JOBS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
fn command_job<T: Send + 'static>(
    cancelled: impl Fn() -> bool,
    job: impl FnOnce() -> T + Send + 'static,
) -> Result<T, String> {
    use std::sync::atomic::Ordering;
    loop {
        if cancelled() {
            return Err("Preview command cancelled or timed out".into());
        }
        if COMMAND_JOBS
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < 4).then_some(count + 1)
            })
            .is_ok()
        {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    let (tx, rx) = mpsc::sync_channel(1);
    if let Err(error) = std::thread::Builder::new()
        .name("preview-command".into())
        .spawn(move || {
            struct Slot;
            impl Drop for Slot {
                fn drop(&mut self) {
                    COMMAND_JOBS.fetch_sub(1, Ordering::AcqRel);
                }
            }
            let _slot = Slot;
            let _ = tx.send(job());
        })
    {
        COMMAND_JOBS.fetch_sub(1, Ordering::AcqRel);
        return Err(error.to_string());
    }
    loop {
        if cancelled() {
            return Err("Preview command cancelled or timed out".into());
        }
        match rx.recv_timeout(Duration::from_millis(5)) {
            Ok(result) => return Ok(result),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err("Preview command worker stopped".into());
            }
        }
    }
}
pub(crate) fn install_ui_api(lua: &Lua) -> mlua::Result<()> {
    let helpers = lua.create_table()?;
    for name in ["run", "measure", "directory_items"] {
        helpers.set(
            name,
            lua.create_function(|_, _: mlua::MultiValue| -> mlua::Result<()> {
                Err(mlua::Error::external(
                    "preview helpers are only available inside a Dynamic preview resolver",
                ))
            })?,
        )?;
    }
    lua.globals().set("preview", helpers)
}
struct Request {
    index: usize,
    queued_at: Option<std::time::Instant>,
    text: String,
    value: String,
    filesystem: bool,
    params: BTreeMap<String, String>,
    max_bytes: usize,
    max_lines: usize,
    cancel: Cancellation,
    reply: mpsc::Sender<Result<Option<PreviewPlan>, String>>,
}
#[derive(Clone)]
pub(crate) struct Worker(mpsc::Sender<Request>);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancelled_command_releases_caller_before_job_finishes() {
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (done_tx, done_rx) = mpsc::channel();
        let cancelled = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = cancelled.clone();
        let caller = std::thread::spawn(move || {
            command_job(
                || flag.load(std::sync::atomic::Ordering::Acquire),
                move || {
                    entered_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    done_tx.send(()).unwrap();
                },
            )
        });
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        cancelled.store(true, std::sync::atomic::Ordering::Release);
        // Joining must not require releasing the blocked job.
        assert!(caller.join().unwrap().is_err());
        assert_eq!(command_job(|| false, || 42).unwrap(), 42);
        release_tx.send(()).unwrap();
        done_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    }

    #[test]
    fn workers_initialize_without_requests_on_load_and_reload() {
        let root =
            std::env::temp_dir().join(format!("ghostty-preview-init-{}", std::process::id()));
        for generation in ["startup", "reload"] {
            let path = root.join(generation);
            std::fs::create_dir_all(&path).unwrap();
            let quoted_path =
                serde_json::to_string(&path.to_string_lossy().replace('\\', "/")).unwrap();
            let source = format!(
                "local path = {quoted_path} .. '/' .. tostring({{}}):gsub('[^%w]', ''); local f = assert(io.open(path, 'w')); f:write('{generation}'); f:close(); return {{pickers={{x={{preview={{resolve=function() return nil end}}}}}}}}"
            );
            let _worker = Worker::new(ConfigSource(source, "@init-test".into()), "x".into(), None);
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            loop {
                let completed = std::fs::read_dir(&path)
                    .unwrap()
                    .filter_map(Result::ok)
                    .filter(|entry| {
                        std::fs::read_to_string(entry.path()).ok().as_deref() == Some(generation)
                    })
                    .count();
                if completed == 4 {
                    break;
                }
                assert!(
                    std::time::Instant::now() < deadline,
                    "worker waited for a preview request"
                );
                std::thread::sleep(Duration::from_millis(5));
            }
        }
        std::fs::remove_dir_all(root).unwrap();
    }
}

impl Worker {
    pub(crate) fn new(source: ConfigSource, name: String, context: Option<FactoryContext>) -> Self {
        let (tx, rx) = mpsc::channel::<Request>();
        // Each lane owns its Lua state. A blocked native io call retains only
        // that lane, allowing newer selections to run on another one.
        let rx = std::sync::Arc::new(std::sync::Mutex::new(rx));
        for lane in 0..4 {
            let rx = rx.clone();
            let source = source.clone();
            let name = name.clone();
            let context = context.clone();
            std::thread::Builder::new()
                .name(format!("lua-preview-{lane}"))
                .spawn(move || {
                    let lua = std::rc::Rc::new(Lua::new());
                    let initialized = (|| -> mlua::Result<_> {
                        install_helpers(&lua)?;
                        // Configuration initialization has its own deadline, independent
                        // of selection requests. Start as soon as the worker is created.
                        let started = std::time::Instant::now();
                        lua.set_hook(
                            mlua::HookTriggers::new().every_nth_instruction(10_000),
                            move |_, _| {
                                if started.elapsed() > Duration::from_secs(5) {
                                    Err(mlua::Error::external("Preview configuration timed out"))
                                } else {
                                    Ok(())
                                }
                            },
                        );
                        let root: mlua::Table = lua.load(&source.0).set_name(&source.1).eval()?;
                        let (group, key) = name
                            .strip_prefix("builtin.")
                            .map_or(("pickers", name.as_str()), |key| ("builtin_pickers", key));
                        let entries: mlua::Table = root.get(group)?;
                        // Build factory options once, retaining the resulting closure environment.
                        let entry: mlua::Value = entries.get(key)?;
                        let definition = match entry {
                            mlua::Value::Table(table) => table,
                            mlua::Value::Function(factory) => factory.call::<_, mlua::Table>(
                                lua.to_value(
                                    &context
                                        .as_ref()
                                        .ok_or_else(|| {
                                            mlua::Error::external("Missing picker factory context")
                                        })?
                                        .0,
                                )?,
                            )?,
                            _ => return Err(mlua::Error::external("Missing preview definition")),
                        };
                        let preview: mlua::Table = definition.get("preview")?;
                        let callback: mlua::Function = preview.get("resolve")?;
                        lua.create_registry_value(callback)
                    })();
                    lua.remove_hook();
                    if let Err(error) = &initialized {
                        eprintln!("picker {name} preview initialization: {error}");
                    }
                    loop {
                        // Release the receiver lock before any Lua or host IO.
                        let request = match rx.lock().unwrap().recv() {
                            Ok(request) => request,
                            Err(_) => break,
                        };
                        if request.cancel.is_cancelled() {
                            crate::preview_trace::record(
                                "lua_queue_cancelled",
                                request.index,
                                request.queued_at,
                                "",
                            );
                            continue;
                        }
                        crate::preview_trace::record(
                            "lua_started",
                            request.index,
                            request.queued_at,
                            "",
                        );
                        let lua_started = crate::preview_trace::start();
                        let result = (|| -> Result<_, String> {
                            let entry = initialized.as_ref().map_err(ToString::to_string)?;
                            install(
                                &lua,
                                request.cancel.clone(),
                                request.max_bytes,
                                request.index,
                            )
                            .map_err(|e| e.to_string())?;
                            let callback: mlua::Function =
                                lua.registry_value(entry).map_err(|e| e.to_string())?;
                            let resolver = crate::lua_callbacks::PreviewResolver {
                                lua: lua.clone(),
                                key: lua
                                    .create_registry_value(callback)
                                    .map_err(|e| e.to_string())?,
                                name: name.clone(),
                                worker: None,
                            };
                            resolver.call(
                                &request.text,
                                &request.value,
                                request.filesystem,
                                &request.params,
                                request.max_bytes,
                                request.max_lines,
                            )
                        })();
                        lua.remove_hook();
                        crate::preview_trace::record(
                            "lua_finished",
                            request.index,
                            lua_started,
                            if result.is_ok() {
                                "ok=true"
                            } else {
                                "ok=false"
                            },
                        );
                        let _ = request.reply.send(result);
                    }
                })
                .expect("start Lua preview worker");
        }
        Self(tx)
    }
    pub(crate) fn resolve(
        &self,
        index: usize,
        text: String,
        value: String,
        filesystem: bool,
        params: BTreeMap<String, String>,
        max_bytes: usize,
        max_lines: usize,
        cancel: Cancellation,
    ) -> Result<Option<PreviewPlan>, String> {
        let (reply, rx) = mpsc::channel();
        self.0
            .send(Request {
                index,
                queued_at: crate::preview_trace::start(),
                text,
                value,
                filesystem,
                params,
                max_bytes,
                max_lines,
                cancel: cancel.clone(),
                reply,
            })
            .map_err(|_| "Lua preview worker stopped")?;
        loop {
            if cancel.is_cancelled() {
                crate::preview_trace::record("nfm_lua_wait_cancelled", index, None, "");
                return Err("Preview cancelled".into());
            }
            match rx.recv_timeout(Duration::from_millis(20)) {
                Ok(result) => return result,
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(_) => return Err("Lua preview worker stopped".into()),
            }
        }
    }
}
fn install(lua: &Lua, cancel: Cancellation, limit: usize, index: usize) -> mlua::Result<()> {
    lua.set_app_data(RequestContext(cancel.clone(), limit, index));
    let hook_cancel = cancel.clone();
    lua.set_hook(
        mlua::HookTriggers::new().every_nth_instruction(10_000),
        move |_, _| {
            if hook_cancel.is_cancelled() {
                Err(mlua::Error::external("Preview cancelled"))
            } else {
                Ok(())
            }
        },
    );
    install_helpers(lua)
}
fn install_helpers(lua: &Lua) -> mlua::Result<()> {
    if lua
        .named_registry_value::<bool>("preview.helpers")
        .unwrap_or(false)
    {
        return Ok(());
    }
    let helpers = lua.create_table()?;
    helpers.set(
        "directory_items",
        lua.create_function(|lua, path: String| {
            let RequestContext(cancel, limit, index) = lua
                .app_data_ref::<RequestContext>()
                .ok_or_else(|| {
                    mlua::Error::external("preview.directory_items requires a preview request")
                })?
                .clone();
            let started = crate::preview_trace::start();
            let result =
                directory_items(std::path::Path::new(&path), limit, || cancel.is_cancelled());
            crate::preview_trace::record(
                "directory",
                index,
                started,
                if result.is_ok() {
                    "ok=true"
                } else {
                    "ok=false"
                },
            );
            match result.map_err(mlua::Error::external)? {
                Some(items) => lua.to_value(&items),
                None => Ok(mlua::Value::Nil),
            }
        })?,
    )?;
    helpers.set(
        "measure",
        lua.create_function(|lua, (stage, callback): (String, mlua::Function)| {
            if !matches!(stage.as_str(), "file_read" | "directory" | "media") {
                return Err(mlua::Error::external("Unknown preview timing stage"));
            }
            let started = crate::preview_trace::start();
            let index = lua
                .app_data_ref::<RequestContext>()
                .map_or(0, |context| context.2);
            let result = callback.call::<_, mlua::MultiValue>(());
            crate::preview_trace::record(
                &stage,
                index,
                started,
                if result.is_ok() {
                    "ok=true"
                } else {
                    "ok=false"
                },
            );
            result
        })?,
    )?;
    helpers.set(
        "run",
        lua.create_function(move |lua, spec: mlua::Table| {
            let RequestContext(cancel, limit, index) = lua
                .app_data_ref::<RequestContext>()
                .ok_or_else(|| {
                    mlua::Error::external("preview.run is only available during a preview request")
                })?
                .clone();
            let args: Vec<String> = lua.from_value(spec.get("args")?)?;
            if args.is_empty() || args.iter().any(|a| a.contains('\0')) {
                return Err(mlua::Error::external("Invalid command arguments"));
            }
            let timeout = spec
                .get::<_, Option<u64>>("timeout_ms")?
                .unwrap_or(5000)
                .clamp(1, 120_000);
            let mut command = nfm_preview_file::resolved::CommandSpec::new(&args[0]);
            command.arguments = args[1..].to_vec();
            command.working_directory = spec.get::<_, Option<String>>("cwd")?.map(Into::into);
            command.output_limit = limit;
            let started = std::time::Instant::now();
            let trace_started = crate::preview_trace::start();
            let cancellation_seen =
                std::sync::Arc::new(std::sync::OnceLock::<std::time::Instant>::new());
            if crate::preview_trace::enabled() {
                let observed_cancel = cancellation_seen.clone();
                command.observer = Some(nfm_preview_command::CommandObserver::new(move |event| {
                    use nfm_preview_command::CommandEvent;
                    match event {
                        CommandEvent::SpawnStarted => {
                            crate::preview_trace::record("command_spawn_started", index, None, "")
                        }
                        CommandEvent::Spawned => crate::preview_trace::record(
                            "command_spawn_finished",
                            index,
                            trace_started,
                            "",
                        ),
                        CommandEvent::FirstStdout => crate::preview_trace::record(
                            "command_first_stdout",
                            index,
                            trace_started,
                            "",
                        ),
                        // NFM sends Finished after its child guard has terminated/reaped
                        // the child and released the command's local resources.
                        CommandEvent::Finished => crate::preview_trace::record(
                            "command_cleanup_finished",
                            index,
                            observed_cancel.get().copied(),
                            if observed_cancel.get().is_some() {
                                "cancelled=true"
                            } else {
                                "cancelled=false"
                            },
                        ),
                    }
                }));
            }
            let job_cancel = cancel.clone();
            let result = command_job(
                || cancel.is_cancelled() || started.elapsed() >= Duration::from_millis(timeout),
                move || {
                    let cancel = job_cancel;
                    let result = nfm_preview_file::resolved::run(
                        &command,
                        || {
                            let cancelled = cancel.is_cancelled();
                            let timed_out = started.elapsed() >= Duration::from_millis(timeout);
                            if (cancelled || timed_out)
                                && crate::preview_trace::enabled()
                                && cancellation_seen.set(std::time::Instant::now()).is_ok()
                            {
                                crate::preview_trace::record(
                                    "command_cancel_observed",
                                    index,
                                    trace_started,
                                    if cancelled {
                                        "reason=selection"
                                    } else {
                                        "reason=timeout"
                                    },
                                );
                            }
                            cancelled || timed_out
                        },
                        |_, _| true,
                    );
                    crate::preview_trace::record(
                        "command_execution",
                        index,
                        trace_started,
                        if result.is_ok() {
                            "ok=true"
                        } else {
                            "ok=false"
                        },
                    );
                    result
                },
            )
            .map_err(mlua::Error::external)?;
            let result = result.map_err(mlua::Error::external)?;
            if cancel.is_cancelled() || started.elapsed() >= Duration::from_millis(timeout) {
                return Err(mlua::Error::external(
                    "Preview command cancelled or timed out",
                ));
            }
            if result.truncated {
                return Err(mlua::Error::external("Command exceeds max_bytes"));
            }
            let output = lua.create_table()?;
            output.set("stdout", lua.create_string(&result.stdout)?)?;
            output.set("stderr", lua.create_string(&result.stderr)?)?;
            output.set("exit_code", result.status.code())?;
            Ok(output)
        })?,
    )?;
    lua.globals().set("preview", helpers)?;
    let ghostty = lua.create_table()?;
    ghostty.set(
        "json_parse",
        lua.create_function(|lua, text: String| {
            let value: serde_json::Value =
                serde_json::from_str(&text).map_err(mlua::Error::external)?;
            lua.to_value(&value)
        })?,
    )?;
    ghostty.set(
        "json_encode_pretty",
        lua.create_function(|lua, value: mlua::Value| {
            let value: serde_json::Value = lua.from_value(value)?;
            serde_json::to_string_pretty(&value).map_err(mlua::Error::external)
        })?,
    )?;
    lua.globals().set("ghostty", ghostty)?;
    lua.set_named_registry_value("preview.helpers", true)
}
