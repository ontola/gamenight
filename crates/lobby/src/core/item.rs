//! Common item code.
//!
//! An item is anything in the game that can be picked up by the player.

use crate::prelude::*;

pub fn install(session: &mut SessionBuilder) {
    Item::register_schema();
    ItemThrow::register_schema();
    ItemGrab::register_schema();
    DropItem::register_schema();
    ItemUsed::register_schema();
    AimFlick::register_schema();
    TumblingItem::register_schema();

    session
        .stages
        .add_system_to_stage(CoreStage::PreUpdate, track_aim_flicks)
        .add_system_to_stage(CoreStage::Last, grab_items)
        .add_system_to_stage(CoreStage::Last, drop_items)
        .add_system_to_stage(CoreStage::Last, throw_dropped_items)
        .add_system_to_stage(CoreStage::Last, upgrade_late_flicks)
        .add_system_to_stage(CoreStage::Last, settle_thrown_items);
}

/// A thrown item that is currently being simulated as a rigid body, and how
/// long it has been sitting still.
///
/// Items are kinematic the rest of the time — points that slide along a
/// velocity — which is right for something clipped to a player's hands and
/// wrong for something spinning through the air. So a throw hands the item to
/// the physics simulation, and it's handed back the moment it settles: a
/// musket lying on the floor doesn't need rapier thinking about it, and the
/// element code that watches for a crate hitting the ground reads the
/// kinematic body, which stops updating while the simulation owns it.
#[derive(Clone, Copy, Debug, Default, HasSchema)]
#[repr(C)]
pub struct TumblingItem {
    /// Where it was last frame, for noticing that it has stopped.
    last_pos: Vec2,
    /// How long it has been in more or less the same place.
    still_for: f32,
    /// How long it has been tumbling at all.
    age: f32,
    /// Whether anybody threw this at all. A weapon that fell out of the
    /// ceiling has no thrower, and `thrower` is then a default `Entity` —
    /// which is not a real one, and looking it up indexes the entity bitset
    /// out of bounds rather than politely returning `None`.
    thrown: bool,
    /// Who threw it, so a flick that lands just after the button can still
    /// count. See `upgrade_late_flicks`. Only meaningful when `thrown`.
    thrower: Entity,
    /// Which way it was thrown, so only a flick *that* way counts.
    dir: f32,
    /// Whether it already left as a hard throw, or has since become one.
    hard: bool,
    /// The collider it had before it went flying, to be put back when it
    /// lands. See [`tumble_shape`].
    resting_shape: ColliderShape,
}

/// How long after the throw a flick can still turn it into a hard one.
///
/// The pair to [`FLICK_WINDOW`], which covers a flick that lands *before* the
/// button. Between them the two give the same slack either side of the press:
/// "tap and throw" is one gesture performed by a hand, not two events the
/// game expects in a particular order, and demanding the order is what made
/// the hard throw feel impossible to get on purpose.
const LATE_FLICK_WINDOW: f32 = 0.2;

/// What a late flick multiplies the throw by — the gap between the held
/// throw it went out as and the flicked throw it should have been.
const LATE_FLICK_BOOST: f32 = 1.68;

/// Turn a throw that has just left your hands into a hard one, if the flick
/// arrives a moment late.
fn upgrade_late_flicks(
    entities: Res<Entities>,
    flicks: Comp<AimFlick>,
    mut tumbling: CompMut<TumblingItem>,
    mut dynamic_bodies: CompMut<DynamicBody>,
    time: Res<Time>,
) {
    let dt = time.delta_seconds();
    for (entity, tumble) in entities.iter_with(&mut tumbling) {
        if !tumble.thrown || tumble.hard || tumble.age > LATE_FLICK_WINDOW {
            continue;
        }
        // A flick this frame, in the direction the item is already going.
        let flicked_now = flicks
            .get(tumble.thrower)
            .is_some_and(|flick| flick.dir == tumble.dir && flick.dir != 0.0 && flick.age <= dt);
        if !flicked_now {
            continue;
        }
        tumble.hard = true;
        if let Some(dynamic_body) = dynamic_bodies.get_mut(entity) {
            dynamic_body.push_simulation_command(Box::new(move |rapier_body| {
                let boosted = *rapier_body.linvel() * LATE_FLICK_BOOST;
                rapier_body.set_linvel(boosted, true);
            }));
        }
    }
}

