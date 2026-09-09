//! Dev-only: two virtual gamepads driven by the keyboard, so the GameNight
//! lobby can be exercised on a laptop with no controllers plugged in.
//!
//! This synthesises `GamepadEvent`s rather than mapping the keyboard to a
//! player directly. Everything downstream — joining the party
//! (`GlobalInput::join_pad`), the per-player menu, the seat's
//! `ControlSource::Gamepad`, character movement — is driven by gamepad
//! events and never learns the difference. A keyboard-to-player shortcut
//! would have skipped the join/seat path, which is exactly the part worth
//! testing.
//!
//! Off unless `LOBBY_DEV_PADS=1` is set, so a normal build behaves normally.
//!
//! ## Why this is a bones system and not a bevy one
//!
//! The obvious implementation — a bevy `PreUpdate` system reading
//! `Input<KeyCode>` and pushing into the shared `GamepadInputs` — silently
//! half-works, and it's worth recording why. The renderer owns a single
//! `PreUpdate` `.chain()`:
//!
//! ```text
//! setup_egui → get_bones_input.pipe(insert_bones_input) → … → egui_input_hook
//! ```
//!
//! `insert_bones_input` *replaces* `GamepadInputs` wholesale, and
//! `egui_input_hook` is what ends up calling `collect_player_controls`,
//! which turns events into `PlayerControl`s. So synthetic events are only
//! seen if they land strictly between those two — and both systems are
//! private, so no external `.after()`/`.before()` can name them.
//!
//! A bevy system therefore lands outside the chain and gets wiped, which
//! produces a confusing split: joining still works (the join path reads the
//! *previous* frame's leftover events) while movement never does (the
//! collector reads the freshly-emptied list). Hooking the same egui input
//! hook that calls `collect_player_controls` puts the injection at exactly
//! the right point, with no ordering guesswork.
//!
//! Two other details:
//!
//! * The pads have to be indices `0` and `1`. `PlayerInputCollector`'s
//!   control map is pre-populated for `Gamepad(0..MAX_PLAYERS)` only
//!   (`src/input.rs`), so an out-of-range index would join a seat and then
//!   never move. A real controller plugged in at the same time shares an
//!   index with a virtual pad — fine on a dev machine, but don't do both.
//! * Bones' `KeyboardEvent`s are already press/release *edges*, which maps
//!   one-to-one onto how a real pad reports. `apply_inputs_inner` treats
//!   "no event for this button this frame" as "unchanged", so holding a key
//!   needs no repeat and a release needs its own `0.0` event.

use crate::prelude::*;

/// Env var that turns the virtual pads on.
const ENABLE_VAR: &str = "LOBBY_DEV_PADS";

/// `(key, pad index, button)`.
///
/// Movement uses the D-pad because `movement_alt` binds the D-pad to the
/// same actions (see `game.yaml`), and a digital button is the honest
/// analogue of a key — a stick axis would mean inventing values and
/// fighting the join deadzone in `global_input_system`.
/// Note that several keys may map to the same button — two jump keys per
/// player, and two ways to open a menu — but no key appears twice, which
/// `events_for` relies on (it takes the first match).
///
/// `Up`/`DPadUp` is deliberately *not* also bound to jump: in an open player
/// menu, up navigates and `South` confirms, so one key doing both would
/// move the highlight and immediately pick whatever it landed on.
const BINDINGS: &[(KeyCode, u32, GamepadButton)] = &[
    // Player 1 — WASD, with its buttons on the left of the board.
    (KeyCode::W, 0, GamepadButton::DPadUp),
    (KeyCode::A, 0, GamepadButton::DPadLeft),
    (KeyCode::S, 0, GamepadButton::DPadDown),
    (KeyCode::D, 0, GamepadButton::DPadRight),
    (KeyCode::Q, 0, GamepadButton::South), // jump / menu confirm
    (KeyCode::ShiftLeft, 0, GamepadButton::South), // second jump, thumb-friendly
    (KeyCode::E, 0, GamepadButton::East),  // grab / menu back
    // Escape is the natural "open my menu" key, and it can't collide with
    // jumpy's own Escape handling: that only targets seated players with no
    // gamepad, and a dev pad player has one by definition.
    (KeyCode::Escape, 0, GamepadButton::Start), // join, then menu
    (KeyCode::Key1, 0, GamepadButton::Start),   // alias
    // Select is "back to the party": it pauses whatever is running and puts
    // the lobby back on screen. F12 rather than Backspace — a dev running
    // this alongside their editor and chat needs Backspace to still mean
    // Backspace everywhere else, and a function key never does.
    (KeyCode::Key2, 0, GamepadButton::Select),
    (KeyCode::F12, 0, GamepadButton::Select),
    // Player 2 — IJKL, with its buttons on the right.
    (KeyCode::I, 1, GamepadButton::DPadUp),
    (KeyCode::J, 1, GamepadButton::DPadLeft),
    (KeyCode::K, 1, GamepadButton::DPadDown),
    (KeyCode::L, 1, GamepadButton::DPadRight),
    (KeyCode::U, 1, GamepadButton::South),
    (KeyCode::ShiftRight, 1, GamepadButton::South), // second jump
    (KeyCode::O, 1, GamepadButton::East),
    (KeyCode::Return, 1, GamepadButton::Start), // join, then menu
    (KeyCode::Key9, 1, GamepadButton::Start),   // alias
    (KeyCode::Key0, 1, GamepadButton::Select),
];

