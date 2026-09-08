use crate::{
    prelude::*,
    settings::{InputKind, PlayerControlMapping, Settings},
};

use strum::EnumIter;

pub fn game_plugin(game: &mut Game) {
    game.systems.add_startup_system(load_controler_mapping);
    game.insert_shared_resource(EguiInputHook::new(handle_egui_input));
    game.init_shared_resource::<GlobalPlayerControls>();
    game.init_shared_resource::<PlayerInputCollector>();
}

// Startup system to load game control mapping resource from the storage and insert the player input
// collector.
fn load_controler_mapping(game: &mut Game) {
    let control_mapping = {
        let storage = game.shared_resource::<Storage>();
        storage.get::<Settings>().unwrap().player_controls.clone()
    };
    game.insert_shared_resource(control_mapping);
}

fn collect_player_controls(game: &mut Game) {
    let controls = 'controls: {
        let mut collector = game.shared_resource_mut::<PlayerInputCollector>();
        let Some(mapping) = game.get_shared_resource::<PlayerControlMapping>() else {
            break 'controls default();
        };
        let keyboard = game.shared_resource::<KeyboardInputs>();
        let gamepad = game.shared_resource::<GamepadInputs>();
        collector.apply_inputs_inner(&mapping, &keyboard, &gamepad);
        collector.update_just_pressed();
        collector.advance_frame();
        GlobalPlayerControls(
            collector
                .get_current_controls()
                .clone()
                .into_iter()
                .collect(),
        )
    };
    game.insert_shared_resource(controls);
}

/// Settings to configure the [`handle_egui_input`] system
#[derive(Default, Debug, Clone, Copy)]
pub struct EguiInputSettings {
    /// If set to `true`, then all keyboard inputs will be sucked into a black hole so that egui
    /// doesn't read them.
    pub disable_keyboard_input: bool,
    /// If set to `true`, gamepad inputs will not be converted to egui inputs for menu navigation.
    pub disable_gamepad_input: bool,
}

/// Game system that takes the raw input events and converts it to player controls based on the
/// player input map.
pub fn handle_egui_input(game: &mut Game, egui_input: &mut egui::RawInput) {
    // Dev-only virtual pads. Must be *immediately* before the collect below:
    // the renderer replaces `GamepadInputs` earlier in this same chain, so
    // this is the only point where synthetic events survive to be read.
    #[cfg(not(target_arch = "wasm32"))]
    crate::dev_pads::inject(game);

    // We collect the global player controls here in the egui input hoook so that it will be
    // available immediately to egui, and then available to the rest of the systems that run after.
    collect_player_controls(game);

    let ctx = game.shared_resource::<EguiCtx>();
    let settings = ctx.get_state::<EguiInputSettings>();
    let events = &mut egui_input.events;

    // Remove keyboard events if disabled.
    if settings.disable_keyboard_input {
        events.retain(|x| !matches!(x, egui::Event::Key { .. }));
    }

    // Forward gamepad events to egui if not disabled.
    if !settings.disable_gamepad_input {
        let controls = game.shared_resource::<GlobalPlayerControls>();

        let push_key = |events: &mut Vec<egui::Event>, key| {
            events.push(egui::Event::Key {
                key,
                pressed: true,
                repeat: false,
                modifiers: default(),
            });
        };

        for (source, player_control) in controls.iter() {
            if !matches!(source, ControlSource::Gamepad(_)) {
                continue;
            };

            if player_control.menu_confirm_just_pressed {
                push_key(events, egui::Key::Enter);
            }
            if player_control.menu_back_just_pressed {
                push_key(events, egui::Key::Escape);
            }

            if player_control.just_moved {
                if player_control.move_direction.y > 0.1 {
                    push_key(events, egui::Key::ArrowUp);
                } else if player_control.move_direction.y < -0.1 {
                    push_key(events, egui::Key::ArrowDown);
                } else if player_control.move_direction.x < -0.1 {
                    push_key(events, egui::Key::ArrowLeft);
                } else if player_control.move_direction.x > 0.1 {
                    push_key(events, egui::Key::ArrowRight);
                }
            }
        }
    }
}

