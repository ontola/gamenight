//! Avatar voting. Players stand on an option; when every voter agrees, the
//! decision fires. Voting is gameplay, not a dialog box.

use std::collections::HashMap;

use gamenight_protocol::{PlayerId, VoteOption, VoteSnapshot};

#[derive(Debug, Clone, Default)]
pub struct VoteBoard {
    /// Whether a vote is currently accepting positions.
    open: bool,
    positions: HashMap<PlayerId, VoteOption>,
    decided: Option<VoteOption>,
}

impl VoteBoard {
    /// Open a fresh vote (e.g. when a game finishes).
    pub fn open(&mut self) {
        self.open = true;
        self.positions.clear();
        self.decided = None;
    }

    pub fn close(&mut self) {
        self.open = false;
        self.positions.clear();
    }

    pub fn is_open(&self) -> bool {
        self.open
    }

    /// A player moves onto an option. Moving again just relocates them.
    /// Returns the consensus decision if this move produced one.
    ///
    /// `voters` is the set of players who must agree — everyone currently in a
    /// seat. Consensus requires *all* of them standing on the same option.
    pub fn place(
        &mut self,
        player: PlayerId,
        option: VoteOption,
        voters: &[PlayerId],
    ) -> Option<VoteOption> {
        if !self.open || self.decided.is_some() || !voters.contains(&player) {
            return None;
        }
        self.positions.insert(player, option);
        let consensus = !voters.is_empty()
            && voters
                .iter()
                .all(|v| self.positions.get(v) == Some(&option));
        if consensus {
            self.decided = Some(option);
            self.open = false;
            Some(option)
        } else {
            None
        }
    }

    /// Re-check consensus after the voter set changed (e.g. a player left).
    /// Returns and records the decision if the remaining voters all agree.
    pub fn reevaluate(&mut self, voters: &[PlayerId]) -> Option<VoteOption> {
        if !self.open || self.decided.is_some() || voters.is_empty() {
            return None;
        }
        let first = self.positions.get(voters.first()?)?;
        if voters.iter().all(|v| self.positions.get(v) == Some(first)) {
            let decision = *first;
            self.decided = Some(decision);
            self.open = false;
            Some(decision)
        } else {
            None
        }
    }

    pub fn snapshot(&self) -> VoteSnapshot {
        let mut positions: Vec<_> = self.positions.iter().map(|(p, o)| (*p, *o)).collect();
        // Deterministic order for the wire.
        positions.sort_by_key(|(p, _)| p.0);
        VoteSnapshot {
            open: self.open,
            positions,
            decided: self.decided,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn consensus_needs_everyone() {
        let (a, b, c) = (PlayerId::new(), PlayerId::new(), PlayerId::new());
        let voters = vec![a, b, c];
        let mut board = VoteBoard::default();
        board.open();

        assert_eq!(board.place(a, VoteOption::NextGame, &voters), None);
        assert_eq!(board.place(b, VoteOption::NextGame, &voters), None);
        // c disagrees, then changes their mind.
        assert_eq!(board.place(c, VoteOption::Replay, &voters), None);
        assert_eq!(
            board.place(c, VoteOption::NextGame, &voters),
            Some(VoteOption::NextGame)
        );
        assert!(!board.is_open());
    }

    #[test]
    fn closed_board_ignores_votes() {
        let a = PlayerId::new();
        let mut board = VoteBoard::default();
        assert_eq!(board.place(a, VoteOption::Quit, &[a]), None);
    }

    #[test]
    fn non_voters_cannot_vote() {
        let (seated, stranger) = (PlayerId::new(), PlayerId::new());
        let mut board = VoteBoard::default();
        board.open();
        assert_eq!(board.place(stranger, VoteOption::Quit, &[seated]), None);
        assert!(board.snapshot().positions.is_empty());
    }

    #[test]
    fn solo_player_decides_instantly() {
        let a = PlayerId::new();
        let mut board = VoteBoard::default();
        board.open();
        assert_eq!(
            board.place(a, VoteOption::Replay, &[a]),
            Some(VoteOption::Replay)
        );
    }
}
