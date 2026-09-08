//! macOS only: remember whichever app was frontmost right before GameNight's
//! Back/Select press brought jumpy to the front, so switching away again
//! reactivates it — the same transition as Cmd+Tabbing back, including
//! landing on that app's own fullscreen Space again if it has one.
//!
//! No window-level or collection-behavior tricks here (see
//! `gamenight-overlay`'s history for that dead end) — jumpy is a completely
//! ordinary app. Bringing it to the front and going fullscreen is handled by
//! mutating Bevy's own `Window` component (`mode`/`focused`); this module
//! only deals with the one thing Bevy has no concept of: the *other* app.

use objc2::msg_send;
use objc2::runtime::AnyObject;

/// `NSApplicationActivateIgnoringOtherApps`.
const NS_APPLICATION_ACTIVATE_IGNORING_OTHER_APPS: u64 = 1 << 1;
/// `NSApplicationActivateAllWindows` — bring our windows forward too, not just
/// the app. Without it, activating while our only window sits on its own
/// fullscreen Space makes the menu bar say "jumpy" and changes nothing else:
/// the party keeps looking at the desktop with the lobby one swipe away. This
/// is the pair of options a Dock-icon click uses, and a Dock click has always
/// switched Spaces correctly.
const NS_APPLICATION_ACTIVATE_ALL_WINDOWS: u64 = 1 << 0;

/// `NSApplicationActivationPolicyRegular` — in the Dock and the app switcher.
const NS_ACTIVATION_POLICY_REGULAR: i64 = 0;
/// `NSApplicationActivationPolicyAccessory` — running, but not something the
/// party can Cmd+Tab into. Hiding alone isn't enough: a hidden app still sits
/// in the switcher, so a warmed game looks like a second copy of the lobby
/// you can tab to, one of which has no screen.
const NS_ACTIVATION_POLICY_ACCESSORY: i64 = 1;

pub struct PreviousApp(*mut AnyObject);

// SAFETY: only ever touched from `global_input_system`, which Bevy never runs
// concurrently with itself (it's the sole accessor of the `GlobalInput`
// resource this lives in) — needed because Bevy resources must be
// `Send + Sync`, which a raw `*mut AnyObject` isn't by default.
unsafe impl Send for PreviousApp {}
unsafe impl Sync for PreviousApp {}

pub fn capture_frontmost_app() -> Option<PreviousApp> {
    unsafe {
        let workspace_cls = objc2::runtime::AnyClass::get(c"NSWorkspace")?;
        let workspace: *mut AnyObject = msg_send![workspace_cls, sharedWorkspace];
        let app: *mut AnyObject = msg_send![workspace, frontmostApplication];
        if app.is_null() {
            return None;
        }
        let pid: i32 = msg_send![app, processIdentifier];
        if pid == std::process::id() as i32 {
            return None; // we're already frontmost; nothing to switch back to
        }
        let _: *mut AnyObject = msg_send![app, retain];
        Some(PreviousApp(app))
    }
}

impl PreviousApp {
    pub fn reactivate(self) {
        unsafe {
            let _: bool =
                msg_send![self.0, activateWithOptions: NS_APPLICATION_ACTIVATE_IGNORING_OTHER_APPS];
            let _: () = msg_send![self.0, release];
        }
    }
}

/// Take every window of ours off the screen, exactly as Cmd+H does.
///
/// A warmed game is a whole running copy of the title — its own window, its
/// own audio — and on macOS that window is *visible*: the party gets a black
/// rectangle sitting on top of the lobby, and two soundtracks at once.
/// Warming is only worth anything if it's invisible until it's wanted.
///
/// Returns whether we are hidden now. Asking to hide before the window
/// exists does nothing at all — and `Prepare` arrives while the process is
/// still starting up — so the caller re-asserts this each frame until it
/// takes, rather than firing once and trusting it.
pub fn hide_self() -> bool {
    unsafe {
        let Some(app_cls) = objc2::runtime::AnyClass::get(c"NSApplication") else {
            return false;
        };
        let app: *mut AnyObject = msg_send![app_cls, sharedApplication];
        if app.is_null() {
            return false;
        }
        let hidden: bool = msg_send![app, isHidden];
        if hidden {
            return true;
        }
        let nil: *mut AnyObject = std::ptr::null_mut();
        let _: () = msg_send![app, hide: nil];
        // Out of the switcher too, not just off the screen.
        let _: bool = msg_send![app, setActivationPolicy: NS_ACTIVATION_POLICY_ACCESSORY];
        msg_send![app, isHidden]
    }
}

/// `NSApplicationPresentationAutoHideMenuBar | NSApplicationPresentationAutoHideDock`.
/// The lobby fills the screen with an ordinary borderless window rather than
/// a native fullscreen one (see `fill_the_screen_system`), so the menu bar
/// and Dock have to be asked to get out of the way separately — otherwise
/// they sit on top of the party's screen. Presentation options apply only
/// while we're the active app, so a game taking over restores them for free.
const NS_PRESENTATION_AUTO_HIDE_DOCK: u64 = 1 << 0;
const NS_PRESENTATION_AUTO_HIDE_MENU_BAR: u64 = 1 << 2;

