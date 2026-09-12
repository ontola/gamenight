use crate::prelude::*;

/// A pad on the lobby floor that controls the host's background music: jump
/// onto it to pause the record, or to skip the track.
///
/// The music is the one part of a game night that everybody has an opinion
/// about and nobody but the host can reach — it's their laptop, in the other
/// room, behind a lock screen. Putting pause and skip on the floor of the
/// lobby hands them to whoever is holding a controller, which is the whole
/// party rather than one person.
///
/// Inert and invisible whenever nothing is playing (see `update` and
/// `gamenight::sync_jukebox_system`): a pad for music that isn't on would do
/// nothing when stood on, and a lobby that offers controls for silence is
/// just clutter.
///
/// One element type for both jobs rather than two, because bones resolves a
/// metadata asset by memory *layout* — see `sign_in`'s test — and two pad
/// types with the same fields would be indistinguishable to it, each one
/// silently claiming the other's elements.
#[derive(HasSchema, Default, Debug, Clone)]
#[type_data(metadata_asset("music_pad"))]
#[repr(C)]
pub struct MusicPadMeta {
    /// The button itself: a solid block on the floor you land on top of.
    /// Low, because it's furniture in a room people are also fighting in —
    /// tall enough to be a thing you stand on, short enough not to be a wall.
    /// The element's position is its centre.
    pub body_size: Vec2,
    /// How long the pad ignores further landings after it fires. A player who
    /// jumps onto it means one press; a bounce, a sproinger launch or a
    /// landing the physics step resolves over two frames does not mean two.
    pub cooldown_secs: f32,
    /// `true` skips to the next track, `false` pauses (or resumes).
    pub skips: bool,
}

pub fn game_plugin(game: &mut Game) {
    MusicPadMeta::register_schema();
    game.init_shared_resource::<AssetServer>();
}

pub fn session_plugin(session: &mut SessionBuilder) {
    session
        .stages
        .add_system_to_stage(CoreStage::PreUpdate, hydrate)
        .add_system_to_stage(CoreStage::PostUpdate, update)
        // After `update`, which is what turns the pads solid: this is the
        // clean-up for the frame that happens on.
        .add_system_to_stage(CoreStage::PostUpdate, unstick);
}

#[derive(Clone, Debug, HasSchema, Default)]
pub struct MusicPad {
    /// Footprint, copied off the element meta so the bevy side can draw the
    /// pad without resolving the asset every frame.
    pub size: Vec2,
    pub skips: bool,
    /// How far the button is pushed in: 1 the moment somebody lands on it,
    /// easing back to 0 over `PAD_PRESS_SECONDS`. Driven by landings only —
    /// walking across a pad moves nothing, because nothing happened.
    pub press: f32,
    /// Seconds left before this pad will fire again. See `cooldown_secs`.
    cooling: f32,
    cooldown_secs: f32,
    /// Whether this pad was solid last frame, so `unstick` can tell the
    /// moment it *became* solid from the rest of the time it simply is.
    was_solid: bool,
}

fn hydrate(
    entities: Res<Entities>,
    mut hydrated: CompMut<MapElementHydrated>,
    element_handles: Comp<ElementHandle>,
    assets: Res<AssetServer>,
    mut pads: CompMut<MusicPad>,
    mut solids: CompMut<Solid>,
    transforms: Comp<Transform>,
) {
    let mut not_hydrated_bitset = hydrated.bitset().clone();
    not_hydrated_bitset.bit_not();
    not_hydrated_bitset.bit_and(element_handles.bitset());

    for entity in entities.iter_with_bitset(&not_hydrated_bitset) {
        let element_handle = element_handles.get(entity).unwrap();
        let element_meta = assets.get(element_handle.0);

        if let Ok(MusicPadMeta {
            body_size,
            cooldown_secs,
            skips,
        }) = assets.get(element_meta.data).try_cast_ref()
        {
            hydrated.insert(entity, MapElementHydrated);
            // A solid, not a trigger: you bump into this one and you stand on
            // top of it. Starts disabled — the music buttons only exist while
            // there's music, and an invisible block in the middle of the lobby
            // floor is the worst thing in this file that could happen.
            let pos = transforms
                .get(entity)
                .map(|t| t.translation.truncate())
                .unwrap_or_default();
            solids.insert(
                entity,
                Solid {
                    disabled: true,
                    pos,
                    size: *body_size,
                    ..default()
                },
            );
            pads.insert(
                entity,
                MusicPad {
                    size: *body_size,
                    skips: *skips,
                    press: 0.0,
                    cooling: 0.0,
                    cooldown_secs: *cooldown_secs,
                    was_solid: false,
                },
            );
        }
    }
}