/// Resource containing the global player control inputs.
///
/// It is important to note that these controls are updated every system frame, and therefore
/// the `just_pressed` and `just_moved` flags are not accurate in the context of a fixed
/// update match loop. Matches with fixed updates have their own input resource.
///
/// This resource is used throughout the menu where the inputs are collected every frame, not
/// every fixed update.
#[derive(HasSchema, Clone, Default, Deref, DerefMut)]
pub struct GlobalPlayerControls(HashMap<ControlSource, PlayerControl>);

impl GlobalPlayerControls {
    /// Iterator over inputs that originated from gamepads.
    pub fn gamepads(&self) -> impl Iterator<Item = &PlayerControl> {
        self.iter().filter_map(|(source, control)| {
            matches!(source, ControlSource::Gamepad(_)).then_some(control)
        })
    }
}

/// The source of player control inputs
#[derive(Debug, Clone, Copy, Default, HasSchema, Hash, Eq, PartialEq, EnumIter)]
#[repr(C, u8)]
pub enum ControlSource {
    #[default]
    /// The first keyboard controls
    Keyboard1,
    /// The second keyboard controls
    Keyboard2,
    /// A gamepad control with the given index
    Gamepad(u32),
}

/// Player control input state
#[derive(HasSchema, Default, Clone, Copy, Debug)]
#[repr(C)]
pub struct PlayerControl {
    pub left: f32,
    pub right: f32,
    pub up: f32,
    pub down: f32,
    pub move_direction: Vec2,
    pub just_moved: bool,
    pub moving: bool,

    pub menu_back_pressed: bool,
    pub menu_back_just_pressed: bool,
    pub menu_confirm_pressed: bool,
    pub menu_confirm_just_pressed: bool,
    pub menu_start_pressed: bool,
    pub menu_start_just_pressed: bool,

    pub pause_pressed: bool,
    pub pause_just_pressed: bool,

    pub jump_pressed: bool,
    pub jump_just_pressed: bool,

    pub shoot_pressed: bool,
    pub shoot_just_pressed: bool,

    pub grab_pressed: bool,
    pub grab_just_pressed: bool,

    pub slide_pressed: bool,
    pub slide_just_pressed: bool,

    pub ragdoll_pressed: bool,
    pub ragdoll_just_pressed: bool,
}

#[derive(HasSchema, Clone)]
pub struct PlayerInputCollector {
    /// The local player's [`ControlSource`] in an online / lan game.
    control_source: ControlSource,
    current_controls: HashMap<ControlSource, PlayerControl>,
    last_controls: HashMap<ControlSource, PlayerControl>,
}

impl PlayerInputCollector {
    pub fn get_current_controls(&self) -> &HashMap<ControlSource, PlayerControl> {
        &self.current_controls
    }
}

impl Default for PlayerInputCollector {
    fn default() -> Self {
        let def_controls = || {
            let mut m = HashMap::default();
            // We always have the keyboard controls "plugged in"
            m.insert(ControlSource::Keyboard1, default());
            m.insert(ControlSource::Keyboard2, default());
            for i in 0..MAX_PLAYERS {
                m.insert(ControlSource::Gamepad(i), default());
            }
            m
        };
        Self {
            control_source: ControlSource::Keyboard1,
            current_controls: def_controls(),
            last_controls: def_controls(),
        }
    }
}