/// Whether the virtual pads are switched on. Read once — flipping the env
/// var mid-run isn't a thing worth supporting.
pub fn enabled() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| {
        let on = std::env::var(ENABLE_VAR).map(|v| v != "0").unwrap_or(false);
        if on {
            info!(
                "dev pads ON | P1: WASD move, Q/LShift jump, E back, \
                 Esc (or 1) join+menu, F12 (or 2) party/back to lobby \
                 || P2: IJKL move, U/RShift jump, O back, \
                 Enter (or 9) join+menu, 0 party/back to lobby"
            );
        }
        on
    })
}

/// Translates this frame's keyboard edges into gamepad events on the two
/// virtual pads. Called from `input::handle_egui_input`, immediately before
/// `collect_player_controls` turns events into player controls.
pub fn inject(game: &mut Game) {
    if !enabled() {
        return;
    }

    let pressed = {
        let keyboard = game.shared_resource::<KeyboardInputs>();
        events_for(&keyboard)
    };
    if pressed.is_empty() {
        return;
    }

    let mut gamepad_inputs = game.shared_resource_mut::<GamepadInputs>();
    for (gamepad, button, value) in pressed {
        gamepad_inputs
            .gamepad_events
            .push(GamepadEvent::Button(GamepadButtonEvent {
                gamepad,
                button,
                value,
            }));
    }
}

