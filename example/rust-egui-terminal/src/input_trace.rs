//! Opt-in input timing. Never records selected text, paths, Lua or command output.
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
static INPUT_SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

pub(crate) fn key_arrived() {
    if enabled() {
        INPUT_SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    }
}

pub(crate) fn enabled() -> bool {
    TRACE
        .get_or_init(|| {
            let path = std::env::var_os("GHOSTTY_INPUT_TRACE")?;
            let mut file = match std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
            {
                Ok(file) => file,
                Err(error) => {
                    eprintln!("Cannot open input timing log: {error}");
                    return None;
                }
            };
            let (sender, receiver) = mpsc::sync_channel::<String>(4096);
            std::thread::Builder::new()
                .name("input-trace".into())
                .spawn(move || {
                    let _ = writeln!(file, "input_trace pid={} version=1", std::process::id());
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
        "t_ms={:.3} stage={stage} item={item} elapsed_ms={:.3} input_seq={} {detail}",
        trace.started.elapsed().as_secs_f64() * 1000.0,
        started.map_or(0.0, |t| t.elapsed().as_secs_f64() * 1000.0),
        INPUT_SEQUENCE.load(std::sync::atomic::Ordering::Relaxed),
    ));
}
