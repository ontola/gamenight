use crate::prelude::*;

pub fn game_plugin(game: &mut Game) {
    game.systems.add_before_system(update_fullscreen);
}

fn update_fullscreen(game: &mut Game) {
    #[cfg(target_arch = "wasm32")]
    let _ = game;

    #[cfg(not(target_arch = "wasm32"))]
    {
        // macOS refuses `toggleFullScreen:` for a window that isn't up yet or
        // an app that isn't frontmost, and winit's failure path
        // (`window_did_fail_to_enter_fullscreen`) re-locks a mutex it already
        // holds — the main thread deadlocks on a black window.
        //
        // Two guards, because there are two ways to be refused:
        //
        // * Let the window settle for a few frames after creation.
        // * Only ask while we actually have focus. A GameNight lobby is
        //   launched *by the daemon* as a child process and so starts in the
        //   background; asking then either fails or hands the app a
        //   fullscreen Space nobody switches to, which looks exactly like a
        //   window that won't open.
        {
            use std::sync::atomic::{AtomicU32, Ordering};
            static FRAMES: AtomicU32 = AtomicU32::new(0);
            const SETTLE_FRAMES: u32 = 10;
            if FRAMES.fetch_add(1, Ordering::Relaxed) < SETTLE_FRAMES {
                return;
            }
        }
        if !game.shared_resource::<Window>().focused {
            return;
        }
        // ...and `focused` is not the guard it looks like: it is about a
        // *window*, and reads `true` for a window whose *application* was
        // never activated. Even asking AppKit who is active only narrows the
        // window — the check is a snapshot, and the transition it guards is
        // asynchronous. macOS can still refuse (another app is fullscreen,
        // focus moved while the animation ran), and a refusal is not a no-op:
        // winit's `window_did_fail_to_enter_fullscreen` re-locks a mutex it
        // already holds and the main thread never comes back. The lobby spends
        // the rest of the night frozen — no screen, deaf to the daemon, with
        // a game already running and no way back to the party.
        //
        // So the lobby doesn't play this game at all: it fills the screen with
        // a borderless window instead (`gamenight::fill_the_screen_system`),
        // which asks the window server for nothing it can decline. F11 still
        // toggles real fullscreen for an ordinary `cargo run` of jumpy.
        if crate::gamenight::is_lobby() {
            return;
        }

        let storage = game.shared_resource_cell::<Storage>().unwrap();
        let mut storage = storage.borrow_mut().unwrap();
        let window = game.shared_resource_cell::<Window>().unwrap();
        let mut window = window.borrow_mut().unwrap();
        let keyboard = game.shared_resource::<KeyboardInputs>();

        let f11_pressed = keyboard
            .key_events
            .iter()
            .any(|x| x.key_code == Set(KeyCode::F11) && x.button_state.pressed());

        let settings = storage.get_mut::<Settings>().unwrap();
        if f11_pressed {
            settings.fullscreen = !settings.fullscreen;
        }
        window.fullscreen = settings.fullscreen;
    }
}