/// Ask the menu bar and Dock to auto-hide while we're the active app.
pub fn hide_system_chrome() {
    unsafe {
        let Some(app_cls) = objc2::runtime::AnyClass::get(c"NSApplication") else {
            return;
        };
        let app: *mut AnyObject = msg_send![app_cls, sharedApplication];
        if app.is_null() {
            return;
        }
        let options: u64 = NS_PRESENTATION_AUTO_HIDE_MENU_BAR | NS_PRESENTATION_AUTO_HIDE_DOCK;
        let _: () = msg_send![app, setPresentationOptions: options];
    }
}

/// Whether AppKit considers *this application* the active one.
///
/// Not the same question as bevy's `Window::focused`, which is about a window
/// and is happily `true` for a window whose app was never activated — a lobby
/// the daemon launched as a background child process is exactly that. macOS
/// refuses `toggleFullScreen:` for an inactive app, and winit's refusal path
/// (`window_did_fail_to_enter_fullscreen`) re-locks a mutex it already holds:
/// the main thread deadlocks and the lobby is frozen for the rest of the
/// night — alive, on nobody's screen, deaf to every message the daemon sends
/// it. So this is the gate for asking at all.
pub fn app_is_active() -> bool {
    unsafe {
        let Some(app_cls) = objc2::runtime::AnyClass::get(c"NSApplication") else {
            return false;
        };
        let app: *mut AnyObject = msg_send![app_cls, sharedApplication];
        if app.is_null() {
            return false;
        }
        msg_send![app, isActive]
    }
}

pub fn bring_self_to_front() {
    unsafe {
        if let Some(app_cls) = objc2::runtime::AnyClass::get(c"NSApplication") {
            let app: *mut AnyObject = msg_send![app_cls, sharedApplication];
            if !app.is_null() {
                // Back into the Dock and the switcher, and back on screen —
                // a warmed game demoted and hid itself while it waited (see
                // `hide_self`), and activating a hidden app leaves it hidden.
                let _: bool = msg_send![app, setActivationPolicy: NS_ACTIVATION_POLICY_REGULAR];
                let nil: *mut AnyObject = std::ptr::null_mut();
                let _: () = msg_send![app, unhide: nil];
            }
        }
        // Activate via `NSRunningApplication`, not `[NSApp activate]`.
        //
        // Since macOS 14 an app may only take focus if the frontmost app
        // cooperates, and a warmed game asking from the background is exactly
        // the case the OS declines: `Start` arrived, the game logged that it
        // was taking the screen, and nothing appeared. (The older
        // `activateIgnoringOtherApps:` on NSApplication is no use either —
        // objc2's return-type check rejects it whichever type we declare,
        // which once turned every launch into a panic and a spawn loop.)
        //
        // `activateWithOptions:` still honours
        // `NSApplicationActivateIgnoringOtherApps`, and it's the same call
        // `PreviousApp::reactivate` has been using successfully all along.
        if let Some(running_cls) = objc2::runtime::AnyClass::get(c"NSRunningApplication") {
            let me: *mut AnyObject = msg_send![running_cls, currentApplication];
            if !me.is_null() {
                let options: u64 = NS_APPLICATION_ACTIVATE_IGNORING_OTHER_APPS
                    | NS_APPLICATION_ACTIVATE_ALL_WINDOWS;
                let _: bool = msg_send![me, activateWithOptions: options];
            }
        }
        // We fill the screen with a borderless window, not a fullscreen one
        // (see `gamenight::fill_the_screen_system`), so the menu bar and Dock
        // don't get out of the way on their own. Asked here rather than once
        // at startup because presentation options only hold while we're the
        // active app — this is exactly the moment we become it.
        hide_system_chrome();
        // Activating the *app* is not enough when our window is fullscreen.
        //
        // A fullscreen window lives on a Space of its own, and becoming the
        // frontmost application does not bring that Space forward: the menu
        // bar said "jumpy" while the party sat looking at the desktop, with
        // the lobby running one swipe away. Ordering the window front is what
        // switches Spaces — it's what clicking our Dock icon does.
        //
        // Every visible window rather than `mainWindow`/`keyWindow`: neither
        // is reliably set for a window on another Space, and this process has
        // exactly one real window anyway. Hidden ones are skipped so nothing
        // the app deliberately put away comes back with it.
        order_visible_windows_front();
    }
}

fn order_visible_windows_front() {
    unsafe {
        let Some(app_cls) = objc2::runtime::AnyClass::get(c"NSApplication") else {
            return;
        };
        let app: *mut AnyObject = msg_send![app_cls, sharedApplication];
        if app.is_null() {
            return;
        }
        let windows: *mut AnyObject = msg_send![app, windows];
        if windows.is_null() {
            return;
        }
        let count: usize = msg_send![windows, count];
        let nil: *mut AnyObject = std::ptr::null_mut();
        for i in 0..count {
            let window: *mut AnyObject = msg_send![windows, objectAtIndex: i];
            if window.is_null() {
                continue;
            }
            let visible: bool = msg_send![window, isVisible];
            if !visible {
                continue;
            }
            let _: () = msg_send![window, makeKeyAndOrderFront: nil];
        }
    }
}
