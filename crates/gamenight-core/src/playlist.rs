//! The queue of games for the night. Wraps around: game night doesn't end
//! because the playlist did.

use gamenight_protocol::{PlaylistEntry, PlaylistSnapshot};

#[derive(Debug, Clone, Default)]
pub struct Playlist {
    entries: Vec<PlaylistEntry>,
    /// Index of the entry the active session plays. `None` until the first
    /// session starts.
    current: Option<usize>,
}

impl Playlist {
    pub fn set_entries(&mut self, entries: Vec<PlaylistEntry>) {
        self.entries = entries;
        self.current = None;
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
    }

    pub fn get(&self, index: usize) -> Option<&PlaylistEntry> {
        self.entries.get(index)
    }

    /// Index of the first entry for `game`, if it's queued at all.
    pub fn position_of(&self, game: &gamenight_protocol::GameId) -> Option<usize> {
        self.entries.iter().position(|e| &e.game == game)
    }

    /// Insert an entry. `index` must be after `current`, so the pointer to
    /// what's playing never shifts.
    pub fn insert(&mut self, index: usize, entry: PlaylistEntry) {
        debug_assert!(index <= self.entries.len());
        debug_assert!(self.current.is_none_or(|c| index > c));
        self.entries.insert(index.min(self.entries.len()), entry);
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
