use crate::prelude::*;

/// Stand on a TV button for two seconds to confirm. Stepping off cancels;
/// staying on it after confirmation cannot trigger another action.
#[derive(HasSchema, Default, Debug, Clone)]
#[type_data(metadata_asset("next_game_trigger"))]
#[repr(C)]
pub struct NextGameTriggerMeta {
    /// Width of the station and height of its painted, non-solid floor zones.
    /// The element position is the centre of the floor markings.
    pub body_size: Vec2,
    /// Size of the TV screen drawn above the zone.
    pub screen_size: Vec2,
    /// Offset from the zone's center to the center of the screen.
    pub screen_offset: Vec2,
    pub hold_sounds: SVec<Handle<AudioSource>>,
}

pub fn game_plugin(game: &mut Game) {
    NextGameTriggerMeta::register_schema();
    game.init_shared_resource::<AssetServer>();
}

pub fn session_plugin(session: &mut SessionBuilder) {
    session
        .stages
        .add_system_to_stage(CoreStage::PreUpdate, hydrate)
        .add_system_to_stage(CoreStage::PostUpdate, update);
}

#[derive(Clone, Debug, HasSchema, Default)]
pub struct NextGameTrigger {
    /// Each button owns a continuous hold and a release-to-rearm latch.
    holds: [PadHold; 3],
    hold_sounds: SVec<Handle<AudioSource>>,
    /// Confirmation progress, also used for the button depression and timer.
    pub press: f32,
    pub skip_press: f32,
    pub play_press: f32,
    /// Pad and screen geometry, copied off the element meta at hydrate so the
    /// bevy side can lay the TV and its buttons out without resolving the
    /// asset every frame.
    pub body_size: Vec2,
    pub screen_size: Vec2,
    pub screen_offset: Vec2,
}

/// How much of the slab each button *face* covers. The rest is the gap
/// between them: two buttons drawn edge to edge read as one striped block,
/// and "back into your game" sitting flush against "leave your game" is a
/// thing somebody will mis-hit at speed.
pub fn pad_thirds(pos: Vec2, size: Vec2) -> [(Vec2, Vec2); 3] {
    let width = size.x / 3.0;
    [0, 1, 2].map(|index| {
        (
            Vec2::new(pos.x + (index as f32 - 1.0) * width, pos.y),
            Vec2::new((width * 0.55).min(68.0), size.y),
        )
    })
}

/// Gaps between markings do not belong to either action. A player must be
/// grounded with feet at floor level; merely jumping past a sign is harmless.
fn dwell_zone(x: f32, feet_y: f32, grounded: bool, pos: Vec2, size: Vec2) -> Option<usize> {
    if !grounded || (feet_y - pos.y).abs() > 6.0 {
        return None;
    }
    pad_thirds(pos, size)
        .iter()
        .position(|(center, face)| (x - center.x).abs() <= face.x / 2.0)
}

pub const HOLD_SECONDS: f32 = 2.0;

#[derive(Clone, Debug, HasSchema, Default)]
struct PadHold {
    owner: Option<u32>,
    elapsed: f32,
    fired: bool,
    last_cue: Option<u32>,
}
impl PadHold {
    fn update(&mut self, owner: Option<u32>, enabled: bool, dt: f32) -> bool {
        if owner.is_none() {
            *self = Self::default();
            return false;
        }
        if self.fired {
            return false;
        }
        if !enabled {
            self.elapsed = 0.0;
            self.last_cue = None;
            self.owner = owner;
            return false;
        }
        if self.owner != owner {
            self.elapsed = 0.0;
            self.last_cue = None;
            self.owner = owner;
        }
        self.elapsed = (self.elapsed + dt).min(HOLD_SECONDS);
        if self.elapsed >= HOLD_SECONDS {
            self.fired = true;
            return true;
        }
        false
    }
    /// One short cue per countdown step; never replay missed ticks in a burst.
    fn take_cue(&mut self, enabled: bool) -> Option<usize> {
        if !enabled || self.owner.is_none() || self.elapsed <= 0.0 {
            return None;
        }
        let cue = if self.fired {
            5
        } else {
            (self.elapsed / 0.4).floor() as u32
        };
        if self.last_cue == Some(cue) {
            return None;
        }
        self.last_cue = Some(cue);
        Some(cue as usize)
    }
    fn progress(&self) -> f32 {
        self.elapsed / HOLD_SECONDS
    }
}

fn hydrate(
    entities: ResMutInit<Entities>,
    mut hydrated: CompMut<MapElementHydrated>,
    element_handles: Comp<ElementHandle>,
    assets: Res<AssetServer>,
    mut triggers: CompMut<NextGameTrigger>,
) {
    let mut not_hydrated_bitset = hydrated.bitset().clone();
    not_hydrated_bitset.bit_not();
    not_hydrated_bitset.bit_and(element_handles.bitset());

    let unhydrated: Vec<_> = entities.iter_with_bitset(&not_hydrated_bitset).collect();
    for entity in unhydrated {
        let element_handle = element_handles.get(entity).unwrap();
        let element_meta = assets.get(element_handle.0);

        if let Ok(NextGameTriggerMeta {
            body_size,
            screen_size,
            screen_offset,
            hold_sounds,
        }) = assets.get(element_meta.data).try_cast_ref()
        {
            hydrated.insert(entity, MapElementHydrated);
            // Furniture and floor markings are visual only: never add collision.
            triggers.insert(
                entity,
                NextGameTrigger {
                    holds: Default::default(),
                    hold_sounds: hold_sounds.clone(),
                    press: 0.0,
                    skip_press: 0.0,
                    play_press: 0.0,
                    body_size: *body_size,
                    screen_size: *screen_size,
                    screen_offset: *screen_offset,
                },
            );
        }
    }
}

