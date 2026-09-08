//! A single playable game instance and its lifecycle.

use gamenight_protocol::{GameId, SessionId, SessionInfo, SessionPhase};

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
#[error("illegal session transition: {from:?} -> {to:?}")]
pub struct IllegalTransition {
    pub from: SessionPhase,
    pub to: SessionPhase,
}

/// A disposable game session. Sessions only ever move forward through their
/// lifecycle; a "replay" is a brand-new session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    pub id: SessionId,
    pub game: GameId,
    pub phase: SessionPhase,
    /// Which playlist entry this session was created for.
    pub playlist_index: usize,
    /// Loading progress the game last reported, 0–100 (see `SessionInfo`).
    pub progress: Option<u8>,
    /// What the game said it's doing right now ("generating arena").
    pub progress_label: Option<String>,
}

impl Session {
    pub fn new(game: GameId, playlist_index: usize) -> Self {
        Self {
            id: SessionId::new(),
            game,
            phase: SessionPhase::Created,
            playlist_index,
            progress: None,
            progress_label: None,
        }
    }

    pub fn info(&self) -> SessionInfo {
        SessionInfo {
            id: self.id,
            game: self.game.clone(),
            phase: self.phase,
            progress: self.progress,
            progress_label: self.progress_label.clone(),
        }
    }

    /// Move to `to`, enforcing the lifecycle.
    pub fn advance(&mut self, to: SessionPhase) -> Result<(), IllegalTransition> {
        use SessionPhase::*;
        let ok = matches!(
            (self.phase, to),
            (Created, Preparing)
                | (Preparing, Ready)
                | (Ready, Running)
                | (Running, Paused)
                | (Paused, Running)
                | (Running, Finished)
                // a game may report finished while a pause was in flight
                | (Paused, Finished)
                // abort: anything not yet disposed can be torn down
                | (Created, Disposed)
                | (Preparing, Disposed)
                | (Ready, Disposed)
                | (Running, Disposed)
                | (Paused, Disposed)
                | (Finished, Disposed)
        );
        if ok {
            self.phase = to;
            Ok(())
        } else {
            Err(IllegalTransition {
                from: self.phase,
                to,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use SessionPhase::*;

    fn session() -> Session {
        Session::new(GameId::new("towerfall"), 0)
    }

    #[test]
    fn happy_path() {
        let mut s = session();
        for phase in [
            Preparing, Ready, Running, Paused, Running, Finished, Disposed,
        ] {
            s.advance(phase).unwrap();
        }
        assert_eq!(s.phase, Disposed);
    }

    #[test]
    fn cannot_start_before_ready() {
        let mut s = session();
        assert_eq!(
            s.advance(Running),
            Err(IllegalTransition {
                from: Created,
                to: Running
            })
        );
    }

    #[test]
    fn cannot_resurrect_disposed() {
        let mut s = session();
        s.advance(Disposed).unwrap();
        assert!(s.advance(Preparing).is_err());
        assert!(s.advance(Disposed).is_err());
    }

    #[test]
    fn abort_from_any_live_phase() {
        for setup in [
            vec![],
            vec![Preparing],
            vec![Preparing, Ready],
            vec![Preparing, Ready, Running],
            vec![Preparing, Ready, Running, Paused],
        ] {
            let mut s = session();
            for p in setup {
                s.advance(p).unwrap();
            }
            s.advance(Disposed).unwrap();
        }
    }
}