/// What a thrown item weighs, for the physics simulation.
///
/// Arbitrary but not meaningless: heavy enough to carry through a bounce and
/// shove nothing around (items only contact the world, never each other),
/// light enough to be tossed about by the throw velocities the game already
/// uses.
const ITEM_MASS: f32 = 40.0;

/// Hand `entity` to the physics simulation with a velocity and a spin, as a
/// throw does.
///
/// Public because a throw is not the only way an item ends up in the air: the
/// lobby drops weapons in from the ceiling, and one that falls like a point
/// and lands flat next to one that tumbled is a jarring pair.
#[allow(clippy::too_many_arguments)]
pub fn tumble_item(
    entity: Entity,
    at: Vec2,
    velocity: Vec2,
    spin: f32,
    resting_shape: ColliderShape,
    tumble_shape: ColliderShape,
    tumbling: &mut CompMut<TumblingItem>,
    dynamic_bodies: &mut CompMut<DynamicBody>,
    collision_world: &mut CollisionWorld,
) {
    let dynamic_body = dynamic_bodies.get_mut_or_insert(entity, DynamicBody::default);
    dynamic_body.is_dynamic = true;
    dynamic_body.push_simulation_command(Box::new(move |rapier_body| {
        rapier_body.set_additional_mass(ITEM_MASS, true);
        rapier_body.set_linvel(velocity.into(), true);
        rapier_body.set_angvel(spin, true);
    }));
    tumbling.insert(
        entity,
        TumblingItem {
            last_pos: at,
            resting_shape,
            ..default()
        },
    );
    collision_world.set_actor_shape(entity, tumble_shape);
}

/// How much of a sprite's tile counts as the object, once the transparent
/// margin around the art is discounted.
const SPRITE_FILL: f32 = 0.85;

/// A ceiling on that growth, so an item with a tiny collider under a big tile
/// doesn't become a barn door in flight.
const MAX_TUMBLE_GROWTH: f32 = 3.0;

/// The shape an item should have *while it's in the air*.
///
/// Items carry deliberately small colliders — a musket's is 32x8 under a
/// 92x32 sprite — which is right for a thing being carried and detected, and
/// wrong for a thing tumbling through a room: the gun pivots around a box in
/// its middle and buries its barrel in the floor. So the flight uses a shape
/// taken from the sprite instead, and the item gets its own back the moment
/// it settles, leaving pickup and resting behaviour exactly as they were.
pub fn tumble_shape(
    assets: &AssetServer,
    sprite: Option<&AtlasSprite>,
    resting: ColliderShape,
) -> ColliderShape {
    let Some(sprite) = sprite else {
        return resting;
    };
    // `get` panics on an atlas that hasn't finished loading, and items can be
    // thrown — or rained into the lobby — before every asset is in. A frame
    // with the ordinary collider is a far better outcome than a dead worker
    // thread.
    let Some(Ok(atlas)) = assets.try_get(sprite.atlas) else {
        return resting;
    };
    let ColliderShape::Rectangle { size } = resting else {
        return resting;
    };
    if size.x <= 0.0 {
        return resting;
    }
    // Grown to the sprite's length, keeping the proportions the item declares
    // for itself. A single scale factor off the tile can't serve both: a
    // musket's tile is 92x32 for a gun that is all barrel and no height, so
    // scaling the tile evenly gives a collider far too tall, while the item's
    // own 32x8 has the right shape and only wants to be longer.
    let scale = (atlas.tile_size.x * SPRITE_FILL / size.x).clamp(1.0, MAX_TUMBLE_GROWTH);
    ColliderShape::Rectangle { size: size * scale }
}