fn update(
    entities: Res<Entities>,
    mut pads: CompMut<MusicPad>,
    mut solids: CompMut<Solid>,
    player_indexes: Comp<PlayerIdx>,
    bodies: Comp<KinematicBody>,
    transforms: Comp<Transform>,
    time: Res<Time>,
    // Read-only: a pad press is sent straight out to the daemon, and what's
    // playing comes back the same way everything else about the party does.
    bridge: Option<ResMut<crate::gamenight::GameNightBridge>>,
) {
    let Some(mut bridge) = bridge else {
        // Standalone play: no daemon, so no host music to speak of.
        return;
    };
    // Nothing playing: the buttons aren't drawn, so they're not there to be
    // jumped on or bumped into either. A control that fires invisibly is bad;
    // an invisible thing you can trip over is worse.
    let playing = bridge.now_playing().is_some();
    let dt = time.delta_seconds();

    for (entity, (pad, solid)) in entities.iter_with((&mut pads, &mut solids)) {
        solid.disabled = true;
        pad.cooling = (pad.cooling - dt).max(0.0);
        pad.press = (pad.press - dt / PAD_PRESS_SECONDS).max(0.0);
        let _ = entity;
        if !playing || pad.cooling > 0.0 {
            continue;
        }
        for seat in players_on_pad(solid.pos,solid.size,&entities,&player_indexes,&bodies,&transforms) {
            if !bridge.offer_interaction(seat, if pad.skips {"Next track"} else {"Play / pause music"}, Vec2::new(solid.pos.x, solid.pos.y-solid.size.y/2.)) {continue;}
            pad.cooling = pad.cooldown_secs;
            pad.press = 1.0;
            bridge.control_music(if pad.skips {
                gamenight_protocol::MediaAction::NextTrack
            } else {
                gamenight_protocol::MediaAction::PlayPause
            });
        }
    }
}

/// Lift anybody standing where a pad just appeared up on top of it.
///
/// The jukebox comes into being when the host starts a record, and its
/// buttons are solid furniture. Somebody idling on that spot was suddenly
/// inside a wall — walkable-into, not walkable-out-of — and stayed stuck
/// there until the music stopped.
///
/// Standing on top is the resolution rather than a shove sideways: it's
/// where they'd have ended up if the pad had been there all along, it can't
/// push anyone into a wall or off a ledge, and it needs no opinion about
/// which way "out" is.
///
/// Only on the frame a pad *becomes* solid. A system that continuously
/// pushed players out of anything they overlap would fight the physics for
/// every player merely leaning on something.
fn unstick(
    entities: Res<Entities>,
    mut pads: CompMut<MusicPad>,
    solids: Comp<Solid>,
    player_indexes: Comp<PlayerIdx>,
    bodies: Comp<KinematicBody>,
    mut transforms: CompMut<Transform>,
) {
    let mut appeared: Vec<(Vec2, Vec2)> = Vec::new();
    for (_, (pad, solid)) in entities.iter_with((&mut pads, &solids)) {
        let solid_now = !solid.disabled;
        if solid_now && !pad.was_solid {
            appeared.push((solid.pos, solid.size));
        }
        pad.was_solid = solid_now;
    }
    if appeared.is_empty() {
        return;
    }

    for (_, (_, body, transform)) in
        entities.iter_with((&player_indexes, &bodies, &mut transforms))
    {
        for (pos, size) in &appeared {
            let player = body.bounding_box(*transform);
            let left = pos.x - size.x / 2.0;
            let right = pos.x + size.x / 2.0;
            let bottom = pos.y - size.y / 2.0;
            let top = pos.y + size.y / 2.0;
            let overlaps = player.min.x < right
                && player.max.x > left
                && player.min.y < top
                && player.max.y > bottom;
            if !overlaps {
                continue;
            }
            // Keep the body's own offset from its feet, whatever the origin
            // happens to be, so this lands them on the surface rather than
            // halfway through it.
            let feet_offset = transform.translation.y - player.min.y;
            transform.translation.y = top + feet_offset;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Element metadata types must not share a memory layout — bones tells
    /// them apart by representation, not by name, so a collision means one
    /// element type quietly hydrates another's elements. See `sign_in`'s own
    /// test for the bug this is guarding against.
    #[test]
    fn the_music_pad_is_not_mistakable_for_another_element() {
        MusicPadMeta::register_schema();
        MusicScreenMeta::register_schema();
        SignInMeta::register_schema();
        QrSignMeta::register_schema();
        NextGameTriggerMeta::register_schema();

        let pad = MusicPadMeta::schema();
        for (other, name) in [
            (MusicScreenMeta::schema(), "MusicScreenMeta"),
            (SignInMeta::schema(), "SignInMeta"),
            (QrSignMeta::schema(), "QrSignMeta"),
            (NextGameTriggerMeta::schema(), "NextGameTriggerMeta"),
        ] {
            assert!(
                !pad.represents(other),
                "MusicPadMeta has the same layout as {name}, so bones cannot \
                 tell them apart and one hydrate system will steal the other's \
                 elements"
            );
        }
    }
}
