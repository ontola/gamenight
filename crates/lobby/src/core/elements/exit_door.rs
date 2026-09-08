use crate::prelude::*;

/// The way out of the party: walk into the doorway and you leave.
///
/// Every other way to leave is a menu — Start, then down, then Leave. That is
/// fine for the person holding the pad and invisible to everyone else, and in a
/// room where the whole proposition is that there are no menus it was the last
/// place you had to use one. A door is legible from the sofa: you can see
/// somebody walk out, and you can see the space they left.
///
/// Walking in, not landing on it. The sign-in wardrobe is a jump because a jump
/// is deliberate and a claim should be; leaving is a walk because leaving should
/// be as easy as standing up. The guard against doing it by accident is not
/// difficulty but *dwell* — you have to still be in the doorway a moment later,
/// which nobody is if they were only running past.
#[derive(HasSchema, Default, Debug, Clone)]
#[type_data(metadata_asset("exit_door"))]
#[repr(C)]
pub struct ExitDoorMeta {
    /// The opening, as a trigger region. The element's position is its centre.
    pub body_size: Vec2,
    /// How long a player has to stay inside the opening before they leave.
    ///
    /// This is the whole accident-guard. It is not a cooldown: the timer is per
    /// player and resets the moment they step out, so brushing the doorway on
    /// the way to the bookcase costs nothing.
    pub dwell_secs: f32,
    /// How long after leaving before that player's pad may rejoin.
    ///
    /// Without it, leaving is impossible to complete: `join_pad` treats any
    /// stick movement as "this pad wants in", and the stick you just walked
    /// through the door with is still pushed over. You would leave and rejoin
    /// in the same breath, forever.
    ///
    /// It also keeps this schema structurally distinct from `SignInMeta`, which
    /// is `{ Vec2, f32 }` — bones matches metadata assets by memory layout, so
    /// two identical shapes are interchangeable and whichever hydrate system
    /// runs first silently claims the other's elements. See `sign_in`'s test.
    pub rejoin_block_secs: f32,
}

pub fn game_plugin(game: &mut Game) {
    ExitDoorMeta::register_schema();
    game.init_shared_resource::<AssetServer>();
}

pub fn session_plugin(session: &mut SessionBuilder) {
    session
        .stages
        .add_system_to_stage(CoreStage::PreUpdate, hydrate)
        .add_system_to_stage(CoreStage::PostUpdate, update);
}

/// A hydrated doorway. Carries its own footprint so the bevy side can draw the
/// glow over it without resolving the asset every frame.
#[derive(Clone, Debug, HasSchema, Default)]
pub struct ExitDoor {
    pub size: Vec2,
    /// How far through leaving the player currently in the doorway is, 0 to 1.
    /// Drawn as a filling bar, so standing in a door is never a mystery.
    pub progress: f32,
    dwell_secs: f32,
    rejoin_block_secs: f32,
    /// Which seat is currently in the doorway, and for how long. Only one at a
    /// time: a doorway is one person wide, and tracking a set here would mean
    /// carrying a map in a component that is copied every frame.
    occupant: Option<(u32, f32)>,
}

fn hydrate(
    entities: Res<Entities>,
    mut hydrated: CompMut<MapElementHydrated>,
    element_handles: Comp<ElementHandle>,
    assets: Res<AssetServer>,
    mut doors: CompMut<ExitDoor>,
) {
    let mut not_hydrated_bitset = hydrated.bitset().clone();
    not_hydrated_bitset.bit_not();
    not_hydrated_bitset.bit_and(element_handles.bitset());

    for entity in entities.iter_with_bitset(&not_hydrated_bitset) {
        let element_handle = element_handles.get(entity).unwrap();
        let element_meta = assets.get(element_handle.0);

        if let Ok(ExitDoorMeta {
            body_size,
            dwell_secs,
            rejoin_block_secs,
        }) = assets.get(element_meta.data).try_cast_ref()
        {
            hydrated.insert(entity, MapElementHydrated);
            // No `Solid` and no collider: you walk into this one. The doorway's
            // tiles are written to the map as `Empty` for the same reason.
            doors.insert(
                entity,
                ExitDoor {
                    size: *body_size,
                    progress: 0.0,
                    dwell_secs: *dwell_secs,
                    rejoin_block_secs: *rejoin_block_secs,
                    occupant: None,
                },
            );
        }
    }
}