/// How much spin a throw imparts, per unit of speed — and the range it's held
/// to, so a gentle drop still turns over a little and a hard throw doesn't
/// become a blur.
const TUMBLE_PER_SPEED: f32 = 20.0;
const MIN_TUMBLE: f32 = 6.0;
const MAX_TUMBLE: f32 = 22.0;

/// How many orientations a tumbling item is drawn in.
///
/// Pixel art has no in-between angles: rotate a 32x8 musket by 37 degrees and
/// every edge resamples into a staircase that shimmers as it turns. Four
/// orientations are the ones that cost nothing — at 0, 90, 180 and 270
/// degrees each source pixel lands on exactly one screen pixel — so a thrown
/// gun snaps between them as it spins and stays as crisp as it is at rest.
///
/// Only the drawing is snapped. The simulation keeps its real angle, and is
/// told that the snapped one is what it handed us, so the two don't spend the
/// evening teleporting each other back and forth.
const DRAWN_ORIENTATIONS: f32 = 8.0;

/// How still (world units per frame) counts as settled.
const SETTLED_DISTANCE: f32 = 0.5;

/// How long it has to stay that still before the item goes back to being an
/// ordinary kinematic thing.
const SETTLED_FOR: f32 = 0.2;

/// A backstop for anything that never settles — resting on a slope, wedged
/// against a wall, endlessly nudged by a player standing on it.
const TUMBLE_LIMIT: f32 = 6.0;

/// Hand a thrown item back to the kinematic world once it has come to rest.
fn settle_thrown_items(
    entities: Res<Entities>,
    mut transforms: CompMut<Transform>,
    mut tumbling: CompMut<TumblingItem>,
    mut dynamic_bodies: CompMut<DynamicBody>,
    mut bodies: CompMut<KinematicBody>,
    mut collision_world: CollisionWorld,
    time: Res<Time>,
) {
    let dt = time.delta_seconds();
    let mut settled = Vec::new();
    for (entity, (tumble, transform)) in entities.iter_with((&mut tumbling, &mut transforms)) {
        // Snap what's drawn to a quarter turn, and tell the simulation that
        // this is what it gave us, so it doesn't treat the snap as gameplay
        // moving the body and teleport it back — which would stop it turning
        // altogether.
        let step = std::f32::consts::TAU / DRAWN_ORIENTATIONS;
        let angle = transform.rotation.to_euler(EulerRot::XYZ).2;
        let snapped = Quat::from_rotation_z((angle / step).round() * step);
        transform.rotation = snapped;
        if let Some(dynamic_body) = dynamic_bodies.get_mut(entity) {
            dynamic_body.update_last_rapier_synced_transform(transform.translation, snapped);
        }

        let pos = transform.translation.xy();
        if (pos - tumble.last_pos).length() < SETTLED_DISTANCE {
            tumble.still_for += dt;
        } else {
            tumble.still_for = 0.0;
        }
        tumble.last_pos = pos;
        tumble.age += dt;
        if tumble.still_for > SETTLED_FOR || tumble.age > TUMBLE_LIMIT {
            settled.push(entity);
        }
    }
    for entity in settled {
        if let Some(tumble) = tumbling.remove(entity) {
            collision_world.set_actor_shape(entity, tumble.resting_shape);
        }
        if let Some(dynamic_body) = dynamic_bodies.get_mut(entity) {
            dynamic_body.is_dynamic = false;
        }
        if let Some(body) = bodies.get_mut(entity) {
            // The simulation was moving it, so the kinematic body's idea of
            // its velocity is whatever it was at the throw. Handing that back
            // would make a settled item leap off across the floor.
            body.velocity = Vec2::ZERO;
            body.angular_velocity = 0.0;
        }
    }
}

