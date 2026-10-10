//! Observe egui-winit's existing IME profiling scopes without changing its behavior.
use std::{
    collections::HashMap,
    sync::{
        Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::Instant,
};
use tracing::{
    Metadata, Subscriber,
    span::{Attributes, Id, Record},
};

fn stage(name: &str) -> Option<&'static str> {
    match name {
        "set_ime_allowed" => Some("platform_ime_allowed"),
        "set_ime_cursor_area" => Some("platform_ime_cursor_area"),
        "accesskit" => Some("platform_accesskit"),
        _ => None,
    }
}

#[derive(Default)]
struct PlatformTiming {
    next_id: AtomicU64,
    spans: Mutex<HashMap<u64, (&'static str, Option<Instant>)>>,
}
impl Subscriber for PlatformTiming {
    fn enabled(&self, metadata: &Metadata<'_>) -> bool {
        metadata.target().starts_with("egui_winit") && stage(metadata.name()).is_some()
    }
    fn new_span(&self, attributes: &Attributes<'_>) -> Id {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed) + 1;
        if let Some(stage) = stage(attributes.metadata().name()) {
            self.spans.lock().unwrap().insert(id, (stage, None));
        }
        Id::from_u64(id)
    }
    fn record(&self, _: &Id, _: &Record<'_>) {}
    fn record_follows_from(&self, _: &Id, _: &Id) {}
    fn event(&self, _: &tracing::Event<'_>) {}
    fn enter(&self, id: &Id) {
        if let Some((_, started)) = self.spans.lock().unwrap().get_mut(&id.into_u64()) {
            *started = Some(Instant::now());
        }
    }
    fn exit(&self, id: &Id) {
        let timing = self
            .spans
            .lock()
            .unwrap()
            .get_mut(&id.into_u64())
            .map(|(stage, started)| (*stage, started.take()));
        if let Some((stage, Some(started))) = timing {
            super::record(stage, 0, Some(started), "");
        }
    }
    fn try_close(&self, id: Id) -> bool {
        self.spans.lock().unwrap().remove(&id.into_u64());
        true
    }
}

pub(super) fn observe<R>(run: impl FnOnce() -> R) -> R {
    if !super::enabled() {
        return run();
    }
    static DISPATCH: OnceLock<tracing::Dispatch> = OnceLock::new();
    let dispatch = DISPATCH.get_or_init(|| tracing::Dispatch::new(PlatformTiming::default()));
    tracing::dispatcher::with_default(dispatch, run)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn observes_only_platform_scopes_and_releases_timing_state() {
        let timing = std::sync::Arc::new(PlatformTiming::default());
        let dispatch = tracing::Dispatch::new(timing.clone());
        tracing::dispatcher::with_default(&dispatch, || {
            let unrelated = tracing::span!(target: "egui_winit", tracing::Level::INFO, "unrelated");
            assert!(unrelated.is_disabled());
            {
                let span = tracing::span!(target: "egui_winit", tracing::Level::INFO, "set_ime_cursor_area");
                let _entered = span.enter();
                let spans = timing.spans.lock().unwrap();
                assert_eq!(spans.len(), 1);
                let (stage, started) = spans.values().next().unwrap();
                assert_eq!(*stage, "platform_ime_cursor_area");
                assert!(started.is_some());
            }
            assert!(timing.spans.lock().unwrap().is_empty());
        });
    }
}