impl<'a> bones_framework::input::InputCollector<'a, PlayerControl> for PlayerInputCollector {
    fn update_just_pressed(&mut self) {
        self.current_controls
            .iter_mut()
            .for_each(|(source, current)| {
                let last = self.last_controls.entry(*source).or_default();

                current.move_direction =
                    vec2(current.right - current.left, current.up - current.down);
                current.moving = current.move_direction.length_squared() > 0.01;

                for (just_pressed, current_pressed, last_pressed) in [
                    (
                        &mut current.pause_just_pressed,
                        current.pause_pressed,
                        last.pause_pressed,
                    ),
                    (
                        &mut current.jump_just_pressed,
                        current.jump_pressed,
                        last.jump_pressed,
                    ),
                    (
                        &mut current.shoot_just_pressed,
                        current.shoot_pressed,
                        last.shoot_pressed,
                    ),
                    (
                        &mut current.grab_just_pressed,
                        current.grab_pressed,
                        last.grab_pressed,
                    ),
                    (
                        &mut current.slide_just_pressed,
                        current.slide_pressed,
                        last.slide_pressed,
                    ),
                    (
                        &mut current.ragdoll_just_pressed,
                        current.ragdoll_pressed,
                        last.ragdoll_pressed,
                    ),
                    (
                        &mut current.menu_back_just_pressed,
                        current.menu_back_pressed,
                        last.menu_back_pressed,
                    ),
                    (
                        &mut current.menu_confirm_just_pressed,
                        current.menu_confirm_pressed,
                        last.menu_confirm_pressed,
                    ),
                    (
                        &mut current.menu_start_just_pressed,
                        current.menu_start_pressed,
                        last.menu_start_pressed,
                    ),
                    (&mut current.just_moved, current.moving, last.moving),
                ] {
                    *just_pressed = current_pressed && !last_pressed;
                }
            });
    }

    fn advance_frame(&mut self) {
        self.last_controls = self.current_controls.clone();
    }

    /// Update the internal state with new inputs. This must be called every render frame with the
    /// input events.
    fn apply_inputs(&mut self, world: &World) {
        let keyboard = world.resource::<KeyboardInputs>();
        let gamepad = world.resource::<GamepadInputs>();
        let mapping = world.resource::<PlayerControlMapping>();
        self.apply_inputs_inner(&mapping, &keyboard, &gamepad);

        #[cfg(not(target_arch = "wasm32"))]
        // Get the first local player control source which should be the only
        // local player in an online game.
        if let Some(user_control_source) = world
            .resource::<MatchInputs>()
            .players
            .iter()
            .find_map(|player| player.control_source)
        {
            // `self.control_source` is only used in online / lan games to
            // tell the `GgrsSessionRunner` which controls to grab for the
            // one local player via `InputCollecter::get_control`.
            self.control_source = user_control_source;

            // `apply_inputs` is called before `get_control` so this will
            // always update the source in time.
        } else {
            panic!("no local player control source")
        }
    }

    fn get_control(&self) -> &PlayerControl {
        self.current_controls.get(&self.control_source).unwrap()
    }
}