/// How recently a player pressed the direction they're aiming.
///
/// Kept per player rather than read off the control, because the control only
/// says *where* the stick is, and a throw needs to know whether it just got
/// there.
#[derive(Clone, Copy, Debug, Default, HasSchema)]
#[repr(C)]
pub struct AimFlick {
    /// Which way they're aiming: -1, 0 or 1.
    dir: f32,
    /// Seconds they've been aiming that way.
    age: f32,
}

/// How fresh a direction has to be to count as flicked rather than held.
///
/// Long enough that "tap and press" is a thing hands can do while also
/// fighting, short enough that running across the room and letting go isn't
/// secretly the strongest throw in the game.
const FLICK_WINDOW: f32 = 0.3;

/// Anything past this counts as aiming; below it the stick is centred.
const AIM_DEADZONE: f32 = 0.2;

impl AimFlick {
    fn flicked(&self) -> bool {
        self.dir != 0.0 && self.age <= FLICK_WINDOW
    }
}

fn track_aim_flicks(
    entities: Res<Entities>,
    player_indexes: Comp<PlayerIdx>,
    player_inputs: Res<MatchInputs>,
    mut flicks: CompMut<AimFlick>,
    time: Res<Time>,
) {
    let dt = time.delta_seconds();
    for (entity, player_idx) in entities.iter_with(&player_indexes) {
        let x = player_inputs.players[player_idx.0 as usize]
            .control
            .move_direction
            .x;
        let dir = if x.abs() > AIM_DEADZONE {
            x.signum()
        } else {
            0.0
        };
        let was = flicks.get(entity).copied().unwrap_or_default();
        flicks.insert(
            entity,
            AimFlick {
                dir,
                age: if was.dir == dir { was.age + dt } else { 0.0 },
            },
        );
    }
}

/// Marker component for items.
///
/// Items are any entity that players can pick up and use.
#[derive(Clone, Copy, HasSchema, Default)]
#[repr(C)]
pub struct Item;

/// An intventory component, indicating another entity that the player is carrying.
#[derive(Clone, HasSchema, Default, Deref, DerefMut)]
pub struct Inventory(pub Option<Entity>);

/// Marker component that may be added to an item to cause it to be droped by a player.
#[derive(Clone, HasSchema, Default)]
#[repr(C)]
pub struct DropItem;

/// A helper struct containing a player-inventory pair that indicates the given player is holding
/// the other entity in their inventory.
#[derive(Debug, Clone, Copy)]
pub struct Inv {
    pub player: Entity,
    pub inventory: Entity,
}

/// System param that can be used to conveniently get the inventory of each player.
#[derive(Deref, DerefMut, Debug)]
pub struct PlayerInventories<'a>(&'a [Option<Inv>; MAX_PLAYERS as usize]);

impl PlayerInventories<'_> {
    pub fn find_item(&self, item: Entity) -> Option<Inv> {
        self.0
            .iter()
            .find_map(|i| i.filter(|inv| inv.inventory == item))
    }
}

impl<'a> SystemParam for PlayerInventories<'a> {
    type State = [Option<Inv>; MAX_PLAYERS as usize];
    type Param<'s> = PlayerInventories<'s>;

    fn get_state(world: &World) -> Self::State {
        world.run_system(
            |entities: Res<Entities>,
             player_indexes: Comp<PlayerIdx>,
             inventories: Comp<Inventory>| {
                let mut player_inventories = [None; MAX_PLAYERS as usize];
                for (player, (idx, inventory)) in
                    entities.iter_with((&player_indexes, &inventories))
                {
                    if let Some(inventory) = inventory.0 {
                        player_inventories[idx.0 as usize] = Some(Inv { player, inventory });
                    }
                }

                player_inventories
            },
            (),
        )
    }