fn update(
    entities: Res<Entities>,
    mut doors: CompMut<ExitDoor>,
    player_indexes: Comp<PlayerIdx>,
    bodies: Comp<KinematicBody>,
    transforms: Comp<Transform>,
    time: Res<Time>,
    bridge: Option<ResMut<crate::gamenight::GameNightBridge>>,
) {
    let Some(mut bridge) = bridge else {
        // Standalone play: no party, so there is nothing to leave.
        return;
    };
    let dt = time.delta_seconds();

    for (door_entity, door) in entities.iter_with(&mut doors) {
        let Some(door_pos) = transforms.get(door_entity).map(|t| t.translation.truncate()) else {
            continue;
        };
        let half = door.size / 2.0;

        // Whoever is standing in the opening.
        //
        // Tested against the body's bounding box, not its transform: a
        // transform's origin sits at the feet for some bodies and the centre
        // for others, so a point test needs a band loose enough to catch both
        // and then catches players who are merely near the door. The box is
        // unambiguous — the same reason `player_landed_on` uses it.
        //
        // Grounded, because a player arcing through the top of the doorway
        // mid-jump has not gone anywhere, and the opening is tall enough to
        // jump through.
        let (left, right) = (door_pos.x - half.x, door_pos.x + half.x);
        let (bottom, top) = (door_pos.y - half.y, door_pos.y + half.y);
        let inside = entities
            .iter_with((&player_indexes, &bodies, &transforms))
            .find(|(_, (_, body, transform))| {
                if !body.is_on_ground {
                    return false;
                }
                let b = body.bounding_box(**transform);
                b.min.x < right && b.max.x > left && b.min.y < top && b.max.y > bottom
            })
            .map(|(_, (idx, _, _))| idx.0);

        match (inside, door.occupant) {
            (Some(seat), Some((held, elapsed))) if held == seat => {
                let elapsed = elapsed + dt;
                if elapsed >= door.dwell_secs {
                    bridge.request_exit(seat as u8, door.rejoin_block_secs);
                    door.occupant = None;
                    door.progress = 0.0;
                } else {
                    door.occupant = Some((seat, elapsed));
                    door.progress = elapsed / door.dwell_secs;
                }
            }
            // Somebody new stepped in, or the doorway just became occupied.
            (Some(seat), _) => {
                door.occupant = Some((seat, 0.0));
                door.progress = 0.0;
            }
            // Empty. Reset rather than pause: half a step through the door
            // should not be banked against your next walk past it.
            (None, _) => {
                door.occupant = None;
                door.progress = 0.0;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The doorway's metadata must not be mistakable for another element's.
    ///
    /// See `sign_in`'s test for the full story: bones resolves a metadata asset
    /// with `try_cast_ref`, which compares memory *representation*, so
    /// `ExitDoorMeta { Vec2, f32 }` would have been indistinguishable from
    /// `SignInMeta { Vec2, f32 }` and the doorway would have hydrated as a
    /// sign-in pad — a solid block filling the way out.
    #[test]
    fn exit_door_meta_has_its_own_layout() {
        ExitDoorMeta::register_schema();
        SignInMeta::register_schema();
        QrSignMeta::register_schema();
        NextGameTriggerMeta::register_schema();

        let door = ExitDoorMeta::schema();
        for (other, name) in [
            (SignInMeta::schema(), "SignInMeta"),
            (QrSignMeta::schema(), "QrSignMeta"),
            (NextGameTriggerMeta::schema(), "NextGameTriggerMeta"),
        ] {
            assert!(
                !door.represents(other),
                "ExitDoorMeta shares a layout with {name}, so bones cannot tell \
                 them apart and one hydrate system will steal the other's elements"
            );
        }
    }
}