impl PlayerInputCollector {
    fn apply_inputs_inner(
        &mut self,
        mapping: &PlayerControlMapping,
        keyboard: &KeyboardInputs,
        gamepad: &GamepadInputs,
    ) {
        // Helper to get the value of the given input type for the given player.
        let get_input_value = |input_map: &InputKind, control_source: &ControlSource| match (
            input_map,
            control_source,
        ) {
            (InputKind::Button(mapped_button), ControlSource::Gamepad(idx)) => {
                for input in gamepad.gamepad_events.iter().rev() {
                    if let GamepadEvent::Button(e) = input {
                        if &e.button == mapped_button && e.gamepad == *idx {
                            let value = if e.value < 0.1 { 0.0 } else { e.value };
                            return Some(value);
                        }
                    }
                }
                None
            }
            (InputKind::AxisPositive(mapped_axis), ControlSource::Gamepad(idx)) => {
                for input in gamepad.gamepad_events.iter().rev() {
                    if let GamepadEvent::Axis(e) = input {
                        if &e.axis == mapped_axis && e.gamepad == *idx {
                            let value = if e.value < 0.1 { 0.0 } else { e.value };
                            return Some(value);
                        }
                    }
                }
                None
            }
            (InputKind::AxisNegative(mapped_axis), ControlSource::Gamepad(idx)) => {
                for input in gamepad.gamepad_events.iter().rev() {
                    if let GamepadEvent::Axis(e) = input {
                        if &e.axis == mapped_axis && e.gamepad == *idx {
                            let value = if e.value > -0.1 { 0.0 } else { e.value };
                            return Some(value);
                        }
                    }
                }
                None
            }
            (
                InputKind::Keyboard(mapped_key),
                ControlSource::Keyboard1 | ControlSource::Keyboard2,
            ) => {
                for input in keyboard.key_events.iter().rev() {
                    if input.key_code.option() == Some(*mapped_key) {
                        return Some(if input.button_state.pressed() {
                            1.0
                        } else {
                            0.0
                        });
                    }
                }
                None
            }
            _ => None,
        };

        for (source, control) in self.current_controls.iter_mut() {
            let mapping = match source {
                ControlSource::Keyboard1 => &mapping.keyboard1,
                ControlSource::Keyboard2 => &mapping.keyboard2,
                ControlSource::Gamepad(_) => &mapping.gamepad,
            };

            for (button_pressed, button_map) in [
                (&mut control.pause_pressed, &mapping.pause),
                (&mut control.jump_pressed, &mapping.jump),
                (&mut control.grab_pressed, &mapping.grab),
                (&mut control.shoot_pressed, &mapping.shoot),
                (&mut control.slide_pressed, &mapping.slide),
                (&mut control.ragdoll_pressed, &mapping.ragdoll),
                (&mut control.menu_back_pressed, &mapping.menu_back),
                (&mut control.menu_confirm_pressed, &mapping.menu_confirm),
                (&mut control.menu_start_pressed, &mapping.menu_start),
            ] {
                if let Some(value) = get_input_value(button_map, source) {
                    *button_pressed = value > 0.0;
                }
            }

            // helper for merging two inputs (like dpad + joystick for example) allowing multiple bindings
            // for same control
            let merge_inputs = |input1: &InputKind, input2: &InputKind| -> Option<f32> {
                match (
                    get_input_value(input1, source),
                    get_input_value(input2, source),
                ) {
                    // Both inputs have a value and the first is zero -- use the second value
                    (Some(0.0), Some(value2)) => Some(value2),
                    // First input has a non-zero value -- use the first value
                    (Some(value1), _) => Some(value1),
                    // First input has no value -- use the second
                    (None, value2) => value2,
                }
                .map(f32::abs)
            };

            if let Some(left) = merge_inputs(&mapping.movement.left, &mapping.movement_alt.left) {
                control.left = left;
            }
            if let Some(right) = merge_inputs(&mapping.movement.right, &mapping.movement_alt.right)
            {
                control.right = right;
            }
            if let Some(up) = merge_inputs(&mapping.movement.up, &mapping.movement_alt.up) {
                control.up = up;
            }
            if let Some(down) = merge_inputs(&mapping.movement.down, &mapping.movement_alt.down) {
                control.down = down;
            }
        }
    }
}

#[cfg(not(target_arch = "wasm32"))]
impl DenseControl<DensePlayerControl> for PlayerControl {
    fn get_dense_input(&self) -> DensePlayerControl {
        let mut dense_control = DensePlayerControl::default();
        dense_control.set_jump_pressed(self.jump_pressed);
        dense_control.set_grab_pressed(self.grab_pressed);
        dense_control.set_slide_pressed(self.slide_pressed);
        dense_control.set_shoot_pressed(self.shoot_pressed);
        dense_control.set_ragdoll_pressed(self.ragdoll_pressed);
        dense_control.set_move_direction(proto::DenseMoveDirection(self.move_direction));
        dense_control
    }