    fn borrow<'s>(_world: &'s World, state: &'s mut Self::State) -> Self::Param<'s> {
        PlayerInventories(state)
    }
}

/// Marker component added to items when they are dropped.
#[derive(Clone, Copy, HasSchema, Default)]
pub struct ItemDropped {
    /// The player that dropped the item
    pub player: Entity,
}

/// Marker component added to items when they are grabbed.
#[derive(Clone, Copy, HasSchema, Default)]
pub struct ItemGrabbed {
    /// The player that grabbed the item
    pub player: Entity,
}

/// Marker component added to items when they are used.
#[derive(Clone, Copy, HasSchema, Default)]
#[repr(C)]
pub struct ItemUsed {
    /// The player that used the item
    pub owner: Entity,
}

/// Component defining the grab settings when an item is grabbed.
///
/// Mainly handled by the [`grab_items`] system which consumes the
/// [`ItemGrabbed`] components for entities which have this component.
/// [`Item`] is required for the system to take affect.
#[derive(Clone, HasSchema, Default)]
#[repr(C)]
pub struct ItemGrab {
    pub fin_anim: Ustr,
    pub grab_offset: Vec2,
    pub sync_animation: bool,
}

/// Drop items that have the `DropItem` component added to them.
pub fn drop_items(
    mut commands: Commands,
    mut drop_items: CompMut<DropItem>,
    player_inventories: PlayerInventories,
) {
    for Inv { player, inventory } in player_inventories.iter().flatten() {
        if drop_items.remove(*inventory).is_some() {
            commands.add(PlayerCommand::set_inventory(*player, None));
        }
    }
}

pub fn grab_items(
    entities: Res<Entities>,
    item_grab: Comp<ItemGrab>,
    items: Comp<Item>,
    mut items_grabbed: CompMut<ItemGrabbed>,
    mut tumbling: CompMut<TumblingItem>,
    mut dynamic_bodies: CompMut<DynamicBody>,
    mut bodies: CompMut<KinematicBody>,
    mut attachments: CompMut<PlayerBodyAttachment>,
    mut player_layers: CompMut<PlayerLayers>,
) {
    for (entity, (_item, item_grab)) in entities.iter_with((&items, &item_grab)) {
        let ItemGrab {
            fin_anim,
            grab_offset,
            sync_animation,
        } = *item_grab;

        if let Some(ItemGrabbed { player }) = items_grabbed.remove(entity) {
            // Whatever it was doing in the air, it's in somebody's hands now.
            tumbling.remove(entity);
            if let Some(dynamic_body) = dynamic_bodies.get_mut(entity) {
                dynamic_body.is_dynamic = false;
            }
            player_layers.get_mut(player).unwrap().fin_anim = fin_anim;

            if let Some(body) = bodies.get_mut(entity) {
                body.is_deactivated = true
            }

            attachments.insert(
                entity,
                PlayerBodyAttachment {
                    player,
                    sync_animation,
                    sync_color: false,
                    head: false,
                    offset: grab_offset.extend(PlayerLayers::FIN_Z_OFFSET / 2.0),
                },
            );
        }
    }
}

/// Component defining the strength of the throw types when an item is dropped.
///
/// Mainly handled by the [`throw_dropped_items`] system which consumes the
/// [`ItemDropped`] components for entities which have this component.
/// [`Item`] is required for the system to take affect.
#[derive(Clone, HasSchema)]
#[repr(C)]
pub struct ItemThrow {
    normal: Vec2,
    fast: Vec2,
    /// A held direction rather than a flicked one — see
    /// [`Self::velocity_from_control`].
    medium: Vec2,
    up: Vec2,
    drop: Vec2,
    lob: Vec2,
    roll: Vec2,
    spin: f32,
    #[schema(opaque)]
    /// An optional system value that gets run once on throw.
    system: Option<Arc<AtomicCell<StaticSystem<(), ()>>>>,
}

impl Default for ItemThrow {
    fn default() -> Self {
        Self::base()
    }
}