/// The pure half of `inject`: this frame's keyboard edges as
/// `(pad, button, value)`. Split out so the binding table can be tested
/// without standing up a `Game`.
fn events_for(keyboard: &KeyboardInputs) -> Vec<(u32, GamepadButton, f32)> {
    keyboard
        .key_events
        .iter()
        .filter_map(|ev| {
            let key = ev.key_code.option()?;
            let value = if ev.button_state.pressed() { 1.0 } else { 0.0 };
            BINDINGS
                .iter()
                .find(|(bound, _, _)| *bound == key)
                .map(|&(_, pad, button)| (pad, button, value))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(key_code: KeyCode, pressed: bool) -> KeyboardEvent {
        KeyboardEvent {
            scan_code: 0,
            key_code: Maybe::Set(key_code),
            button_state: if pressed {
                ButtonState::Pressed
            } else {
                ButtonState::Released
            },
        }
    }

    fn events(keys: Vec<KeyboardEvent>) -> Vec<(u32, GamepadButton, f32)> {
        let mut kb = KeyboardInputs::default();
        for k in keys {
            kb.key_events.push(k);
        }
        events_for(&kb)
    }

    #[test]
    fn wasd_drives_pad_zero_and_ijkl_pad_one() {
        assert_eq!(
            events(vec![key(KeyCode::D, true)]),
            vec![(0, GamepadButton::DPadRight, 1.0)]
        );
        assert_eq!(
            events(vec![key(KeyCode::L, true)]),
            vec![(1, GamepadButton::DPadRight, 1.0)]
        );
    }

    /// Releasing has to emit its own zero — `apply_inputs_inner` holds the
    /// previous value when a button gets no event, so a missing release would
    /// leave the character walking forever.
    #[test]
    fn release_emits_a_zero() {
        assert_eq!(
            events(vec![key(KeyCode::A, false)]),
            vec![(0, GamepadButton::DPadLeft, 0.0)]
        );
    }

    /// Keys nobody bound must stay out of the gamepad stream entirely,
    /// or they'd read as spurious button presses (and join the party).
    #[test]
    fn unbound_keys_are_ignored() {
        assert!(events(vec![key(KeyCode::Z, true), key(KeyCode::F11, true)]).is_empty());
    }

    /// Both players' join/menu buttons must be `Start`: that is what
    /// `global_input_system` treats as join-then-open-menu. Escape and Enter
    /// are the primary keys, with the digits kept as aliases.
    #[test]
    fn join_keys_are_start_on_each_pad() {
        for k in [KeyCode::Escape, KeyCode::Key1] {
            assert_eq!(
                events(vec![key(k, true)]),
                vec![(0, GamepadButton::Start, 1.0)],
                "{k:?} must open player 1's menu"
            );
        }
        for k in [KeyCode::Return, KeyCode::Key9] {
            assert_eq!(
                events(vec![key(k, true)]),
                vec![(1, GamepadButton::Start, 1.0)],
                "{k:?} must open player 2's menu"
            );
        }
    }

    /// Each player has two jump keys, both landing on `South`.
    #[test]
    fn both_players_have_two_jump_keys() {
        for k in [KeyCode::Q, KeyCode::ShiftLeft] {
            assert_eq!(
                events(vec![key(k, true)]),
                vec![(0, GamepadButton::South, 1.0)],
                "{k:?} must jump for player 1"
            );
        }
        for k in [KeyCode::U, KeyCode::ShiftRight] {
            assert_eq!(
                events(vec![key(k, true)]),
                vec![(1, GamepadButton::South, 1.0)],
                "{k:?} must jump for player 2"
            );
        }
    }

    /// Up must not also jump: in an open menu, up moves the highlight and
    /// `South` confirms, so one key doing both would pick an entry the player
    /// only meant to scroll past.
    #[test]
    fn up_is_not_also_jump() {
        for (k, pad) in [(KeyCode::W, 0u32), (KeyCode::I, 1u32)] {
            assert_eq!(
                events(vec![key(k, true)]),
                vec![(pad, GamepadButton::DPadUp, 1.0)],
                "{k:?} must only move up"
            );
        }
    }

    /// Both players need every lobby action, on their own pad — a missing
    /// binding on one side is easy to introduce and invisible until someone
    /// sits down to play.
    #[test]
    fn both_pads_cover_the_same_actions() {
        use std::collections::HashSet;
        let buttons = |pad: u32| -> HashSet<GamepadButton> {
            BINDINGS
                .iter()
                .filter(|(_, p, _)| *p == pad)
                .map(|(_, _, b)| *b)
                .collect()
        };
        assert_eq!(
            buttons(0),
            buttons(1),
            "the two virtual pads must expose the same actions"
        );
    }

    /// Two players pressing at once both get through, on their own pads.
    #[test]
    fn simultaneous_players_are_independent() {
        let got = events(vec![key(KeyCode::A, true), key(KeyCode::J, true)]);
        assert_eq!(
            got,
            vec![
                (0, GamepadButton::DPadLeft, 1.0),
                (1, GamepadButton::DPadLeft, 1.0)
            ]
        );
    }

    /// Every binding must target a pad index that `PlayerInputCollector`
    /// actually has a control source for, or that key joins a seat and then
    /// can never move it.
    #[test]
    fn every_binding_targets_a_real_control_source() {
        for &(_, pad, _) in BINDINGS {
            assert!(
                pad < MAX_PLAYERS,
                "pad {pad} is outside 0..{MAX_PLAYERS}, so it has no control source"
            );
        }
    }

    /// No key may drive two different buttons — `events_for` takes the first
    /// match, so a duplicate would silently shadow the later binding. Several
    /// keys mapping to the *same* button is fine and intended (two jump keys,
    /// two ways to open a menu).
    #[test]
    fn bindings_are_unambiguous() {
        let mut seen = std::collections::HashSet::new();
        for &(k, _, _) in BINDINGS {
            assert!(seen.insert(k), "{k:?} is bound twice");
        }
    }
}
