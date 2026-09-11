//! Room/outfit selection is presentation only; daemon identities stay unchanged.
use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};
const IDS: [&str; 5] = ["living-room", "underwater", "sky", "school", "gameroom"];
static CURRENT: once_cell::sync::Lazy<AtomicUsize> = once_cell::sync::Lazy::new(|| {
    AtomicUsize::new(index(&std::env::var("GAMENIGHT_LOBBY_THEME").unwrap_or_default()))
});
fn index(id: &str) -> usize { IDS.iter().position(|candidate| *candidate == id).unwrap_or(0) }
pub(super) fn selected(core: &CoreMeta) -> Option<&crate::core::metadata::LobbyThemeMeta> {
    let id = IDS[CURRENT.load(Ordering::Relaxed) % IDS.len()];
    core.lobby_themes.iter().find(|theme| theme.id.as_str() == id)
}
pub(super) fn cycle_theme(
    keys: bevy::prelude::Res<bevy::prelude::Input<bevy::prelude::KeyCode>>,
    game: bevy::prelude::ResMut<bones_bevy_renderer::BonesGame>,
) {
    if std::env::var("GAMENIGHT").as_deref() != Ok("1") { return; }
    if !keys.just_pressed(bevy::prelude::KeyCode::F6) { return; }
    let mut bridge = game.0.shared_resource_mut::<GameNightBridge>();
    if bridge.lobby_away { return; }
    let next = (CURRENT.load(Ordering::Relaxed) + 1) % IDS.len();
    CURRENT.store(next, Ordering::Relaxed);
    bridge.lobby_rebuild_at = Some(std::time::Instant::now());
    info!(theme = IDS[next], "lobby room and outfits changed");
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn theme_names_are_stable_and_unknown_names_fall_back() {
        for (i, name) in IDS.iter().enumerate() { assert_eq!(index(name), i); }
        assert_eq!(index("missing"), 0);
        assert_eq!(index(""), 0);
    }
}