impl ItemThrow {
    /// The relative velocities of each different throw type.
    ///
    /// This is multiiplied by the desired throw strength in [`Self::strength`] to get a deafault
    /// throw pattern from a single velocity.
    pub fn base() -> Self {
        Self {
            normal: Vec2::new(1.5, 1.2).normalize() * 0.6,
            fast: Vec2::new(1.5, 1.2).normalize() * 1.6,
            medium: Vec2::new(1.5, 1.2).normalize() * 0.95,
            up: Vec2::new(0.0, 1.1),
            drop: Vec2::new(0.0, 0.0),
            lob: Vec2::new(1.0, 2.5).normalize() * 1.1,
            roll: Vec2::new(0.4, -0.1),
            spin: 0.0,
            system: None,
        }
    }

    /// [`Self::base`] with the throw values multiplied by `strength`.
    pub fn strength(strength: f32) -> Self {
        let base = Self::base();
        Self {
            normal: base.normal * strength,
            fast: base.fast * strength,
            medium: base.medium * strength,
            up: base.up * strength,
            drop: base.drop * strength,
            lob: base.lob * strength,
            roll: base.roll * strength,
            spin: 0.0,
            system: None,
        }
    }

    pub fn with_spin(self, spin: f32) -> Self {
        Self { spin, ..self }
    }

    pub fn with_system<Args, I>(self, system: I) -> Self
    where
        I: IntoSystem<Args, (), (), Sys = StaticSystem<(), ()>>,
    {
        Self {
            system: Some(Arc::new(AtomicCell::new(system.system()))),
            ..self
        }
    }

    /// Chooses one of the throw values based on a [`PlayerControl`], and on
    /// whether the aim was *flicked* — pressed in the same moment as the
    /// throw — or was simply already being held.
    ///
    /// That distinction is the whole difference between putting something
    /// down and throwing it at someone. Aiming nowhere drops it at your feet;
    /// running in a direction and letting go sends it that way at a
    /// reasonable pace; snapping the stick over as you press throws it hard.
    /// The last one has to be earned by timing, or every throw would be the
    /// hardest one and there'd be no choice left to make.
    pub fn velocity_from_control(&self, player_control: &PlayerControl, flicked: bool) -> Vec2 {
        let PlayerControl { move_direction, .. } = player_control;
        let y = move_direction.y;
        let moving = move_direction.x.abs() > 0.0;
        if y < 0.0 {
            if moving {
                return self.roll;
            } else {
                return self.drop;
            }
        }
        if moving {
            if y > 0.0 {
                self.lob
            } else if flicked {
                self.fast
            } else {
                self.medium
            }
        } else if y > 0.0 {
            self.up
        } else {
            self.normal
        }
    }
}

