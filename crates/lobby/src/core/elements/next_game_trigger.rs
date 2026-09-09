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
const FACE_SHARE: f32 = 0.34;

/// The two buttons, as (centre, size), given where the slab is and how big
/// it is. Faces at the far ends, gap in the middle.
///
/// One solid underneath both, and one landing test across the whole of it:
/// splitting the *collider* would leave a seam for a player to jump into and
/// press nothing, and two overlapping tests would make whoever straddles the
/// middle press both. Which button you hit is decided afterwards, by which
/// side of the middle you came down on — so the gap is a visual one, and
/// landing in it still works.
pub fn pad_halves(pos: Vec2, size: Vec2) -> ((Vec2, Vec2), (Vec2, Vec2)) {
    let face = Vec2::new(size.x * FACE_SHARE, size.y);
    let inset = size.x / 2.0 - face.x / 2.0;
    (
        (Vec2::new(pos.x - inset, pos.y), face),
        (Vec2::new(pos.x + inset, pos.y), face),
    )
}

/// How long the pad ignores further landings after starting a game. Long
/// enough to cover a bouncy touchdown, short enough that it's never what
/// stops somebody starting the next match.
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
        if x > solid.pos.x {
            trigger.cooling = COOLDOWN_SECS;
            trigger.skip_press = 1.0;
            bridge.skip_next_game();
        } else {
            // A game that hasn't finished warming cannot be started, only
            // waited for. Pressing anyway would have the party staring at a
            // lobby that ignored the button they just pushed — so the button
            // doesn't move either, and the screen above it goes on saying how
            // far along the loading is.
            if button == crate::gamenight::TvButton::Disabled {
                continue;
            }
            trigger.cooling = COOLDOWN_SECS;
            trigger.press = 1.0;
            bridge.press_tv_button();
        }
    }
}
