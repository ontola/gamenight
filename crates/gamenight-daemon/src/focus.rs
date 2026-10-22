//! Alt+Tab is a pause. When the party switches away from the game in front
//! (Alt+Tab, the Windows key, a click on another window), the host pauses it
//! exactly as if Back had been pressed: the lobby takes the controllers.
//! Switching back to the game's window resumes it — but only a pause this
//! watcher caused, so a game paused on purpose stays paused.
//!
//! The host asks the window server which process is in front; the game never
//! has to report its own focus. That keeps every engine covered, and keeps
//! the decision in one place, where a stray focus event can be debounced.
use std::time::{Duration, Instant};

use gamenight_protocol::{SessionId, SessionPhase};

/// How long another window must stay in front before the game pauses. Long
/// enough to ride out a launch flashing a window, short enough that the game
/// is frozen before anyone has looked away properly.
pub(crate) const AWAY_AFTER: Duration = Duration::from_millis(500);

/// How long the game's window must be back in front before it resumes.
pub(crate) const BACK_AFTER: Duration = Duration::from_millis(300);

/// Whose window is in front.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Front {
    /// The active game's.
    Game,
    /// Nobody's in particular: no window at all (mid-switch), or a game the
    /// host launched itself, such as the next one warming up. Neither says
    /// the party went anywhere.
    Neutral,
    /// Anything else: the lobby, a browser, the desktop, the task switcher.
    /// Only Windows can tell; elsewhere the host sees nothing but `Neutral`.
    #[cfg_attr(not(windows), allow(dead_code))]
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FocusAction {
    /// Pause the game and give the lobby the controllers.
    Pause,
    /// Undo that pause.
    Resume,
}

#[derive(Debug, Default)]
pub(crate) struct FocusWatch {
    session: Option<SessionId>,
    /// The game has been seen in front since it last started running. Until
    /// then nothing pauses it: a game whose window the host cannot recognise
    /// must never be paused for being "away".
    armed: bool,
    away_since: Option<Instant>,
    /// The current pause is ours to undo.
    paused_by_us: bool,
    back_since: Option<Instant>,
}

impl FocusWatch {
    /// Whether this watcher paused the session in front.
    pub(crate) fn paused_by_us(&self) -> bool {
        self.paused_by_us
    }

