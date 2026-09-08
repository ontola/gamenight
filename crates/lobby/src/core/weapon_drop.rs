//! Weapons falling into the lobby on a timer.
//!
//! The lobby is where the party waits, and waiting with a controller in your
//! hand means fighting whoever else is waiting. A map with nothing to pick up
//! is a map where that fizzles out after a minute, so the room hands out a
//! weapon every so often and takes it back if nobody wants it — the arena
//! restocks itself, without anyone having to lay out spawners by hand.
//!
//! Lobby-only, decided by what's on the map rather than by a flag: a real
//! match has its own item spawners placed deliberately, and raining muskets
//! into someone's carefully built level would be vandalism.

use crate::prelude::*;

/// How often a weapon drops.
const DROP_EVERY: f32 = 10.0;

/// How long a dropped weapon lies around before it's cleared away.
///
/// Long enough that somebody crossing the room can still reach it, short
/// enough that the floor doesn't silt up with muskets over an evening — which
/// is the actual failure mode here, since nothing else in the lobby ever
/// removes them.
const DROP_LIFETIME: f32 = 30.0;

/// Where drops come from, measured up from the top of the map's floor. High
/// enough to fall past the ledges and be seen coming.
const DROP_HEIGHT: f32 = 480.0;

/// Marks a weapon this system dropped, and how long it has been lying there.
///
/// Sits on the *element* entity, which is not the weapon: hydrating a weapon
/// element turns it into a spawner and puts the thing you can actually pick
/// up on a second entity that points back at it (`DehydrateOutOfBounds`).
/// Clearing one therefore means clearing both — killing the spawner alone
/// leaves the musket lying on the floor with nothing left to tidy it up,
/// which is exactly what it did the first time.
///
/// Deliberately not [`Lifetime`], which kills whatever it's on the moment the
/// clock runs out. These expire in a room full of people picking things up,
/// and a musket that evaporates out of somebody's hands mid-shot — leaving
/// their inventory pointing at a dead entity — is a worse bug than a tidy
/// floor is a feature. So the clock only runs while nobody is holding it.
#[derive(Clone, Debug, HasSchema, Default)]
pub struct DroppedWeapon {
    /// How long since it fell into the room. Counts always, held or not.
    age: f32,
    /// Its time is up, but somebody is carrying it — so it goes the moment
    /// they put it down.
    expired: bool,
    /// Whether the item this element spawned has been handed to the physics
    /// simulation yet.
    launched: bool,
}

/// Keeps the drop timer between frames.
#[derive(Clone, Debug, HasSchema, Default)]
pub struct WeaponDrops {
    /// Seconds until the next one. Starts at zero so the first weapon lands
    /// as soon as the lobby comes up rather than ten seconds into an empty
    /// room.
    next_in: f32,
}

pub fn session_plugin(session: &mut SessionBuilder) {
    WeaponDrops::register_schema();
    DroppedWeapon::register_schema();
    session
        .stages
        .add_system_to_stage(CoreStage::Last, drop_a_weapon)
        .add_system_to_stage(CoreStage::Last, launch_new_weapons)
        .add_system_to_stage(CoreStage::Last, clear_expired_weapons);
}

/// Give a freshly spawned weapon the same physics a thrown one gets, so it
/// tumbles in and lands at whatever angle it lands at.
///
/// It happens here rather than at spawn because the thing you can pick up
/// doesn't exist yet when the element is placed: hydrating a weapon element
/// turns it into a spawner, and the item appears on its own entity a frame
/// later.
fn launch_new_weapons(
    entities: Res<Entities>,
    mut dropped: CompMut<DroppedWeapon>,
    spawned_from: Comp<DehydrateOutOfBounds>,
    bodies: Comp<KinematicBody>,
    transforms: Comp<Transform>,
    atlas_sprites: Comp<AtlasSprite>,
    assets: Res<AssetServer>,
    rng: Res<GlobalRng>,
    mut tumbling: CompMut<TumblingItem>,
    mut dynamic_bodies: CompMut<DynamicBody>,
    mut collision_world: CollisionWorld,
) {
    let mut launch = Vec::new();
    for (element, weapon) in entities.iter_with(&mut dropped) {
        if weapon.launched {
            continue;
        }
        for (item, from) in entities.iter_with(&spawned_from) {
            if **from == element {
                weapon.launched = true;
                launch.push(item);
            }
        }
    }
    for item in launch {
        let Some(body) = bodies.get(item) else { continue };
        let Some(transform) = transforms.get(item) else {
            continue;
        };
        // A little sideways drift and a lazy turn, so a dropped weapon reads
        // as falling into the room rather than being placed in it.
        let drift = (rng.f32() - 0.5) * 120.0;
        let spin = (rng.f32() - 0.5) * 24.0;
        debug!(?item, "launching a dropped weapon into the room");
        tumble_item(
            item,
            transform.translation.xy(),
            vec2(drift, 0.0),
            spin,
            body.shape,
            tumble_shape(&assets, atlas_sprites.get(item), body.shape),
            &mut tumbling,
            &mut dynamic_bodies,
            &mut collision_world,
        );
    }
}