    fn update_from_dense(&mut self, new_control: &DensePlayerControl) {
        let jump_pressed = new_control.jump_pressed();
        self.jump_just_pressed = jump_pressed && !self.jump_pressed;
        self.jump_pressed = jump_pressed;

        let grab_pressed = new_control.grab_pressed();
        self.grab_just_pressed = grab_pressed && !self.grab_pressed;
        self.grab_pressed = grab_pressed;

        let shoot_pressed = new_control.shoot_pressed();
        self.shoot_just_pressed = shoot_pressed && !self.shoot_pressed;
        self.shoot_pressed = shoot_pressed;

        let ragdoll_pressed = new_control.ragdoll_pressed();
        self.ragdoll_just_pressed = ragdoll_pressed && !self.ragdoll_pressed;
        self.ragdoll_pressed = ragdoll_pressed;

        let was_moving = self.move_direction.length_squared() > f32::MIN_POSITIVE;
        self.move_direction = new_control.move_direction().0;
        let is_moving = self.move_direction.length_squared() > f32::MIN_POSITIVE;
        self.just_moved = !was_moving && is_moving;
    }
}

#[cfg(not(target_arch = "wasm32"))]
bitfield::bitfield! {
    /// A player's controller inputs densely packed into a single u32.
    ///
    /// This is used when sending player inputs across the network.
    #[derive(bytemuck::Pod, bytemuck::Zeroable, Copy, Clone, PartialEq, Eq)]//, Reflect)]
    #[repr(transparent)]
    pub struct DensePlayerControl(u32);
    impl Debug;
    pub jump_pressed, set_jump_pressed: 0;
    pub shoot_pressed, set_shoot_pressed: 1;
    pub grab_pressed, set_grab_pressed: 2;
    pub slide_pressed, set_slide_pressed: 3;
    pub ragdoll_pressed, set_ragdoll_pressed: 4;
    pub from into proto::DenseMoveDirection, move_direction, set_move_direction: 16, 5;
}

#[cfg(not(target_arch = "wasm32"))]
impl Default for DensePlayerControl {
    fn default() -> Self {
        let mut control = Self(0);
        control.set_move_direction(default());
        control
    }
}

#[cfg(not(target_arch = "wasm32"))]
/// Used to implement input type config for bones networking.
pub struct NetworkInputConfig;

#[cfg(not(target_arch = "wasm32"))]
impl<'a> DenseInputConfig<'a> for NetworkInputConfig {
    type Dense = DensePlayerControl;
    type Control = PlayerControl;
    type Controls = MatchInputs;
    type InputCollector = PlayerInputCollector;
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The gamepad mapping the dev pads target: D-pad on `movement_alt`,
    /// left stick on `movement` — mirroring `assets/game.yaml`.
    fn gamepad_mapping() -> PlayerControlMapping {
        let mut m = PlayerControlMapping::default();
        m.gamepad.movement = VirtualDPad {
            up: InputKind::AxisPositive(GamepadAxis::LeftStickY),
            down: InputKind::AxisNegative(GamepadAxis::LeftStickY),
            left: InputKind::AxisNegative(GamepadAxis::LeftStickX),
            right: InputKind::AxisPositive(GamepadAxis::LeftStickX),
        };
        m.gamepad.movement_alt = VirtualDPad {
            up: InputKind::Button(GamepadButton::DPadUp),
            down: InputKind::Button(GamepadButton::DPadDown),
            left: InputKind::Button(GamepadButton::DPadLeft),
            right: InputKind::Button(GamepadButton::DPadRight),
        };
        m.gamepad.jump = InputKind::Button(GamepadButton::South);
        m.gamepad.menu_start = InputKind::Button(GamepadButton::Start);
        m
    }

    fn button(gamepad: u32, button: GamepadButton, value: f32) -> GamepadEvent {
        GamepadEvent::Button(GamepadButtonEvent {
            gamepad,
            button,
            value,
        })
    }

    fn collect(events: Vec<GamepadEvent>) -> PlayerInputCollector {
        let mut collector = PlayerInputCollector::default();
        let mut gamepad = GamepadInputs::default();
        for e in events {
            gamepad.gamepad_events.push(e);
        }
        collector.apply_inputs_inner(&gamepad_mapping(), &KeyboardInputs::default(), &gamepad);
        collector
    }

