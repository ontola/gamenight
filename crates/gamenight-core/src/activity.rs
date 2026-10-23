//! The room log: what changed between two party snapshots, in words.
//!
//! The daemon compares every snapshot it broadcasts with the previous one, so
//! no command handler has to remember to log. Things a snapshot cannot show
//! (a round ending, a game's own note) the daemon adds itself.

use gamenight_protocol::{
    ActivityKind, GameId, PartySnapshot, PlayerId, SettingSpec, SettingValue,
};
use std::collections::HashMap;

/// One line before the daemon stamps it with an id and a time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Change {
    pub kind: ActivityKind,
    pub text: String,
    pub game: Option<GameId>,
    /// Who it is about, so the daemon can fold lines together.
    pub player: Option<PlayerId>,
}

impl Change {
    pub fn new(kind: ActivityKind, text: String) -> Self {
        Self {
            kind,
            text,
            game: None,
            player: None,
        }
    }

    fn about(mut self, player: PlayerId) -> Self {
        self.player = Some(player);
        self
    }

    fn in_game(mut self, game: &GameId) -> Self {
        self.game = Some(game.clone());
        self
    }
}

/// A game's display title, or its id when the shelf does not know it.
pub fn title(party: &PartySnapshot, game: &GameId) -> String {
    party
        .library
        .iter()
        .find(|meta| &meta.id == game)
        .map(|meta| meta.title.clone())
        .unwrap_or_else(|| game.0.clone())
}

/// Everything worth a log line between `before` and `after`.
pub fn changes(before: &PartySnapshot, after: &PartySnapshot) -> Vec<Change> {
    let mut out = Vec::new();
    let old_names: HashMap<PlayerId, &str> = before
        .players
        .iter()
        .map(|p| (p.id, p.name.as_str()))
        .collect();
    let new_names: HashMap<PlayerId, &str> = after
        .players
        .iter()
        .map(|p| (p.id, p.name.as_str()))
        .collect();
    let name = |id: &PlayerId| {
        new_names
            .get(id)
            .or_else(|| old_names.get(id))
            .copied()
            .unwrap_or("Someone")
            .to_string()
    };

    for player in &after.players {
        match old_names.get(&player.id) {
            None => out.push(
                Change::new(ActivityKind::Joined, format!("{} joined", player.name))
                    .about(player.id),
            ),
            Some(old) if *old != player.name => out.push(
                Change::new(
                    ActivityKind::Profile,
                    format!("{old} is now {}", player.name),
                )
                .about(player.id),
            ),
            _ => {}
        }
    }
    for player in &before.players {
        if !new_names.contains_key(&player.id) {
            out.push(
                Change::new(ActivityKind::Left, format!("{} left", player.name)).about(player.id),
            );
        }
    }

    // Controllers, per player: who holds one now that did not before.
    let holding = |party: &PartySnapshot| -> HashMap<PlayerId, String> {
        party
            .seats
            .iter()
            .filter_map(|seat| Some((seat.occupant.player_id()?, seat.controller.clone()?)))
            .collect()
    };
    let (old_pads, new_pads) = (holding(before), holding(after));
    for player in &after.players {
        let id = player.id;
        let text = match (old_pads.get(&id), new_pads.get(&id)) {
            (None, Some(_)) if old_names.contains_key(&id) => "picked up a controller",
            (None, Some(_)) => continue, // Joining with a controller says enough.
            (Some(_), None) => "put down their controller",
            (Some(a), Some(b)) if a != b => "switched controllers",
            _ => continue,
        };
        out.push(
            Change::new(ActivityKind::Controller, format!("{} {text}", player.name)).about(id),
        );
    }

    for id in &after.phones {
        if !before.phones.contains(id) && new_names.contains_key(id) {
            out.push(
                Change::new(
                    ActivityKind::Phone,
                    format!("{} connected a phone", name(id)),
                )
                .about(*id),
            );
        }
    }

    if let Some(session) = &after.active_session {
        if before.active_session.as_ref().map(|s| s.id) != Some(session.id) {
            out.push(
                Change::new(
                    ActivityKind::GameStarted,
                    format!("Started {}", title(after, &session.game)),
                )
                .in_game(&session.game),
            );
        }
    }

    for settings in &after.settings {
        let Some(old) = before.settings.iter().find(|s| s.game == settings.game) else {
            continue; // Just declared: nobody changed anything.
        };
        for spec in settings.specs.iter().filter(|spec| spec.scope.is_party()) {
            if !old.specs.iter().any(|s| s.key == spec.key) {
                continue;
            }
            let was = effective(spec, old.values.get(&spec.key));
            let now = effective(spec, settings.values.get(&spec.key));
            if was != now {
                out.push(
                    Change::new(
                        ActivityKind::Setting,
                        format!(
                            "{}: {} set to {}",
                            title(after, &settings.game),
                            spec.label,
                            shown(&now)
                        ),
                    )
                    .in_game(&settings.game),
                );
            }
        }
    }
    out
}

