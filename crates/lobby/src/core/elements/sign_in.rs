use crate::prelude::*;

/// The lobby's sign-in platform: jump onto it and the big join QR on the wall
/// becomes *yours*.
///
/// This exists because per-character QR codes don't work in practice. A code
/// floating above each head has to be small enough not to swamp the arena,
/// and at that size a phone across the room can't read it — and with four
/// players there are four of them competing for attention.
///
/// Jumping on a pad is the couch-native way to say "me": one big scannable
/// code on the wall, and you point it at yourself by landing on the thing. No
/// typing, no picking your name off a list, no camera hunting for a 40-pixel
/// target.
///
/// "Last player to land here" rather than "player currently standing here"
/// on purpose — you hop on, walk over to the sign to scan it, and the code
/// is still yours while you do.
#[derive(HasSchema, Default, Debug, Clone)]
#[type_data(metadata_asset("sign_in"))]
#[repr(C)]
pub struct SignInMeta {
    /// The button itself: a solid block on the floor you land on top of to
    /// claim the QR. The element's position is its centre.
    pub body_size: Vec2,
    /// How long the pad ignores further landings after it fires, so one jump
    /// is one claim however many frames the physics takes to settle it.
    ///
    /// Walking past can't steal the code from whoever is mid-scan any more —
    /// that takes a jump now, which nobody does by accident on their way
    /// somewhere else.
    ///
    /// This field also keeps the schema structurally distinct from
    /// `QrSignMeta`, which matters more than it looks — bones'
    /// `try_cast_ref` matches on memory *representation*, not type
    /// identity, so two metadata types with the same layout are
    /// interchangeable. When this was `{ body_size: Vec2 }` alone it was
    /// identical to `QrSignMeta { size: Vec2 }`, and `qr_sign`'s hydrate —
    /// which runs first — claimed this element as a QR sign and marked it
    /// hydrated, so `sign_in` never saw it and no pad was ever drawn.
    pub cooldown_secs: f32,
}

pub fn game_plugin(game: &mut Game) {
    SignInMeta::register_schema();
    game.init_shared_resource::<AssetServer>();
}

pub fn session_plugin(session: &mut SessionBuilder) {
    session
        .stages
        .add_system_to_stage(CoreStage::PreUpdate, hydrate)
        .add_system_to_stage(CoreStage::PostUpdate, update);
}

#[derive(Clone, Debug, HasSchema, Default)]
pub struct SignInPad {
    /// Footprint, copied off the element meta so the bevy side can draw the
    /// pad without resolving the asset every frame.
    pub size: Vec2,
    /// How far the button is pushed in: 1 the moment somebody lands on it,
    /// easing back to 0 over `PAD_PRESS_SECONDS`.
    pub press: f32,
    /// Seconds left before this pad will fire again. See `cooldown_secs`.
    cooling: f32,
    cooldown_secs: f32,
}

fn hydrate(
    entities: Res<Entities>,
    mut hydrated: CompMut<MapElementHydrated>,
    element_handles: Comp<ElementHandle>,
    assets: Res<AssetServer>,
    mut pads: CompMut<SignInPad>,
    mut solids: CompMut<Solid>,
    transforms: Comp<Transform>,
) {
    let mut not_hydrated_bitset = hydrated.bitset().clone();
    not_hydrated_bitset.bit_not();
    not_hydrated_bitset.bit_and(element_handles.bitset());

    for entity in entities.iter_with_bitset(&not_hydrated_bitset) {
        let element_handle = element_handles.get(entity).unwrap();
        let element_meta = assets.get(element_handle.0);

        if let Ok(SignInMeta {
            body_size,
            cooldown_secs,
        }) = assets.get(element_meta.data).try_cast_ref()
        {
            hydrated.insert(entity, MapElementHydrated);
            // A solid, not a trigger: you bump into this one and you stand on
            // top of it.
            solids.insert(
                entity,
                Solid {
                    disabled: false,
                    pos: transforms
                        .get(entity)
                        .map(|t| t.translation.truncate())
                        .unwrap_or_default(),
                    size: *body_size,
                    ..default()
                },
            );
            pads.insert(
                entity,
                SignInPad {
                    size: *body_size,
                    press: 0.0,
                    cooling: 0.0,
                    cooldown_secs: *cooldown_secs,
                },
            );
        }
    }
}

fn update(
    entities: Res<Entities>,
    mut pads: CompMut<SignInPad>,
    solids: Comp<Solid>,
    player_indexes: Comp<PlayerIdx>,
    bodies: Comp<KinematicBody>,
    transforms: Comp<Transform>,
    time: Res<Time>,
    bridge: Option<ResMut<crate::gamenight::GameNightBridge>>,
) {
    let Some(mut bridge) = bridge else {
        // Standalone play: no party, nothing to sign in to.
        return;
    };
    let dt = time.delta_seconds();

    for (_, (pad, solid)) in entities.iter_with((&mut pads, &solids)) {
        pad.cooling = (pad.cooling - dt).max(0.0);
        pad.press = (pad.press - dt / PAD_PRESS_SECONDS).max(0.0);
        if pad.cooling > 0.0 {
            continue;
        }
        if let Some(seat_index) = player_landed_on(
            solid.pos,
            solid.size,
            &entities,
            &player_indexes,
            &bodies,
            &transforms,
        ) {
            pad.cooling = pad.cooldown_secs;
            pad.press = 1.0;
            // The *seat*, not the player id. A seat index is stable across a
            // party rebuild (the daemon clears players when the lobby
            // process restarts), so a code printed minutes ago still points
            // at the right chair. The server resolves seat -> player at the
            // moment of the claim instead of trusting a stale id.
            bridge.set_claim_seat(seat_index as u8);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Element metadata types must not share a memory layout.
    ///
    /// bones resolves a metadata asset to a Rust type with `try_cast_ref`,
    /// which checks `Schema::represents` — memory *representation*, not type
    /// identity. Two `#[repr(C)]` metas with the same fields are therefore
    /// interchangeable, and whichever hydrate system runs first silently
    /// claims the other's elements and marks them hydrated.
    ///
    /// That is not a hypothetical: `SignInMeta` was `{ body_size: Vec2 }`,
    /// identical to `QrSignMeta { size: Vec2 }`, so the sign-in pad was
    /// hydrated as a QR sign and never drawn at all.
    #[test]
    fn element_metas_do_not_share_a_layout() {
        SignInMeta::register_schema();
        QrSignMeta::register_schema();
        NextGameTriggerMeta::register_schema();

        let sign_in = SignInMeta::schema();
        let qr = QrSignMeta::schema();
        let tv = NextGameTriggerMeta::schema();

        assert!(
            !sign_in.represents(qr),
            "SignInMeta and QrSignMeta have the same layout, so bones cannot \
             tell them apart and one hydrate system will steal the other's \
             elements"
        );
        assert!(!sign_in.represents(tv), "SignInMeta collides with NextGameTriggerMeta");
        assert!(!qr.represents(tv), "QrSignMeta collides with NextGameTriggerMeta");
    }
}