fn update(
    entities: Res<Entities>,
    mut triggers: CompMut<NextGameTrigger>,
    player_indexes: Comp<PlayerIdx>,
    bodies: Comp<KinematicBody>,
    transforms: Comp<Transform>,
    time: Res<Time>,
    mut audio_center: ResMut<AudioCenter>,
    bridge: Option<Res<crate::gamenight::GameNightBridge>>,
) {
    let Some(bridge) = bridge else {
        // Standalone play: no daemon, no next game to start.
        return;
    };
    let dt = time.delta_seconds();
    let button = bridge.tv_button();
    for (_, (trigger, station_transform)) in entities.iter_with((&mut triggers, &transforms)) {
        let mut occupants = [None; 3];
        for (_, (idx, body, transform)) in
            entities.iter_with((&player_indexes, &bodies, &transforms))
        {
            if bridge.seat_sleeping(idx.0) {
                continue;
            }
            let x = transform.translation.x;
            let feet = body.bounding_box(*transform);
            if let Some(index) = dwell_zone(
                x,
                feet.min.y,
                body.is_on_ground,
                station_transform.translation.truncate(),
                trigger.body_size,
            ) {
                // Deterministic ownership when two players share a pad.
                occupants[index] = Some(occupants[index].map_or(idx.0, |old: u32| old.min(idx.0)));
            }
        }
        let enabled = [
            button != crate::gamenight::TvButton::Disabled,
            bridge.next_game_is_ready(),
            bridge.can_skip_next_game(),
        ];
        // At most one party action in a frame. Reset competing countdowns.
        for index in 0..3 {
            let fired = trigger.holds[index].update(occupants[index], enabled[index], dt);
            if let Some(cue) = trigger.holds[index].take_cue(enabled[index]) {
                if let Some(sound) = trigger.hold_sounds.get(cue) {
                    audio_center.play_sound(*sound, 0.35);
                }
            }
            if fired {
                match index {
                    0 => bridge.press_tv_button(),
                    1 => bridge.play_next_game(),
                    _ => bridge.skip_next_game(),
                }
                for other in 0..3 {
                    if other != index {
                        trigger.holds[other].elapsed = 0.0;
                        trigger.holds[other].last_cue = None;
                    }
                }
                break;
            }
        }
        trigger.press = trigger.holds[0].progress();
        trigger.play_press = trigger.holds[1].progress();
        trigger.skip_press = trigger.holds[2].progress();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn hold_requires_continuous_time_and_release_to_repeat() {
        let mut hold = PadHold::default();
        assert!(!hold.update(Some(0), true, 1.0));
        assert!(!hold.update(None, true, 0.1));
        assert_eq!(hold.progress(), 0.0);
        assert!(!hold.update(Some(0), true, 1.0));
        assert!(!hold.update(Some(1), true, 1.0));
        assert!(hold.update(Some(1), true, 1.0));
        assert!(!hold.update(Some(1), true, 10.0));
        hold.update(None, true, 0.1);
        assert!(!hold.update(Some(1), false, 10.0));
        assert!(!hold.update(Some(1), true, 1.0));
        assert!(hold.update(Some(1), true, 1.0));
    }
    #[test]
    fn countdown_cues_rise_once_and_cancel_on_release() {
        let mut hold = PadHold::default();
        hold.update(Some(0), true, 0.01);
        assert_eq!(hold.take_cue(true), Some(0));
        assert_eq!(hold.take_cue(true), None);
        for step in 1..=5 {
            hold.update(Some(0), true, 0.4);
            assert_eq!(hold.take_cue(true), Some(step));
            assert_eq!(hold.take_cue(true), None);
        }
        hold.update(Some(0), true, 10.0);
        assert_eq!(hold.take_cue(true), None);
        hold.update(None, true, 0.01);
        assert_eq!(hold.take_cue(true), None);
        hold.update(Some(0), false, 1.0);
        assert_eq!(hold.take_cue(false), None);
        hold.update(Some(0), true, 0.01);
        assert_eq!(hold.take_cue(true), Some(0));
        hold.update(Some(1), true, 0.01);
        assert_eq!(hold.take_cue(true), Some(0));
    }

    #[test]
    fn floor_markings_are_reachable_without_jumping_and_gaps_cancel() {
        let pos = Vec2::new(620.0, 98.0);
        let size = Vec2::new(360.0, 4.0);
        for (index, (center, _)) in pad_thirds(pos, size).into_iter().enumerate() {
            assert_eq!(dwell_zone(center.x, 96.0, true, pos, size), Some(index));
            assert_eq!(dwell_zone(center.x, 96.0, false, pos, size), None);
            assert_eq!(dwell_zone(center.x, 160.0, true, pos, size), None);
        }
        assert_eq!(dwell_zone(560.0, 96.0, true, pos, size), None);
        assert_eq!(dwell_zone(680.0, 96.0, true, pos, size), None);
    }
}
