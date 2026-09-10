use crate::prelude::*;

/// Stand on a TV button for two seconds to confirm. Stepping off cancels;
/// staying on it after confirmation cannot trigger another action.
#[derive(HasSchema, Default, Debug, Clone)]
#[type_data(metadata_asset("next_game_trigger"))]
#[repr(C)]
pub struct NextGameTriggerMeta {
    /// The button itself: a solid block on the floor you land on top of to
    /// start the next game. The element's position is its centre.
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
            Vec2::new(width * 0.82, size.y),
        )
    })
}

fn button_at(x: f32, center: f32, width: f32) -> usize {
    if x < center - width / 6.0 {
        0
    } else if x > center + width / 6.0 {
        2
    } else {
        1
    }
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
    mut entities: ResMutInit<Entities>,
    mut hydrated: CompMut<MapElementHydrated>,
    element_handles: Comp<ElementHandle>,
    assets: Res<AssetServer>,
    mut triggers: CompMut<NextGameTrigger>,
    mut solids: CompMut<Solid>,
    transforms: Comp<Transform>,
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
            // A solid, not a trigger: you bump into this one and you stand on
            // top of it.
            let pos = transforms
                .get(entity)
                .map(|t| t.translation.truncate())
                .unwrap_or_default();
            solids.insert(
                entity,
                Solid {
                    disabled: false,
                    pos,
                    size: *body_size,
                    ..default()
                },
            );
            // The TV above it is a platform in its own right, and an entity
            // carries only one solid — so the screen gets its own, holding
            // nothing but the shape you land on. The bevy side works out
            // where to draw from the trigger's screen geometry, so this
            // never needs finding again.
            let screen = entities.create();
            solids.insert(
                screen,
                Solid {
                    disabled: false,
                    pos: pos + *screen_offset,
                    size: *screen_size + Vec2::splat(SCREEN_FRAME * 2.0),
                    ..default()
                },
            );
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
    solids: Comp<Solid>,
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
    for (_, (trigger, solid)) in entities.iter_with((&mut triggers, &solids)) {
        let mut occupants = [None; 3];
        for (_, (idx, body, transform)) in
            entities.iter_with((&player_indexes, &bodies, &transforms))
        {
            let x = transform.translation.x;
            let feet = body.bounding_box(*transform);
            if body.is_on_ground
                && (feet.min.y - (solid.pos.y + solid.size.y / 2.0)).abs() <= 4.0
                && x >= solid.pos.x - solid.size.x / 2.0
                && x <= solid.pos.x + solid.size.x / 2.0
            {
                let index = button_at(x, solid.pos.x, solid.size.x);
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
    fn button_faces_match_landing_regions() {
        let pos = Vec2::new(560.0, 160.0);
        let size = Vec2::new(240.0, 14.0);
        for (index, (center, face)) in pad_thirds(pos, size).into_iter().enumerate() {
            for x in [center.x - face.x / 2.0, center.x, center.x + face.x / 2.0] {
                assert_eq!(button_at(x, pos.x, size.x), index);
            }
        }
    }
}
