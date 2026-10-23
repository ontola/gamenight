//! The room log phones read back: joins, games, controllers, rounds and
//! setting changes, stamped with the time. See `gamenight_core::activity`.

use gamenight_core::activity::{self, Change};
use gamenight_protocol::{ActivityEntry, ActivityKind, GameId, PartySnapshot, PlayerId, SessionId};
use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Enough for a long evening; older lines fall off.
pub(crate) const KEPT: usize = 200;
/// A game may add one line of its own this often; the rest is dropped.
const NOTE_INTERVAL: Duration = Duration::from_secs(2);
/// Joining and then binding a controller or linking the phone that joined is
/// one thing to a person: such a line that follows a join this soon is left
/// out.
const JOIN_SETTLES: Duration = Duration::from_secs(10);

#[derive(Default)]
pub(crate) struct RoomLog {
    entries: VecDeque<ActivityEntry>,
    next_id: u64,
    /// The party as last compared; `None` until the first look.
    seen: Option<PartySnapshot>,
    last_note: HashMap<GameId, Instant>,
    joined: HashMap<PlayerId, Instant>,
    /// Rounds finished in the session on screen, for "Round 3 over".
    rounds: Option<(SessionId, u32)>,
}

impl RoomLog {
    pub(crate) fn entries(&self) -> Vec<ActivityEntry> {
        self.entries.iter().cloned().collect()
    }

    /// Pick up a log carried over a host restart.
    pub(crate) fn restore(&mut self, entries: Vec<ActivityEntry>) {
        self.next_id = entries.iter().map(|e| e.id + 1).max().unwrap_or(0);
        self.entries = entries.into();
        self.trim();
    }

    /// Take this party as it is, without logging how it got here.
    pub(crate) fn settle(&mut self, mut party: PartySnapshot) {
        // Titles come from the newer side; the shelf's art need not be kept.
        party.library.clear();
        self.seen = Some(party);
    }

    /// Log what changed since the last look.
    pub(crate) fn observe(&mut self, party: &PartySnapshot) {
        let changes = match &self.seen {
            Some(before) => activity::changes(before, party),
            None => Vec::new(),
        };
        self.settle(party.clone());
        for change in changes {
            self.push(change);
        }
    }

    /// A game's own line (`room_log`), at most one per [`NOTE_INTERVAL`].
    pub(crate) fn note(&mut self, game: &GameId, text: &str) -> bool {
        let Some(text) = activity::game_note(text) else {
            return false;
        };
        let now = Instant::now();
        if self
            .last_note
            .get(game)
            .is_some_and(|at| now.duration_since(*at) < NOTE_INTERVAL)
        {
            return false;
        }
        self.last_note.insert(game.clone(), now);
        let mut change = Change::new(ActivityKind::Game, text);
        change.game = Some(game.clone());
        self.push(change);
        true
    }

    /// A round of `game` ended (`finished`).
    pub(crate) fn round_over(&mut self, session: SessionId, game: &GameId, title: &str) {
        let round = match self.rounds {
            Some((id, count)) if id == session => count + 1,
            _ => 1,
        };
        self.rounds = Some((session, round));
        let mut change = Change::new(
            ActivityKind::Round,
            format!("Round {round} over in {title}"),
        );
        change.game = Some(game.clone());
        self.push(change);
    }

    pub(crate) fn push(&mut self, change: Change) {
        if let Some(player) = change.player {
            let now = Instant::now();
            match change.kind {
                ActivityKind::Joined => {
                    self.joined
                        .retain(|_, at| now.duration_since(*at) < JOIN_SETTLES);
                    self.joined.insert(player, now);
                }
                ActivityKind::Controller | ActivityKind::Phone
                    if self
                        .joined
                        .get(&player)
                        .is_some_and(|at| now.duration_since(*at) < JOIN_SETTLES) =>
                {
                    return;
                }
                _ => {}
            }
        }
        let at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        self.entries.push_back(ActivityEntry {
            id: self.next_id,
            at,
            kind: change.kind,
            text: change.text,
            game: change.game,
        });
        self.next_id += 1;
        self.trim();
    }

    fn trim(&mut self) {
        while self.entries.len() > KEPT {
            self.entries.pop_front();
        }
    }
}