pub fn throw_dropped_items(
    entities: Res<Entities>,
    item_throws: Comp<ItemThrow>,
    items: Comp<Item>,
    player_inputs: Res<MatchInputs>,
    player_indexes: Comp<PlayerIdx>,
    mut items_dropped: CompMut<ItemDropped>,
    mut bodies: CompMut<KinematicBody>,
    mut attachments: CompMut<PlayerBodyAttachment>,
    mut sprites: CompMut<AtlasSprite>,
    mut transforms: CompMut<Transform>,
    item_spawners: Comp<DehydrateOutOfBounds>,
    map_layers: Comp<SpawnedMapLayerMeta>,
    player_spawnwers: Comp<PlayerSpawner>,
    flicks: Comp<AimFlick>,
    mut tumbling: CompMut<TumblingItem>,
    mut dynamic_bodies: CompMut<DynamicBody>,
    assets: Res<AssetServer>,
    mut collision_world: CollisionWorld,
    mut commands: Commands,
) {
    // Collected and applied at the end: changing a collider borrows the
    // collision world, which this loop is already holding open.
    let mut reshape: Vec<(Entity, ColliderShape)> = Vec::new();
    for (entity, (_items, item_throw, transform)) in
        entities.iter_with((&items, &item_throws, &mut transforms))
    {
        if let Some(ItemDropped { player }) = items_dropped.get(entity).cloned() {
            if let Some(system) = item_throw.system.clone() {
                commands.add(move |world: &World| (system.borrow_mut().run)(world, ()));
            }
            items_dropped.remove(entity);
            attachments.remove(entity);

            let player_sprite = sprites.get_mut(player).unwrap();

            let horizontal_flip_factor = if player_sprite.flip_x {
                Vec2::new(-1.0, 1.0)
            } else {
                Vec2::ONE
            };

            let flicked = flicks.get(player).is_some_and(AimFlick::flicked);
            let throw_velocity = item_throw.velocity_from_control(
                &player_inputs.players[player_indexes.get(player).unwrap().0 as usize].control,
                flicked,
            );

            // Use the item's spawner depth as the drop depth
            if let Some(item_spawner) = item_spawners.get(entity) {
                let map_layer = map_layers.get(item_spawner.0).unwrap();
                transform.translation.z = z_depth_for_map_layer(map_layer.layer_idx);
            } else {
                // Grab a random player spawner and use that for the z depth
                let (_, (_, layer)) = entities
                    .iter_with((&player_spawnwers, &map_layers))
                    .next()
                    .unwrap();
                transform.translation.z = z_depth_for_map_layer(layer.layer_idx);
            }

            if let Some(body) = bodies.get_mut(entity) {
                debug!(
                    aim = ?player_inputs.players[player_indexes.get(player).unwrap().0 as usize]
                        .control
                        .move_direction,
                    flick = ?flicks.get(player),
                    velocity = ?throw_velocity,
                    "item thrown"
                );
                let velocity = throw_velocity * horizontal_flip_factor;
                body.velocity = velocity;
                body.angular_velocity =
                    item_throw.spin * horizontal_flip_factor.x * throw_velocity.y.signum();

                body.is_deactivated = false;

                // Hand it to the physics simulation for the flight: it leaves
                // your hands as a real object that tumbles, bounces off the
                // furniture and lands however it lands, instead of a point
                // sliding along a parabola. `settle_thrown_items` takes it
                // back once it stops.
                let spin = (velocity.length() / TUMBLE_PER_SPEED).clamp(MIN_TUMBLE, MAX_TUMBLE)
                    * -horizontal_flip_factor.x;
                let dynamic_body = dynamic_bodies.get_mut_or_insert(entity, DynamicBody::default);
                dynamic_body.is_dynamic = true;
                dynamic_body.push_simulation_command(Box::new(move |rapier_body| {
                    // Mass first, and explicitly. An item's collider is a
                    // sensor while it's kinematic, so the body it belongs to
                    // carries no mass properties of its own — which makes a
                    // torque impulse (scaled by an angular inertia of zero)
                    // exactly nothing, and gives contacts nothing to push
                    // against. The ragdoll does the same thing for the same
                    // reason.
                    rapier_body.set_additional_mass(ITEM_MASS, true);
                    rapier_body.set_linvel(velocity.into(), true);
                    // Set rather than impulse, so the spin doesn't depend on
                    // an inertia we've just had to invent.
                    rapier_body.set_angvel(spin, true);
                }));
                let resting_shape = body.shape;
                tumbling.insert(
                    entity,
                    TumblingItem {
                        last_pos: transform.translation.xy(),
                        thrown: true,
                        thrower: player,
                        dir: -horizontal_flip_factor.x,
                        hard: flicked,
                        resting_shape,
                        ..default()
                    },
                );
                reshape.push((
                    entity,
                    tumble_shape(&assets, sprites.get(entity), resting_shape),
                ));
            }
        }
    }

    for (entity, shape) in reshape {
        collision_world.set_actor_shape(entity, shape);
    }
}
