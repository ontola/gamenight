//! Players' own projects on the shelf (a vibecoded Warp game, a mod of one):
//! the game id a host gives one, so the host, the phone and the assistant
//! all name it the same way.

/// A short, stable tag for an owner (`account:<id>`), so two players'
/// projects with the same id stay two games.
fn owner_tag(owner: &str) -> String {
    owner
        .bytes()
        .fold(0u32, |h, b| h.wrapping_mul(31).wrapping_add(b.into()))
        .to_string()
}

/// The shelf id of `owner`'s project `id`.
pub fn game_id(owner: &str, id: &str) -> String {
    format!("project-{id}-{}", owner_tag(owner))
}

/// Whether the game `game` is one of `owner`'s own projects.
pub fn owned_by(game: &str, owner: &str) -> bool {
    game.strip_prefix("project-")
        .and_then(|rest| rest.strip_suffix(&owner_tag(owner)))
        .is_some_and(|id| id.len() > 1 && id.ends_with('-'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_project_is_known_as_its_owners() {
        let id = game_id("account:ada", "neon-siege-mod-1a2b");
        assert!(id.starts_with("project-neon-siege-mod-1a2b-"));
        assert!(owned_by(&id, "account:ada"));
        assert!(!owned_by(&id, "account:bob"));
        assert!(!owned_by("neon-siege-warp", "account:ada"));
        // The cloud names them the same way (gamenight-cloud session_agent).
        assert_eq!(game_id("account:ada", "x"), "project-x-865370577");
    }
}
