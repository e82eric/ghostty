//! Opt-in preview timing. Never records selected text, paths, Lua or command output.
use std::{
    io::Write,
    sync::{OnceLock, mpsc},
    time::Instant,
};

struct Trace {
    started: Instant,
    sender: mpsc::SyncSender<String>,
}
static TRACE: OnceLock<Option<Trace>> = OnceLock::new();

/// Deliberately changes GPU scheduling; enabled only for a traced diagnostic run.
pub(crate) fn gpu_sync_enabled() -> bool {
    static GPU_SYNC: OnceLock<bool> = OnceLock::new();
    enabled()
        && *GPU_SYNC.get_or_init(|| {
            std::env::var("GHOSTTY_PREVIEW_TRACE_GPU_SYNC")
                .ok()
                .as_deref()
                == Some("1")
        })
}

pub(crate) fn enabled() -> bool {
    TRACE
        .get_or_init(|| {
            let path = std::env::var_os("GHOSTTY_PREVIEW_TRACE")?;
            let mut file = match std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
            {
                Ok(file) => file,
                Err(error) => {
                    eprintln!("Cannot open preview timing log: {error}");
                    return None;
                }
            };
            let (sender, receiver) = mpsc::sync_channel::<String>(4096);
            std::thread::Builder::new()
                .name("preview-trace".into())
                .spawn(move || {
                    let _ = writeln!(file, "preview_trace pid={} version=8", std::process::id());
                    for line in receiver {
                        let _ = writeln!(file, "{line}");
                    }
                })
                .ok()?;
            Some(Trace {
                started: Instant::now(),
                sender,
            })
        })
        .is_some()
}

pub(crate) fn start() -> Option<Instant> {
    enabled().then(Instant::now)
}

pub(crate) fn record(stage: &str, item: usize, started: Option<Instant>, detail: &str) {
    if !enabled() {
        return;
    }
    let trace = TRACE.get().unwrap().as_ref().unwrap();
    // Bounded, nonblocking logging: diagnostics must not stall UI or preview work.
    let _ = trace.sender.try_send(format!(
        "t_ms={:.3} stage={stage} item={item} elapsed_ms={:.3} {detail}",
        trace.started.elapsed().as_secs_f64() * 1000.0,
        started.map_or(0.0, |t| t.elapsed().as_secs_f64() * 1000.0),
    ));
}

pub(crate) fn provider<T: 'static>(
    inner: std::sync::Arc<dyn nfm_egui::PreviewProvider<T>>,
) -> std::sync::Arc<dyn nfm_egui::PreviewProvider<T>> {
    if enabled() {
        std::sync::Arc::new(TimedProvider(inner))
    } else {
        inner
    }
}
struct TimedProvider<T>(std::sync::Arc<dyn nfm_egui::PreviewProvider<T>>);
impl<T: 'static> nfm_egui::PreviewProvider<T> for TimedProvider<T> {
    fn preview(
        &self,
        request: nfm_egui::PreviewRequest<T>,
        cancel: nfm_egui::Cancellation,
    ) -> Result<nfm_egui::Preview, String> {
        self.preview_viewport(request, cancel)
            .map(|page| page.document)
    }
    fn preview_viewport(
        &self,
        request: nfm_egui::PreviewRequest<T>,
        cancel: nfm_egui::Cancellation,
    ) -> Result<nfm_egui::preview::PreviewViewport, String> {
        let started = start();
        let index = request.selection.index;
        record("nfm_preview_started", index, None, "");
        let result = self.0.preview_viewport(request, cancel.clone());
        record(
            "nfm_preview_finished",
            index,
            started,
            if cancel.is_cancelled() {
                "cancelled=true"
            } else if result.is_ok() {
                "ok=true"
            } else {
                "ok=false"
            },
        );
        result
    }
    fn copy_document(
        &self,
        version: u64,
        index: usize,
    ) -> Result<Option<std::sync::Arc<dyn nfm_egui::copy_document::CopyDocument>>, String> {
        self.0.copy_document(version, index)
    }
    fn page_step(&self, rows: usize) -> usize {
        self.0.page_step(rows)
    }
}