/// Take the dropped weapons back after their time is up.
///
/// The clock runs from the moment it fell, and does not restart when somebody
/// picks it up. It used to: "thirty seconds untouched" sounds reasonable until
/// you watch one evening of it, where the guns people actually use are the
/// ones that live forever and the floor fills with exactly the weapons nobody
/// wanted cleared. A hard age is the only version with a bound on it.
///
/// The one thing it won't do is take a gun out of somebody's hands — that
/// leaves their inventory pointing at a dead entity, and it's a rotten thing
/// to do mid-fight. So an expired weapon that's being carried is marked, and
/// goes the moment it's put down.
fn clear_expired_weapons(
    mut entities: ResMutInit<Entities>,
    mut dropped: CompMut<DroppedWeapon>,
    spawned_from: Comp<DehydrateOutOfBounds>,
    inventories: Comp<Inventory>,
    attachments: Comp<PlayerBodyAttachment>,
    time: Res<Time>,
) {
    // Held: in an inventory, or still pinned to a player's hands. Two ways of
    // asking because a stale inventory entry would otherwise make a weapon
    // immortal, and an unattached one is on the floor whatever a player's
    // inventory happens to still say.
    let held: HashSet<Entity> = entities
        .iter_with(&inventories)
        .filter_map(|(_, inventory)| inventory.0)
        .collect();

    let mut spawned: HashMap<Entity, Vec<Entity>> = HashMap::default();
    for (item, from) in entities.iter_with(&spawned_from) {
        spawned.entry(**from).or_default().push(item);
    }

    let dt = time.delta_seconds();
    let mut done: Vec<Entity> = Vec::new();
    for (element, weapon) in entities.iter_with(&mut dropped) {
        weapon.age += dt;
        if weapon.age <= DROP_LIFETIME {
            continue;
        }
        weapon.expired = true;
        let items = spawned.get(&element).cloned().unwrap_or_default();
        let in_hand = items
            .iter()
            .chain([&element])
            .any(|e| held.contains(e) || attachments.contains(*e));
        if in_hand {
            continue;
        }
        debug!(?element, items = items.len(), "clearing an expired weapon");
        done.push(element);
        done.extend(items);
    }
    for entity in done {
        entities.kill(entity);
    }
}

fn drop_a_weapon(
    mut entities: ResMutInit<Entities>,
    mut drops: ResMutInit<WeaponDrops>,
    mut transforms: CompMut<Transform>,
    mut element_handles: CompMut<ElementHandle>,
    mut dropped: CompMut<DroppedWeapon>,
    mut layers: CompMut<SpawnedMapLayerMeta>,
    player_spawners: Comp<PlayerSpawner>,
    triggers: Comp<NextGameTrigger>,
    player_indices: Comp<PlayerIdx>,
    time: Res<Time>,
    assets: Res<AssetServer>,
    meta: Root<GameMeta>,
    map: Res<LoadedMap>,
    rng: Res<GlobalRng>,
) {
    // The next-game cabinet only exists in the lobby, which makes its
    // presence the honest answer to "are we the lobby?" — no flag to forget
    // to set, and a map that doesn't have one is somebody's real level.
    if entities.iter_with(&triggers).next().is_none() {
        return;
    }

    // Nothing falls into an empty room. Weapons exist so that people waiting
    // with a controller have something to do with each other; raining muskets
    // onto nobody just litters the floor before the party arrives, and it is
    // the first thing a newcomer sees. The timer does not start until someone
    // is actually here.
    if entities.iter_with(&player_indices).next().is_none() {
        drops.next_in = DROP_EVERY;
        return;
    }

    drops.next_in -= time.delta_seconds();
    if drops.next_in > 0.0 {
        return;
    }
    drops.next_in = DROP_EVERY;

    let weapons: Vec<_> = meta
        .core
        .map_elements
        .iter()
        .filter(|handle| assets.get(**handle).category == ustr("Weapons"))
        .copied()
        .collect();
    let Some(weapon) = rng.sample(&weapons) else {
        return;
    };

    // Anywhere across the map's width, with a margin so nothing lands inside
    // the walls. Falls from above, so it settles on whatever the party has
    // been standing on rather than needing a list of surfaces here.
    let width = map.grid_size.x as f32 * map.tile_size.x;
    let margin = map.tile_size.x * 2.0;
    let x = margin + rng.f32() * (width - margin * 2.0);

    // Which map layer this belongs to. Not decoration: dropping an item asks
    // its spawner what layer it came from and unwraps the answer, so a weapon
    // spawned without one crashes the game the first time somebody puts it
    // down. Borrowed from a player spawner, the same place the item code
    // falls back to when there's no spawner at all.
    let layer_idx = entities
        .iter_with((&player_spawners, &layers))
        .next()
        .map(|(_, (_, layer))| layer.layer_idx)
        .unwrap_or_default();

    let entity = entities.create();
    transforms.insert(
        entity,
        Transform::from_translation(vec3(x, DROP_HEIGHT, z_depth_for_map_layer(layer_idx))),
    );
    element_handles.insert(entity, ElementHandle(*weapon));
    layers.insert(entity, SpawnedMapLayerMeta { layer_idx });
    dropped.insert(entity, default());
}
