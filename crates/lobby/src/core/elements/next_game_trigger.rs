use crate::prelude::*;

/// The lobby's TV: jump onto the pad in front of it and the next warm game
/// starts — GameNight's "vote with your feet" mechanic. A no-op outside the
/// GameNight lobby (standalone play never inserts `GameNightBridge`).
///
/// This used to be a three-second hold, which kept an idle bystander from
/// starting a match by standing in the wrong place but made the party perform
/// a countdown to do something they'd already decided on. A jump can't happen
/// by accident either, and it happens the moment you mean it.
///
/// The element's own position is the *floor zone* a player lands in; the
/// screen hangs above it at `screen_offset`. Keeping the entity on the floor
/// means the existing actor-collision test does the right thing without a
/// separate trigger volume, and the set dressing is purely visual.
///
/// The TV itself has no sprite here: it's drawn by the bevy layer
/// (`gamenight::sync_next_game_tv_system`), which is the only side that can
/// see the daemon's shelf metadata for the upcoming game's title.
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
    /// Seconds left before this pad will fire again, so one landing starts
    /// one game however many frames the physics takes to settle it.
    cooling: f32,
    /// How far each button is pushed in: 1 the moment somebody lands on it,
    /// easing back to 0 over `PAD_PRESS_SECONDS`.
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

const COOLDOWN_SECS: f32 = 0.5;

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
                    cooling: 0.0,
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
    bridge: Option<Res<crate::gamenight::GameNightBridge>>,
) {
    let Some(bridge) = bridge else {
        // Standalone play: no daemon, no next game to start.
        return;
    };
    let dt = time.delta_seconds();
    let button = bridge.tv_button();
    for (_, (trigger, solid)) in entities.iter_with((&mut triggers, &solids)) {
        trigger.cooling = (trigger.cooling - dt).max(0.0);
        trigger.press = (trigger.press - dt / PAD_PRESS_SECONDS).max(0.0);
        trigger.skip_press = (trigger.skip_press - dt / PAD_PRESS_SECONDS).max(0.0);
        trigger.play_press = (trigger.play_press - dt / PAD_PRESS_SECONDS).max(0.0);
        if trigger.cooling > 0.0 {
            continue;
        }
        let Some(idx) = player_landed_on(
            solid.pos,
            solid.size,
            &entities,
            &player_indexes,
            &bodies,
            &transforms,
        ) else {
            continue;
        };
        // Where they came down, not what they overlap: a player is wider
        // than half this slab, so "did you touch the right half" would fire
        // SKIP for somebody who landed squarely on START.
        let Some(x) = entities
            .iter_with((&player_indexes, &transforms))
            .find(|(_, (i, _))| i.0 == idx)
            .map(|(_, (_, transform))| transform.translation.x)
        else {
            continue;
        };
        match button_at(x, solid.pos.x, solid.size.x) {
            0 if button != crate::gamenight::TvButton::Disabled => {
                trigger.press = 1.0;
                bridge.press_tv_button();
            }
            1 if bridge.next_game_is_ready() => {
                trigger.play_press = 1.0;
                bridge.play_next_game();
            }
            2 if bridge.can_skip_next_game() => {
                trigger.skip_press = 1.0;
                bridge.skip_next_game();
            }
            _ => continue,
        }
        trigger.cooling = COOLDOWN_SECS;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