    fn control(collector: &PlayerInputCollector, pad: u32) -> PlayerControl {
        *collector
            .get_current_controls()
            .get(&ControlSource::Gamepad(pad))
            .expect("gamepad control source must exist")
    }

    /// A D-pad press becomes movement. This is the contract `dev_pads` relies
    /// on when it synthesises events from the keyboard — if it ever stops
    /// holding, WASD silently does nothing in the lobby.
    #[test]
    fn dpad_button_drives_movement() {
        let c = collect(vec![button(0, GamepadButton::DPadRight, 1.0)]);
        assert_eq!(control(&c, 0).right, 1.0, "DPadRight must drive `right`");

        let c = collect(vec![button(0, GamepadButton::DPadLeft, 1.0)]);
        assert_eq!(control(&c, 0).left, 1.0, "DPadLeft must drive `left`");
    }

    /// Every pad index a virtual pad may use has to be a live control source.
    /// `PlayerInputCollector` only pre-populates `Gamepad(0..MAX_PLAYERS)`, so
    /// an out-of-range index would join a seat and then never move — the
    /// reason `dev_pads` is pinned to indices 0 and 1.
    #[test]
    fn each_seat_index_is_a_control_source() {
        let c = PlayerInputCollector::default();
        for pad in 0..MAX_PLAYERS {
            assert!(
                c.get_current_controls()
                    .contains_key(&ControlSource::Gamepad(pad)),
                "Gamepad({pad}) must be a control source"
            );
        }
    }

    /// Events are addressed to one pad. Pressing P1's key must not move P2 —
    /// the whole point of two virtual pads.
    #[test]
    fn pads_do_not_bleed_into_each_other() {
        let c = collect(vec![button(0, GamepadButton::DPadRight, 1.0)]);
        assert_eq!(control(&c, 0).right, 1.0);
        assert_eq!(control(&c, 1).right, 0.0, "pad 1 must be untouched");
    }

    /// A release event zeroes the axis. `dev_pads` emits edges only, so
    /// without this a key-up would leave the character walking forever.
    #[test]
    fn release_event_stops_movement() {
        let c = collect(vec![
            button(0, GamepadButton::DPadRight, 1.0),
            button(0, GamepadButton::DPadRight, 0.0),
        ]);
        assert_eq!(
            control(&c, 0).right,
            0.0,
            "the later release must win over the earlier press"
        );
    }

    /// With no event for a button this frame, its value must persist. This is
    /// what lets `dev_pads` emit press/release edges instead of re-sending a
    /// held key every frame.
    #[test]
    fn absent_event_holds_previous_value() {
        let mut collector = PlayerInputCollector::default();
        let mapping = gamepad_mapping();

        let mut pressed = GamepadInputs::default();
        pressed
            .gamepad_events
            .push(button(0, GamepadButton::DPadRight, 1.0));
        collector.apply_inputs_inner(&mapping, &KeyboardInputs::default(), &pressed);
        assert_eq!(control(&collector, 0).right, 1.0);

        // Next frame: nothing at all, as when a key is simply still held.
        collector.apply_inputs_inner(
            &mapping,
            &KeyboardInputs::default(),
            &GamepadInputs::default(),
        );
        assert_eq!(
            control(&collector, 0).right,
            1.0,
            "a held key must keep moving without a repeat event"
        );
    }

    /// Buttons the lobby drives: jump and the Start that joins/opens a menu.
    #[test]
    fn face_buttons_map_to_actions() {
        let c = collect(vec![button(1, GamepadButton::South, 1.0)]);
        assert!(control(&c, 1).jump_pressed, "South must be jump");

        let c = collect(vec![button(1, GamepadButton::Start, 1.0)]);
        assert!(
            control(&c, 1).menu_start_pressed,
            "Start must be menu_start"
        );
    }
}
