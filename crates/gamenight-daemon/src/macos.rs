//! macOS only: keep a launch from stealing the screen.
//!
//! Warming is the whole promise — the next game is already loaded behind the
//! one being played — and on macOS launching a process breaks it, because the
//! window server brings a newly launched application to the front the moment
//! it puts up a window. The party is mid-match and the game they haven't
//! asked for yet takes the screen.
//!
//! No game-side setting fixes this. Godot's `display/window/size/no_focus`
//! keeps the *window* from becoming key and the *application* is activated
//! anyway (measured: frontmost went from the editor to the game with the flag
//! set). It isn't about the window at all, so nothing about the window can
//! answer it.
//!
//! What does answer it is remembering who was in front and putting them back
//! — the same thing the party would do by hand, done for them, by the process
//! that caused the problem. The daemon is the launcher, so the daemon cleans
//! up after its own launches.

use objc2::msg_send;
use objc2::runtime::AnyObject;

/// `NSApplicationActivateIgnoringOtherApps | NSApplicationActivateAllWindows`
/// — the same pair a Dock click uses, which is what makes this land on an app
/// whose window is on another Space.
const ACTIVATE_OPTIONS: u64 = (1 << 1) | (1 << 0);

/// Whoever is frontmost right now, as a process id.
///
/// A pid rather than a retained `NSRunningApplication`: this is handed to a
/// tokio task that outlives the call, and a pid is `Send` without any promises
/// about which thread eventually looks at it. It can go stale — the app may
/// have quit by the time we put it back — which `restore_frontmost` treats as
/// "nothing to do".
pub fn frontmost_pid() -> Option<i32> {
    unsafe {
        let workspace_cls = objc2::runtime::AnyClass::get(c"NSWorkspace")?;
        let workspace: *mut AnyObject = msg_send![workspace_cls, sharedWorkspace];
        if workspace.is_null() {
            return None;
        }
        let app: *mut AnyObject = msg_send![workspace, frontmostApplication];
        if app.is_null() {
            return None;
        }
        let pid: i32 = msg_send![app, processIdentifier];
        (pid > 0).then_some(pid)
    }
}

/// Put `pid` back in front, if it's still around and isn't already there.
///
/// Best-effort by design: this is undoing an activation nobody asked for, so
/// failing to undo it is no worse than not having tried. Never an error.
pub fn restore_frontmost(pid: i32) {
    unsafe {
        let Some(running_cls) = objc2::runtime::AnyClass::get(c"NSRunningApplication") else {
            return;
        };
        let app: *mut AnyObject =
            msg_send![running_cls, runningApplicationWithProcessIdentifier: pid];
        if app.is_null() {
            return; // quit in the meantime; whatever is in front now is fine
        }
        let already: bool = msg_send![app, isActive];
        if already {
            return;
        }
        let _: bool = msg_send![app, activateWithOptions: ACTIVATE_OPTIONS];
    }
}