fn effective(spec: &SettingSpec, value: Option<&SettingValue>) -> SettingValue {
    value.cloned().unwrap_or_else(|| spec.kind.default_value())
}

fn shown(value: &SettingValue) -> String {
    match value {
        SettingValue::Toggle(true) => "on".into(),
        SettingValue::Toggle(false) => "off".into(),
        other => other.to_string(),
    }
}

/// A game's own log line, made safe to show: one line, at most 120 characters.
pub fn game_note(text: &str) -> Option<String> {
    let line: String = text
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let line = line.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.is_empty() {
        return None;
    }
    Some(match line.char_indices().nth(120) {
        Some((cut, _)) => format!("{}…", line[..cut].trim_end()),
        None => line,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Command, GameNight};
    use gamenight_protocol::{GameMeta, SettingKind, SettingScope};

    fn join(night: &mut GameNight, name: &str) -> PlayerId {
        night.handle(Command::JoinParty {
            name: name.into(),
            seat: None,
            color: None,
            avatar: None,
            library: Vec::new(),
        });
        night.snapshot().players.last().unwrap().id
    }

    fn texts(before: &PartySnapshot, after: &PartySnapshot) -> Vec<String> {
        changes(before, after).into_iter().map(|c| c.text).collect()
    }

    #[test]
    fn joins_renames_controllers_and_leaves_read_as_sentences() {
        let mut night = GameNight::new(4);
        let empty = night.snapshot();
        let ann = join(&mut night, "Ann");
        let joined = night.snapshot();
        assert_eq!(texts(&empty, &joined), ["Ann joined"]);
        // Joining needs no separate controller line; picking one up later does.
        night.handle(Command::BindController {
            player_id: ann,
            controller: "xinput:1".into(),
        });
        let holding = night.snapshot();
        assert_eq!(texts(&joined, &holding), ["Ann picked up a controller"]);
        night.handle(Command::RenamePlayer {
            player_id: ann,
            name: "Joep".into(),
        });
        let renamed = night.snapshot();
        assert_eq!(texts(&holding, &renamed), ["Ann is now Joep"]);
        night.handle(Command::LeaveParty { player_id: ann });
        assert_eq!(texts(&renamed, &night.snapshot()), ["Joep left"]);
    }

    #[test]
    fn settings_changes_name_the_game_but_declarations_are_quiet() {
        let mut before = GameNight::new(4).snapshot();
        before.library.push(GameMeta {
            id: GameId::new("ballkickers"),
            title: "Ballkickers".into(),
            tagline: None,
            cover: None,
            icon: None,
            screenshot: None,
            color: None,
            emoji: None,
            players: None,
            min_players: None,
            max_players: None,
            best_players: None,
            play_with: Default::default(),
            min_phones: None,
            launch: None,
        });
        let mut after = before.clone();
        after.settings.push(gamenight_protocol::GameSettings {
            game: GameId::new("ballkickers"),
            revision: 0,
            can_undo: false,
            specs: vec![SettingSpec {
                key: "wind".into(),
                label: "Wind".into(),
                description: None,
                kind: SettingKind::Toggle { default: false },
                scope: SettingScope::default(),
            }],
            values: Default::default(),
            players: Default::default(),
        });
        assert!(changes(&before, &after).is_empty());
        let mut changed = after.clone();
        changed.settings[0]
            .values
            .insert("wind".into(), SettingValue::Toggle(true));
        assert_eq!(texts(&after, &changed), ["Ballkickers: Wind set to on"]);
    }

    #[test]
    fn game_notes_are_one_bounded_line() {
        assert_eq!(game_note("  New\nrun "), Some("New run".into()));
        assert_eq!(game_note(" \t"), None);
        let long = game_note(&"é".repeat(300)).unwrap();
        assert_eq!(long.chars().count(), 121);
    }
}
