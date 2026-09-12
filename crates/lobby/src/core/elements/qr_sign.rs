use crate::prelude::*;

/// A blank signboard in the GameNight lobby whose face is painted with the
/// party's join QR code.
///
/// The pixels are drawn by the bevy layer (`gamenight::sync_lobby_qr_system`)
/// rather than here, because the code encodes a URL that isn't known until
/// the daemon hands us a session — and bones can't build a texture at
/// runtime: `Image` is either file data loaded by an `AssetLoader` or a
/// handle the external renderer already owns, and `AssetServer` has no
/// runtime insert. So the *placement* lives in the map, where it can be
/// moved and resized in the editor like any other element, and only the
/// image itself comes from outside.
#[derive(HasSchema, Default, Debug, Clone)]
#[type_data(metadata_asset("qr_sign"))]
#[repr(C)]
pub struct QrSignMeta {
    /// Size of the sign's face in world units. The bevy side matches the QR
    /// sprite to this, so resizing the sign in the editor resizes the code
    /// drawn on it.
    pub size: Vec2,
}

pub fn game_plugin(game: &mut Game) {
    QrSignMeta::register_schema();
    game.init_shared_resource::<AssetServer>();
}

pub fn session_plugin(session: &mut SessionBuilder) {
    session
        .stages
        .add_system_to_stage(CoreStage::PreUpdate, hydrate);
}

/// Marks a hydrated sign, and carries the size the bevy side should draw at
/// so it doesn't have to resolve the element asset again every frame.
#[derive(Clone, Debug, HasSchema, Default)]
pub struct QrSign {
    pub size: Vec2,
}

fn hydrate(
    entities: Res<Entities>,
    mut hydrated: CompMut<MapElementHydrated>,
    element_handles: Comp<ElementHandle>,
    assets: Res<AssetServer>,
    mut signs: CompMut<QrSign>,
) {
    let mut not_hydrated_bitset = hydrated.bitset().clone();
    not_hydrated_bitset.bit_not();
    not_hydrated_bitset.bit_and(element_handles.bitset());

    for entity in entities.iter_with_bitset(&not_hydrated_bitset) {
        let element_handle = element_handles.get(entity).unwrap();
        let element_meta = assets.get(element_handle.0);

        if let Ok(QrSignMeta { size }) = assets.get(element_meta.data).try_cast_ref() {
            hydrated.insert(entity, MapElementHydrated);
            signs.insert(entity, QrSign { size: *size });
            // Wall display only. The map provides the landing under sign-in;
            // the QR must not block movement or become an invisible collider.

        }
    }
}