    pub(crate) fn step(
        &mut self,
        now: Instant,
        active: Option<(SessionId, SessionPhase)>,
        front: Front,
    ) -> Option<FocusAction> {
        let Some((session, phase)) = active else {
            *self = Self::default();
            return None;
        };
        if self.session != Some(session) {
            *self = Self {
                session: Some(session),
                ..Self::default()
            };
        }
        match phase {
            SessionPhase::Running => {
                if self.paused_by_us {
                    // Resumed some other way (the lobby's Resume): it has to
                    // be seen in front again before switching away counts.
                    self.paused_by_us = false;
                    self.armed = false;
                }
                self.back_since = None;
                match front {
                    Front::Game => {
                        self.armed = true;
                        self.away_since = None;
                    }
                    Front::Neutral => self.away_since = None,
                    Front::Other if self.armed => {
                        let since = *self.away_since.get_or_insert(now);
                        if now.duration_since(since) >= AWAY_AFTER {
                            self.armed = false;
                            self.away_since = None;
                            self.paused_by_us = true;
                            return Some(FocusAction::Pause);
                        }
                    }
                    Front::Other => {}
                }
            }
            SessionPhase::Paused if self.paused_by_us => {
                if front == Front::Game {
                    let since = *self.back_since.get_or_insert(now);
                    if now.duration_since(since) >= BACK_AFTER {
                        self.paused_by_us = false;
                        self.back_since = None;
                        self.armed = true;
                        return Some(FocusAction::Resume);
                    }
                } else {
                    self.back_since = None;
                }
            }
            _ => {
                self.paused_by_us = false;
                self.armed = false;
                self.away_since = None;
                self.back_since = None;
            }
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(start: Instant, ms: u64) -> Instant {
        start + Duration::from_millis(ms)
    }

    #[test]
    fn switching_away_pauses_and_switching_back_resumes() {
        let t = Instant::now();
        let s = SessionId::new();
        let mut w = FocusWatch::default();
        let running = Some((s, SessionPhase::Running));
        assert_eq!(w.step(t, running, Front::Game), None);
        assert_eq!(w.step(ms(t, 200), running, Front::Other), None);
        assert_eq!(w.step(ms(t, 600), running, Front::Other), None);
        assert_eq!(
            w.step(ms(t, 700), running, Front::Other),
            Some(FocusAction::Pause)
        );
        let paused = Some((s, SessionPhase::Paused));
        assert_eq!(w.step(ms(t, 900), paused, Front::Other), None);
        assert_eq!(w.step(ms(t, 1000), paused, Front::Game), None);
        assert_eq!(
            w.step(ms(t, 1300), paused, Front::Game),
            Some(FocusAction::Resume)
        );
    }

    #[test]
    fn a_game_never_seen_in_front_is_never_paused() {
        let t = Instant::now();
        let running = Some((SessionId::new(), SessionPhase::Running));
        let mut w = FocusWatch::default();
        for i in 0..20 {
            assert_eq!(w.step(ms(t, i * 200), running, Front::Other), None);
        }
    }

    #[test]
    fn a_brief_flash_or_a_warming_game_does_not_pause() {
        let t = Instant::now();
        let running = Some((SessionId::new(), SessionPhase::Running));
        let mut w = FocusWatch::default();
        w.step(t, running, Front::Game);
        assert_eq!(w.step(ms(t, 100), running, Front::Other), None);
        assert_eq!(w.step(ms(t, 400), running, Front::Game), None);
        assert_eq!(w.step(ms(t, 500), running, Front::Other), None);
        for i in 0..10 {
            assert_eq!(w.step(ms(t, 600 + i * 200), running, Front::Neutral), None);
        }
    }

    #[test]
    fn a_pause_someone_else_made_is_left_alone() {
        let t = Instant::now();
        let s = SessionId::new();
        let mut w = FocusWatch::default();
        w.step(t, Some((s, SessionPhase::Running)), Front::Game);
        // Back pressed: paused by the party, then the lobby comes up.
        let paused = Some((s, SessionPhase::Paused));
        w.step(ms(t, 100), paused, Front::Game);
        w.step(ms(t, 200), paused, Front::Other);
        for i in 0..10 {
            assert_eq!(w.step(ms(t, 300 + i * 200), paused, Front::Game), None);
        }
    }

    #[test]
    fn resumed_from_the_lobby_rearms_only_once_seen_again() {
        let t = Instant::now();
        let s = SessionId::new();
        let running = Some((s, SessionPhase::Running));
        let mut w = FocusWatch::default();
        w.step(t, running, Front::Game);
        w.step(ms(t, 100), running, Front::Other);
        assert_eq!(
            w.step(ms(t, 700), running, Front::Other),
            Some(FocusAction::Pause)
        );
        // The lobby's Resume, while the lobby is still in front.
        assert_eq!(w.step(ms(t, 900), running, Front::Other), None);
        assert_eq!(w.step(ms(t, 2000), running, Front::Other), None);
        w.step(ms(t, 2100), running, Front::Game);
        w.step(ms(t, 2200), running, Front::Other);
        assert_eq!(
            w.step(ms(t, 2800), running, Front::Other),
            Some(FocusAction::Pause)
        );
    }

    #[test]
    fn a_new_session_starts_unarmed() {
        let t = Instant::now();
        let mut w = FocusWatch::default();
        w.step(
            t,
            Some((SessionId::new(), SessionPhase::Running)),
            Front::Game,
        );
        let next = Some((SessionId::new(), SessionPhase::Running));
        for i in 1..10 {
            assert_eq!(w.step(ms(t, i * 200), next, Front::Other), None);
        }
    }
}
