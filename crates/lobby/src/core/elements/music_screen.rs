use crate::prelude::*;

/// The jukebox's screen: a solid platform with the host's current track shown
/// in its face.
///
/// A platform rather than a floating panel, and always solid even when
/// there's nothing playing. Level geometry that appears and disappears with
/// somebody's Spotify would drop whoever was standing on it, so the slab is
/// always there and only what's *on* it comes and goes — see
/// `gamenight::sync_jukebox_system`, which leaves it blank when the room is
/// quiet.
///
/// Its own element rather than something the music buttons draw above
/// themselves, because where a platform sits is a level-design question: it
/// belongs in the map, next to everything else the party can stand on.
#[derive(HasSchema, Default, Debug, Clone)]
#[type_data(metadata_asset("music_screen"))]
#[repr(C)]
pub struct MusicScreenMeta {
    /// The lit part — what the track is written on.
    pub screen_size: Vec2,
    /// Slab around the screen, per side. Wider than it is tall, so there's
    /// somewhere to land.
    pub frame: Vec2,
}

pub fn game_plugin(game: &mut Game) {
    MusicScreenMeta::register_schema();
    game.init_shared_resource::<AssetServer>();
}

pub fn session_plugin(session: &mut SessionBuilder) {
    session
        .stages
        .add_system_to_stage(CoreStage::PreUpdate, hydrate);
}

#[derive(Clone, Debug, HasSchema, Default)]
pub struct MusicScreen {
    /// The lit part, copied off the meta so the bevy side can lay the card
    /// out without resolving the asset every frame.
    pub screen_size: Vec2,
    /// The whole slab, which is what players actually land on.
    pub size: Vec2,
}

fn hydrate(
    entities: Res<Entities>,
    mut hydrated: CompMut<MapElementHydrated>,
    element_handles: Comp<ElementHandle>,
    assets: Res<AssetServer>,
    mut screens: CompMut<MusicScreen>,
    mut solids: CompMut<Solid>,
    transforms: Comp<Transform>,
) {
    let mut not_hydrated_bitset = hydrated.bitset().clone();
    not_hydrated_bitset.bit_not();
    not_hydrated_bitset.bit_and(element_handles.bitset());

    for entity in entities.iter_with_bitset(&not_hydrated_bitset) {
        let element_handle = element_handles.get(entity).unwrap();
        let element_meta = assets.get(element_handle.0);

        if let Ok(MusicScreenMeta { screen_size, frame }) =
            assets.get(element_meta.data).try_cast_ref()
        {
            hydrated.insert(entity, MapElementHydrated);
            let size = *screen_size + *frame * 2.0;
            screens.insert(
                entity,
                MusicScreen {
                    screen_size: *screen_size,
                    size,
                },
            );
            solids.insert(
                entity,
                Solid {
                    disabled: false,
                    pos: transforms
                        .get(entity)
                        .map(|t| t.translation.truncate())
                        .unwrap_or_default(),
                    size,
                    ..default()
                },
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// bones resolves a metadata asset to a Rust type by memory layout, not by
    /// name, so a screen that happens to have the same shape as another
    /// element would be hydrated as that element instead. See `sign_in`'s test
    /// for the bug this guards against.
    #[test]
    fn the_music_screen_is_not_mistakable_for_another_element() {
        MusicScreenMeta::register_schema();
        MusicPadMeta::register_schema();
        SignInMeta::register_schema();
        QrSignMeta::register_schema();
        NextGameTriggerMeta::register_schema();

        let screen = MusicScreenMeta::schema();
        for (other, name) in [
            (MusicPadMeta::schema(), "MusicPadMeta"),
            (SignInMeta::schema(), "SignInMeta"),
            (QrSignMeta::schema(), "QrSignMeta"),
            (NextGameTriggerMeta::schema(), "NextGameTriggerMeta"),
        ] {
            assert!(
                !screen.represents(other),
                "MusicScreenMeta has the same layout as {name}, so bones cannot \
                 tell them apart and one hydrate system will steal the other's \
                 elements"
            );
        }
    }
}
