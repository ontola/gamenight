//! The queue of games for the night, like a music player's: what was played,
//! what plays now, what players queued themselves, then autoplay picks the
//! host keeps topped up so the queue never runs dry. Still wraps around as a
//! last resort: game night doesn't end because the playlist did.

use gamenight_protocol::{PlaylistEntry, PlaylistSnapshot};

#[derive(Debug, Clone, Default)]
pub struct Playlist {
    entries: Vec<PlaylistEntry>,
    /// Index of the entry the active session plays. `None` until the first
    /// session starts.
    current: Option<usize>,
    /// How many entries right after `current` players queued themselves.
    queued: usize,
}

impl Playlist {
    pub fn set_entries(&mut self, entries: Vec<PlaylistEntry>) {
        self.entries = entries;
        self.current = None;
        self.queued = 0;
    }

    pub fn entries(&self) -> &[PlaylistEntry] {
        &self.entries
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn current(&self) -> Option<usize> {
        self.current
    }

    pub fn set_current(&mut self, index: usize) {
        debug_assert!(index < self.entries.len());
        self.current = Some(index);
        self.set_queued(self.queued);
    }

    /// Start playing entry `index`: the player queue loses whatever entries
    /// that passes, and nothing else.
    pub fn advance_to(&mut self, index: usize) {
        let (start, queue_end) = (self.upcoming_start(), self.upcoming_start() + self.queued);
        self.current = Some(index);
        // Wrapping back to an earlier entry leaves the player queue behind.
        self.queued = if index < start {
            0
        } else {
            queue_end.saturating_sub(index + 1)
        };
        self.set_queued(self.queued);
    }

    /// Index of the first upcoming entry: right after `current`.
    pub fn upcoming_start(&self) -> usize {
        self.current.map_or(0, |c| c + 1)
    }

    /// How many entries after `current` players queued themselves.
    pub fn queued(&self) -> usize {
        self.queued
    }

    pub fn set_queued(&mut self, queued: usize) {
        self.queued = queued.min(self.entries.len().saturating_sub(self.upcoming_start()));
    }

    pub fn get(&self, index: usize) -> Option<&PlaylistEntry> {
        self.entries.get(index)
    }

    /// Index of the first entry for `game`, if it's queued at all.
    pub fn position_of(&self, game: &gamenight_protocol::GameId) -> Option<usize> {
        self.entries.iter().position(|e| &e.game == game)
    }

    /// The entry that should be warmed next: the one after `current`, wrapping
    /// around; or the first entry if nothing has started yet.
    pub fn next_index(&self) -> Option<usize> {
        if self.entries.is_empty() {
            return None;
        }
        Some(match self.current {
            None => 0,
            Some(i) => (i + 1) % self.entries.len(),
        })
    }

    pub fn snapshot(&self) -> PlaylistSnapshot {
        PlaylistSnapshot {
            entries: self.entries.clone(),
            current: self.current,
            queued: self.queued,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gamenight_protocol::GameId;

    fn entry(id: &str) -> PlaylistEntry {
        PlaylistEntry {
            game: GameId::new(id),
            title: id.to_string(),
        }
    }

    #[test]
    fn next_wraps_around() {
        let mut p = Playlist::default();
        p.set_entries(vec![entry("a"), entry("b")]);
        assert_eq!(p.next_index(), Some(0));
        p.set_current(0);
        assert_eq!(p.next_index(), Some(1));
        p.set_current(1);
        assert_eq!(p.next_index(), Some(0));
    }

    #[test]
    fn advancing_consumes_the_player_queue_only() {
        let mut p = Playlist::default();
        p.set_entries(vec![entry("a"), entry("b"), entry("c"), entry("d")]);
        p.set_current(0);
        p.set_queued(2);
        p.advance_to(1);
        assert_eq!(p.queued(), 1);
        p.advance_to(3);
        assert_eq!(p.queued(), 0);
    }

    #[test]
    fn empty_playlist_has_no_next() {
        assert_eq!(Playlist::default().next_index(), None);
    }

    #[test]
    fn single_entry_repeats() {
        let mut p = Playlist::default();
        p.set_entries(vec![entry("solo")]);
        p.set_current(0);
        assert_eq!(p.next_index(), Some(0));
    }
}
