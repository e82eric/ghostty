//! The GPU context threaded through the UI. Terminal code receives it to
//! create panes and release their frames; only the app and painter use wgpu.
pub(crate) use crate::gpu::bridge::Context;

thread_local! {
    // Native window of the window being updated, for panes it creates.
    static CURRENT_WINDOW: std::cell::Cell<*mut std::ffi::c_void> =
        const { std::cell::Cell::new(std::ptr::null_mut()) };
}

/// Record the native window (an HWND on Windows) that panes created from
/// now on belong to.
pub(crate) fn set_current_window(window: *mut std::ffi::c_void) {
    CURRENT_WINDOW.with(|current| current.set(window));
}

pub(crate) fn current_window() -> *mut std::ffi::c_void {
    CURRENT_WINDOW.with(|current| current.get())
}
