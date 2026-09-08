//! GameNight core: the party is persistent, games are disposable sessions.
//!
//! This crate is deliberately IO-free. [`GameNight::handle`] takes a
//! [`Command`], mutates the night, and returns [`Effect`]s for the daemon to
//! execute. Every rule of the evening — seat assignment, warm sessions,
//! instant transitions, avatar voting — lives here and is tested here.

mod night;
mod playlist;
mod session;
mod vote;

pub use night::{Command, Effect, GameCommand, GameNight};
pub use playlist::Playlist;
pub use session::{IllegalTransition, Session};
pub use vote::VoteBoard;

#[cfg(test)]
mod night_tests {
    use super::*;
    use gamenight_protocol::{
        GameId, GameMeta, PlaylistEntry, SeatOccupant, SessionId, SessionPhase, VoteOption,
    };

    fn join_cmd(name: &str, seat: Option<u8>, color: Option<&str>) -> Command {
        Command::JoinParty {
            name: name.into(),
            seat,
            color: color.map(|s| s.into()),
            avatar: None,
            library: Vec::new(),
        }
    }

    fn entry(id: &str) -> PlaylistEntry {
        PlaylistEntry {
            game: GameId::new(id),
            title: id.to_uppercase(),
        }
    }

    fn meta(id: &str) -> GameMeta {
        GameMeta {
            id: GameId::new(id),
            title: id.to_uppercase(),
            tagline: None,
            cover: None,
            color: None,
            emoji: None,
            players: None,
            min_players: None,
            max_players: None,
            best_players: None,
            launch: None,
        }
    }

    /// Pull the session id out of the single `Prepare` effect, if present.
    fn prepared_session(fx: &[Effect]) -> Option<(GameId, SessionId)> {
        fx.iter().find_map(|e| match e {
            Effect::ToGame {
                game,
                session,
                command: GameCommand::Prepare { .. },
            } => Some((game.clone(), *session)),
            _ => None,
        })
    }

    fn started_session(fx: &[Effect]) -> Option<SessionId> {
        fx.iter().find_map(|e| match e {
            Effect::ToGame {
                session,
                command: GameCommand::Start,
                ..
            } => Some(*session),
            _ => None,
        })
    }

    fn disposed_sessions(fx: &[Effect]) -> Vec<SessionId> {
        fx.iter()
            .filter_map(|e| match e {
                Effect::ToGame {
                    session,
                    command: GameCommand::Dispose,
                    ..
                } => Some(*session),
                _ => None,
            })
            .collect()
    }

    /// The whole MVP evening: two games connect, playlist set, first game
    /// auto-starts, "Next" transitions instantly, the previous game is
    /// disposed and the following one warms.
    #[test]
    fn full_night_flow() {
        let mut night = GameNight::default();

        night.handle(join_cmd("Ada", None, None));
        night.handle(join_cmd("Joep", None, None));

        night.handle(Command::GameConnected {
            game: GameId::new("towerfall"),
        });
        night.handle(Command::GameConnected {
            game: GameId::new("duck-game"),
        });

        // Playlist set: towerfall should start warming immediately.
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("towerfall"), entry("duck-game")],
        });
        let (game, warm1) = prepared_session(&fx).expect("towerfall warms");
        assert_eq!(game, GameId::new("towerfall"));

        // Warm session ready + no active game => auto-start, and duck-game
        // begins warming behind it.
        let fx = night.handle(Command::SessionReady { session: warm1 });
        assert_eq!(started_session(&fx), Some(warm1));
        let (game2, warm2) = prepared_session(&fx).expect("duck-game warms next");
        assert_eq!(game2, GameId::new("duck-game"));

        let snap = night.snapshot();
        assert_eq!(snap.active_session.as_ref().unwrap().id, warm1);
        assert_eq!(snap.active_session.unwrap().phase, SessionPhase::Running);
        assert_eq!(snap.warm_session.unwrap().phase, SessionPhase::Preparing);
        assert_eq!(snap.playlist.current, Some(0));

        // Next pressed before warm is ready: transition is pending...
        let fx = night.handle(Command::Next);
        assert_eq!(started_session(&fx), None);
        // ...and fires the instant duck-game reports ready.
        let fx = night.handle(Command::SessionReady { session: warm2 });
        assert_eq!(started_session(&fx), Some(warm2));
        assert_eq!(disposed_sessions(&fx), vec![warm1]);
        // The playlist wraps: towerfall warms again for later.
        let (game3, _warm3) = prepared_session(&fx).expect("towerfall re-warms");
        assert_eq!(game3, GameId::new("towerfall"));

        let snap = night.snapshot();
        assert_eq!(snap.history, vec![GameId::new("towerfall")]);
        assert_eq!(snap.playlist.current, Some(1));
    }

    #[test]
    fn finish_opens_vote_and_consensus_transitions() {
        let mut night = GameNight::default();
        night.handle(join_cmd("A", None, None));
        night.handle(join_cmd("B", None, None));
        let snap = night.snapshot();
        let (a, b) = (snap.players[0].id, snap.players[1].id);

        night.handle(Command::GameConnected {
            game: GameId::new("g1"),
        });
        night.handle(Command::GameConnected {
            game: GameId::new("g2"),
        });
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("g1"), entry("g2")],
        });
        let (_, s1) = prepared_session(&fx).unwrap();
        let fx = night.handle(Command::SessionReady { session: s1 });
        let (_, s2) = prepared_session(&fx).unwrap();
        night.handle(Command::SessionReady { session: s2 });

        // Match over: vote opens instead of a transition.
        let fx = night.handle(Command::SessionFinished { session: s1 });
        assert_eq!(started_session(&fx), None);
        assert!(night.snapshot().vote.decided.is_none());

        night.handle(Command::Vote {
            player_id: a,
            option: VoteOption::NextGame,
        });
        let fx = night.handle(Command::Vote {
            player_id: b,
            option: VoteOption::NextGame,
        });
        // Consensus: g2 starts, g1's session is disposed.
        assert_eq!(started_session(&fx), Some(s2));
        assert_eq!(disposed_sessions(&fx), vec![s1]);
    }

    #[test]
    fn replay_creates_fresh_session_of_same_game() {
        let mut night = GameNight::default();
        night.handle(join_cmd("Solo", None, None));
        let player = night.snapshot().players[0].id;

        night.handle(Command::GameConnected {
            game: GameId::new("g1"),
        });
        night.handle(Command::GameConnected {
            game: GameId::new("g2"),
        });
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("g1"), entry("g2")],
        });
        let (_, s1) = prepared_session(&fx).unwrap();
        let fx = night.handle(Command::SessionReady { session: s1 });
        let (_, s2) = prepared_session(&fx).unwrap();
        night.handle(Command::SessionReady { session: s2 });
        night.handle(Command::SessionFinished { session: s1 });

        // Solo player votes replay: instant consensus. The warm g2 session is
        // scrapped, g1's finished session is disposed to free the process, and
        // a fresh g1 session warms.
        let fx = night.handle(Command::Vote {
            player_id: player,
            option: VoteOption::Replay,
        });
        let disposed = disposed_sessions(&fx);
        assert!(disposed.contains(&s2), "warm g2 scrapped");
        assert!(disposed.contains(&s1), "old g1 disposed");
        let (game, s1b) = prepared_session(&fx).expect("fresh g1 warms");
        assert_eq!(game, GameId::new("g1"));
        assert_ne!(s1b, s1, "replay is a new session");

        // When it's ready it starts right away.
        let fx = night.handle(Command::SessionReady { session: s1b });
        assert_eq!(started_session(&fx), Some(s1b));
    }

    #[test]
    fn quit_vote_ends_the_party() {
        let mut night = GameNight::default();
        night.handle(join_cmd("A", None, None));
        let a = night.snapshot().players[0].id;
        night.handle(Command::GameConnected {
            game: GameId::new("g1"),
        });
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("g1")],
        });
        let (_, s1) = prepared_session(&fx).unwrap();
        night.handle(Command::SessionReady { session: s1 });
        night.handle(Command::SessionFinished { session: s1 });

        let fx = night.handle(Command::Vote {
            player_id: a,
            option: VoteOption::Quit,
        });
        assert!(fx.contains(&Effect::PartyOver));
        assert_eq!(disposed_sessions(&fx), vec![s1]);
        let snap = night.snapshot();
        assert!(snap.active_session.is_none());
        assert!(snap.warm_session.is_none());
    }

    #[test]
    fn single_game_playlist_can_roll_forever() {
        // One entry, one process: Next must dispose the active session first,
        // then warm a fresh one on the same process.
        let mut night = GameNight::default();
        night.handle(Command::GameConnected {
            game: GameId::new("only"),
        });
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("only")],
        });
        let (_, s1) = prepared_session(&fx).unwrap();
        night.handle(Command::SessionReady { session: s1 });

        let fx = night.handle(Command::Next);
        assert_eq!(disposed_sessions(&fx), vec![s1]);
        let (_, s2) = prepared_session(&fx).expect("same game warms again");
        assert_ne!(s2, s1);
        let fx = night.handle(Command::SessionReady { session: s2 });
        assert_eq!(started_session(&fx), Some(s2));
    }

    #[test]
    fn no_seated_players_means_autoplay() {
        // Bots-only demo mode: finishing just rolls to the next game.
        let mut night = GameNight::default();
        night.handle(Command::GameConnected {
            game: GameId::new("g1"),
        });
        night.handle(Command::GameConnected {
            game: GameId::new("g2"),
        });
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("g1"), entry("g2")],
        });
        let (_, s1) = prepared_session(&fx).unwrap();
        let fx = night.handle(Command::SessionReady { session: s1 });
        let (_, s2) = prepared_session(&fx).unwrap();
        night.handle(Command::SessionReady { session: s2 });

        let fx = night.handle(Command::SessionFinished { session: s1 });
        assert_eq!(started_session(&fx), Some(s2));
    }

    #[test]
    fn joining_fills_first_free_seat_and_leaving_clears_it() {
        let mut night = GameNight::new(2);
        night.handle(join_cmd("A", None, None));
        night.handle(join_cmd("B", None, None));
        night.handle(join_cmd("C", None, None));
        let snap = night.snapshot();
        assert_eq!(snap.players.len(), 3);
        let a = snap.players[0].id;
        assert_eq!(snap.seats[0].occupant.player_id(), Some(a));
        // C found no free seat: joined as spectator.
        assert!(snap
            .seats
            .iter()
            .all(|s| s.occupant.player_id() != Some(snap.players[2].id)));

        night.handle(Command::LeaveParty { player_id: a });
        let snap = night.snapshot();
        assert_eq!(snap.players.len(), 2);
        assert!(snap.seats[0].occupant.is_empty());
    }

    /// A running night with one active session, for overlay/seat tests.
    fn night_in_progress() -> (GameNight, SessionId) {
        let mut night = GameNight::default();
        night.handle(join_cmd("A", None, None));
        night.handle(Command::GameConnected {
            game: GameId::new("g1"),
        });
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("g1")],
        });
        let (_, s1) = prepared_session(&fx).unwrap();
        night.handle(Command::SessionReady { session: s1 });
        assert_eq!(
            night.snapshot().active_session.unwrap().phase,
            SessionPhase::Running
        );
        (night, s1)
    }

    fn pause_effect(fx: &[Effect]) -> bool {
        fx.iter().any(|e| {
            matches!(
                e,
                Effect::ToGame {
                    command: GameCommand::Pause,
                    ..
                }
            )
        })
    }

    fn resume_effect(fx: &[Effect]) -> bool {
        fx.iter().any(|e| {
            matches!(
                e,
                Effect::ToGame {
                    command: GameCommand::Resume,
                    ..
                }
            )
        })
    }

    #[test]
    fn opening_overlay_pauses_and_closing_resumes() {
        let (mut night, _s1) = night_in_progress();

        let fx = night.handle(Command::OverlayOpened);
        assert!(pause_effect(&fx), "opening the overlay pauses the game");
        let snap = night.snapshot();
        assert!(snap.overlay_open);
        assert_eq!(snap.active_session.unwrap().phase, SessionPhase::Paused);

        // Opening again (second screen) is idempotent: no double pause.
        let fx = night.handle(Command::OverlayOpened);
        assert!(!pause_effect(&fx));

        let fx = night.handle(Command::OverlayClosed);
        assert!(resume_effect(&fx), "closing the overlay resumes");
        let snap = night.snapshot();
        assert!(!snap.overlay_open);
        assert_eq!(snap.active_session.unwrap().phase, SessionPhase::Running);
    }

    #[test]
    fn closing_overlay_keeps_explicit_pause() {
        let (mut night, _s1) = night_in_progress();
        // Someone paused on purpose, then browsed the overlay.
        night.handle(Command::Pause);
        night.handle(Command::OverlayOpened);
        let fx = night.handle(Command::OverlayClosed);
        assert!(
            !resume_effect(&fx),
            "closing the overlay must not undo an explicit pause"
        );
        assert_eq!(
            night.snapshot().active_session.unwrap().phase,
            SessionPhase::Paused
        );
    }

    #[test]
    fn transition_closes_the_overlay() {
        let mut night = GameNight::default();
        night.handle(Command::GameConnected {
            game: GameId::new("g1"),
        });
        night.handle(Command::GameConnected {
            game: GameId::new("g2"),
        });
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("g1"), entry("g2")],
        });
        let (_, s1) = prepared_session(&fx).unwrap();
        let fx = night.handle(Command::SessionReady { session: s1 });
        let (_, s2) = prepared_session(&fx).unwrap();
        night.handle(Command::SessionReady { session: s2 });

        // Overlay is open (game paused); skipping from it lands everyone in
        // the next game with the overlay gone.
        night.handle(Command::OverlayOpened);
        let fx = night.handle(Command::Next);
        assert_eq!(started_session(&fx), Some(s2));
        let snap = night.snapshot();
        assert!(!snap.overlay_open, "transition closes the overlay");
        assert_eq!(snap.active_session.unwrap().phase, SessionPhase::Running);

        // And the pause the overlay held on the old session is forgotten:
        // closing the overlay again later must not resume anything.
        let fx = night.handle(Command::OverlayClosed);
        assert!(!resume_effect(&fx));
    }

    #[test]
    fn finished_while_overlay_paused_opens_the_vote() {
        // The game reported finished in the same instant the overlay pause
        // was in flight: the finish wins and the vote opens.
        let (mut night, s1) = night_in_progress();
        night.handle(Command::OverlayOpened);
        let fx = night.handle(Command::SessionFinished { session: s1 });
        assert!(!matches!(fx[0], Effect::Reject { .. }));
        assert_eq!(
            night.snapshot().active_session.unwrap().phase,
            SessionPhase::Finished
        );
        // Nothing left to resume when the overlay closes.
        let fx = night.handle(Command::OverlayClosed);
        assert!(!resume_effect(&fx));
    }

    #[test]
    fn growing_the_playlist_mid_game_warms_the_new_entry() {
        // Start the night with a single-game playlist, then append a second
        // game while the first is playing: it should start warming.
        let mut night = GameNight::default();
        night.handle(Command::GameConnected {
            game: GameId::new("g1"),
        });
        night.handle(Command::GameConnected {
            game: GameId::new("g2"),
        });
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("g1")],
        });
        let (_, s1) = prepared_session(&fx).unwrap();
        night.handle(Command::SessionReady { session: s1 });

        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("g1"), entry("g2")],
        });
        let (g, s2) = prepared_session(&fx).expect("g2 warms after append");
        assert_eq!(g, GameId::new("g2"));
        assert_eq!(
            night.snapshot().playlist.current,
            Some(0),
            "pointer re-anchored"
        );

        // Skip is pending until g2 reports ready, then fires.
        night.handle(Command::Next);
        let fx = night.handle(Command::SessionReady { session: s2 });
        assert_eq!(started_session(&fx), Some(s2));
    }

    #[test]
    fn play_next_aims_the_warm_slot_at_a_queued_game() {
        // Playlist g1, g2, g3 — while g1 plays, g2 warms. "Play next: g3"
        // scraps the warm g2 session and warms g3 instead.
        let mut night = GameNight::default();
        for g in ["g1", "g2", "g3"] {
            night.handle(Command::GameConnected {
                game: GameId::new(g),
            });
        }
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("g1"), entry("g2"), entry("g3")],
        });
        let (_, s1) = prepared_session(&fx).unwrap();
        let fx = night.handle(Command::SessionReady { session: s1 });
        let (g, s2) = prepared_session(&fx).unwrap();
        assert_eq!(g, GameId::new("g2"));

        let fx = night.handle(Command::PlayNext {
            game: GameId::new("g3"),
        });
        assert_eq!(disposed_sessions(&fx), vec![s2], "warm g2 scrapped");
        let (g, s3) = prepared_session(&fx).expect("g3 warms instead");
        assert_eq!(g, GameId::new("g3"));

        // Skip lands on g3, not g2.
        night.handle(Command::SessionReady { session: s3 });
        let fx = night.handle(Command::Next);
        assert_eq!(started_session(&fx), Some(s3));
        assert_eq!(night.snapshot().playlist.current, Some(2));
    }

    #[test]
    fn play_next_inserts_a_library_game_into_the_playlist() {
        // g9 is on the shelf but not in the playlist: play-next inserts it
        // right after the current entry, with its proper title.
        let mut night = GameNight::default();
        night.set_library(vec![gamenight_protocol::GameMeta {
            id: GameId::new("g9"),
            title: "The Niner".into(),
            tagline: None,
            cover: None,
            color: None,
            emoji: None,
            players: None,
            min_players: None,
            max_players: None,
            best_players: None,
            launch: None,
        }]);
        for g in ["g1", "g2", "g9"] {
            night.handle(Command::GameConnected {
                game: GameId::new(g),
            });
        }
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("g1"), entry("g2")],
        });
        let (_, s1) = prepared_session(&fx).unwrap();
        let fx = night.handle(Command::SessionReady { session: s1 });
        let (_, s2) = prepared_session(&fx).unwrap();

        let fx = night.handle(Command::PlayNext {
            game: GameId::new("g9"),
        });
        assert_eq!(disposed_sessions(&fx), vec![s2], "shifted warm scrapped");
        let (g, s9) = prepared_session(&fx).expect("g9 warms");
        assert_eq!(g, GameId::new("g9"));

        let snap = night.snapshot();
        let titles: Vec<_> = snap
            .playlist
            .entries
            .iter()
            .map(|e| e.title.as_str())
            .collect();
        assert_eq!(titles, vec!["G1", "The Niner", "G2"]);

        night.handle(Command::SessionReady { session: s9 });
        let fx = night.handle(Command::Next);
        assert_eq!(started_session(&fx), Some(s9));
        assert_eq!(snap.library[0].title, "The Niner");
    }

    #[test]
    fn warming_a_disconnected_launchable_game_asks_for_a_launch() {
        let mut night = GameNight::default();
        night.set_library(vec![
            gamenight_protocol::GameMeta {
                id: GameId::new("launchable"),
                title: "Launchable".into(),
                tagline: None,
                cover: None,
                color: None,
                emoji: None,
                players: None,
                min_players: None,
                max_players: None,
                best_players: None,
                launch: Some(gamenight_protocol::LaunchSpec {
                    command: "/games/launchable".into(),
                    args: vec![],
                    cwd: None,
                    env: Default::default(),
                }),
            },
            gamenight_protocol::GameMeta {
                id: GameId::new("manual"),
                title: "Manual".into(),
                tagline: None,
                cover: None,
                color: None,
                emoji: None,
                players: None,
                min_players: None,
                max_players: None,
                best_players: None,
                launch: None,
            },
        ]);

        // No process connected: the launchable game asks for a spawn...
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("launchable")],
        });
        assert!(fx.contains(&Effect::Launch {
            game: GameId::new("launchable")
        }));
        assert!(prepared_session(&fx).is_none(), "cannot warm yet");

        // ...a game with no launch spec just waits...
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("manual")],
        });
        assert!(!fx.iter().any(|e| matches!(e, Effect::Launch { .. })));

        // ...and once the launched process connects, warming proceeds.
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("launchable")],
        });
        assert!(fx.contains(&Effect::Launch {
            game: GameId::new("launchable")
        }));
        let fx = night.handle(Command::GameConnected {
            game: GameId::new("launchable"),
        });
        let (g, _) = prepared_session(&fx).expect("warms on connect");
        assert_eq!(g, GameId::new("launchable"));
    }

    #[test]
    fn play_next_with_nothing_playing_starts_the_night() {
        let mut night = GameNight::default();
        night.handle(Command::GameConnected {
            game: GameId::new("g1"),
        });
        // Empty playlist, no active game: play-next is "start here".
        let fx = night.handle(Command::PlayNext {
            game: GameId::new("g1"),
        });
        let (_, s1) = prepared_session(&fx).expect("g1 warms from scratch");
        let fx = night.handle(Command::SessionReady { session: s1 });
        assert_eq!(started_session(&fx), Some(s1));
    }

    #[test]
    fn swap_seats_trades_occupants() {
        let mut night = GameNight::default();
        night.handle(join_cmd("A", None, None));
        night.handle(join_cmd("B", None, None));
        let snap = night.snapshot();
        let (a, b) = (snap.players[0].id, snap.players[1].id);

        night.handle(Command::SwapSeats { a: 0, b: 1 });
        let snap = night.snapshot();
        assert_eq!(snap.seats[0].occupant.player_id(), Some(b));
        assert_eq!(snap.seats[1].occupant.player_id(), Some(a));

        // Swapping with an empty seat moves the player over.
        night.handle(Command::SwapSeats { a: 1, b: 3 });
        let snap = night.snapshot();
        assert!(snap.seats[1].occupant.is_empty());
        assert_eq!(snap.seats[3].occupant.player_id(), Some(a));

        let fx = night.handle(Command::SwapSeats { a: 0, b: 9 });
        assert!(matches!(fx[0], Effect::Reject { .. }));
    }

    #[test]
    fn join_prefers_requested_seat() {
        let mut night = GameNight::default();
        night.handle(join_cmd("A", Some(2), None));
        let snap = night.snapshot();
        let a = snap.players[0].id;
        assert_eq!(snap.seats[2].occupant.player_id(), Some(a));

        // Taken seat falls back to the first free one.
        night.handle(join_cmd("B", Some(2), None));
        let snap = night.snapshot();
        assert_eq!(snap.seats[0].occupant.player_id(), Some(snap.players[1].id));
    }

    #[test]
    fn reassigning_a_player_moves_them() {
        let mut night = GameNight::default();
        night.handle(join_cmd("A", None, None));
        let a = night.snapshot().players[0].id;
        night.handle(Command::AssignSeat {
            seat: 3,
            occupant: SeatOccupant::Local { player_id: a },
        });
        let snap = night.snapshot();
        assert!(snap.seats[0].occupant.is_empty());
        assert_eq!(snap.seats[3].occupant.player_id(), Some(a));

        let fx = night.handle(Command::AssignSeat {
            seat: 9,
            occupant: SeatOccupant::Ai,
        });
        assert!(matches!(fx[0], Effect::Reject { .. }));
    }

    #[test]
    fn holdout_leaving_completes_the_vote() {
        let mut night = GameNight::default();
        night.handle(join_cmd("A", None, None));
        night.handle(join_cmd("B", None, None));
        let snap = night.snapshot();
        let (a, b) = (snap.players[0].id, snap.players[1].id);
        night.handle(Command::GameConnected {
            game: GameId::new("g1"),
        });
        night.handle(Command::GameConnected {
            game: GameId::new("g2"),
        });
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("g1"), entry("g2")],
        });
        let (_, s1) = prepared_session(&fx).unwrap();
        let fx = night.handle(Command::SessionReady { session: s1 });
        let (_, s2) = prepared_session(&fx).unwrap();
        night.handle(Command::SessionReady { session: s2 });
        night.handle(Command::SessionFinished { session: s1 });

        night.handle(Command::Vote {
            player_id: a,
            option: VoteOption::NextGame,
        });
        // B never votes and walks out: A's vote is now unanimous.
        let fx = night.handle(Command::LeaveParty { player_id: b });
        assert_eq!(started_session(&fx), Some(s2));
    }

    #[test]
    fn active_game_crash_rolls_to_warm_session() {
        let mut night = GameNight::default();
        night.handle(Command::GameConnected {
            game: GameId::new("g1"),
        });
        night.handle(Command::GameConnected {
            game: GameId::new("g2"),
        });
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("g1"), entry("g2")],
        });
        let (_, s1) = prepared_session(&fx).unwrap();
        let fx = night.handle(Command::SessionReady { session: s1 });
        let (_, s2) = prepared_session(&fx).unwrap();
        night.handle(Command::SessionReady { session: s2 });

        // g1's process dies mid-game: the night continues on g2.
        let fx = night.handle(Command::GameDisconnected {
            game: GameId::new("g1"),
        });
        assert_eq!(started_session(&fx), Some(s2));
        assert_eq!(night.snapshot().history, vec![GameId::new("g1")]);
    }

    #[test]
    fn stale_session_ids_are_rejected() {
        let mut night = GameNight::default();
        let fx = night.handle(Command::SessionReady {
            session: SessionId::new(),
        });
        assert!(matches!(fx[0], Effect::Reject { .. }));
        let fx = night.handle(Command::SessionFinished {
            session: SessionId::new(),
        });
        assert!(matches!(fx[0], Effect::Reject { .. }));
    }

    #[test]
    fn spectator_votes_are_ignored() {
        let mut night = GameNight::new(1);
        night.handle(join_cmd("Seated", None, None));
        night.handle(join_cmd("Spec", None, None));
        let snap = night.snapshot();
        let spectator = snap.players[1].id;

        night.handle(Command::GameConnected {
            game: GameId::new("g1"),
        });
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("g1")],
        });
        let (_, s1) = prepared_session(&fx).unwrap();
        night.handle(Command::SessionReady { session: s1 });
        night.handle(Command::SessionFinished { session: s1 });

        let fx = night.handle(Command::Vote {
            player_id: spectator,
            option: VoteOption::Quit,
        });
        assert!(!fx.contains(&Effect::PartyOver));
    }

    // -- match settings ------------------------------------------------------

    use gamenight_protocol::{SettingKind, SettingSpec, SettingValue};

    fn toggle(key: &str, default: bool) -> SettingSpec {
        SettingSpec {
            key: key.into(),
            label: key.to_uppercase(),
            description: None,
            kind: SettingKind::Toggle { default },
        }
    }

    fn setting_pushed(fx: &[Effect]) -> Option<(&GameId, &str, &SettingValue)> {
        fx.iter().find_map(|e| match e {
            Effect::SettingChanged { game, key, value } => Some((game, key.as_str(), value)),
            _ => None,
        })
    }

    #[test]
    fn settings_declare_set_and_validate() {
        let mut night = GameNight::default();
        let g = GameId::new("g1");
        let fx = night.handle(Command::DeclareSettings {
            game: g.clone(),
            settings: vec![
                toggle("items", true),
                SettingSpec {
                    key: "stock".into(),
                    label: "Stock".into(),
                    description: None,
                    kind: SettingKind::Number {
                        default: 3,
                        min: 1,
                        max: 99,
                    },
                },
            ],
        });
        // Defaults only: nothing to push to the game yet.
        assert!(setting_pushed(&fx).is_none());
        let snap = night.snapshot();
        assert_eq!(snap.settings.len(), 1);
        assert_eq!(snap.settings[0].values["items"], SettingValue::Toggle(true));

        // A valid write lands in the snapshot and is pushed to the game.
        let fx = night.handle(Command::SetSetting {
            game: Some(g.clone()),
            key: "items".into(),
            value: SettingValue::Toggle(false),
        });
        let (game, key, value) = setting_pushed(&fx).unwrap();
        assert_eq!(
            (game, key, value),
            (&g, "items", &SettingValue::Toggle(false))
        );
        assert_eq!(
            night.snapshot().settings[0].values["items"],
            SettingValue::Toggle(false)
        );

        // Unknown keys are named-and-listed; bad values state the rule.
        let fx = night.handle(Command::SetSetting {
            game: Some(g.clone()),
            key: "itemz".into(),
            value: SettingValue::Toggle(true),
        });
        assert!(matches!(&fx[0], Effect::Reject { reason }
            if reason.contains("no setting 'itemz'") && reason.contains("items, stock")));
        let fx = night.handle(Command::SetSetting {
            game: Some(g.clone()),
            key: "stock".into(),
            value: SettingValue::Number(500),
        });
        assert!(matches!(&fx[0], Effect::Reject { reason }
            if reason.contains("between 1 and 99")));

        // Writing the current value again changes nothing → no push.
        let fx = night.handle(Command::SetSetting {
            game: Some(g),
            key: "items".into(),
            value: SettingValue::Toggle(false),
        });
        assert!(setting_pushed(&fx).is_none());
    }

    #[test]
    fn set_setting_defaults_to_the_active_game() {
        let mut night = GameNight::default();
        let fx = night.handle(Command::SetSetting {
            game: None,
            key: "items".into(),
            value: SettingValue::Toggle(false),
        });
        assert!(matches!(&fx[0], Effect::Reject { reason }
            if reason.contains("nothing is playing")));

        night.handle(Command::GameConnected {
            game: GameId::new("g1"),
        });
        night.handle(Command::DeclareSettings {
            game: GameId::new("g1"),
            settings: vec![toggle("items", true)],
        });
        let fx = night.handle(Command::SetPlaylist {
            entries: vec![entry("g1")],
        });
        let (_, s1) = prepared_session(&fx).unwrap();
        night.handle(Command::SessionReady { session: s1 });

        // g1 is live: "disable items" needs no game id.
        let fx = night.handle(Command::SetSetting {
            game: None,
            key: "items".into(),
            value: SettingValue::Toggle(false),
        });
        assert!(setting_pushed(&fx).is_some());
    }

    #[test]
    fn changed_values_survive_reconnect_and_redeclare() {
        let mut night = GameNight::default();
        let g = GameId::new("g1");
        night.handle(Command::DeclareSettings {
            game: g.clone(),
            settings: vec![toggle("items", true)],
        });
        night.handle(Command::SetSetting {
            game: Some(g.clone()),
            key: "items".into(),
            value: SettingValue::Toggle(false),
        });

        // The process crashes and comes back: values survive, and the
        // re-declaration replays every non-default value to the game.
        night.handle(Command::GameDisconnected { game: g.clone() });
        assert_eq!(
            night.snapshot().settings[0].values["items"],
            SettingValue::Toggle(false)
        );
        let fx = night.handle(Command::DeclareSettings {
            game: g.clone(),
            settings: vec![toggle("items", true), toggle("teams", false)],
        });
        let (_, key, value) = setting_pushed(&fx).unwrap();
        assert_eq!((key, value), ("items", &SettingValue::Toggle(false)));
        // The new knob starts at its default.
        assert_eq!(
            night.snapshot().settings[0].values["teams"],
            SettingValue::Toggle(false)
        );
    }

    #[test]
    fn malformed_declarations_are_rejected() {
        let mut night = GameNight::default();
        let fx = night.handle(Command::DeclareSettings {
            game: GameId::new("g1"),
            settings: vec![toggle("items", true), toggle("items", false)],
        });
        assert!(matches!(&fx[0], Effect::Reject { reason }
            if reason.contains("duplicate setting key 'items'")));

        let fx = night.handle(Command::DeclareSettings {
            game: GameId::new("g1"),
            settings: vec![SettingSpec {
                key: "arena".into(),
                label: "Arena".into(),
                description: None,
                kind: SettingKind::Choice {
                    default: "moon".into(),
                    options: vec!["meadow".into()],
                },
            }],
        });
        assert!(matches!(&fx[0], Effect::Reject { reason }
            if reason.contains("illegal default")));
        assert!(night.snapshot().settings.is_empty());
    }

    /// A persistent lobby sits in the shelf right alongside the
    /// games it launches into — it has to, since the shelf is also where
    /// its own launch spec lives. Rotation must still skip straight past it.
    #[test]
    fn warm_never_targets_the_lobby_game() {
        let mut night = GameNight::default();
        night.set_lobby_game(Some(GameId::new("lobby")));
        night.set_library(vec![meta("lobby"), meta("towerfall")]);

        night.handle(Command::GameConnected {
            game: GameId::new("lobby"),
        });
        let fx = night.handle(Command::GameConnected {
            game: GameId::new("towerfall"),
        });

        let (game, _) = prepared_session(&fx).expect("towerfall warms");
        assert_eq!(game, GameId::new("towerfall"));
        assert!(night.snapshot().warm_session.is_some());
    }

    /// With no lobby, the very first ready game auto-starts (see
    /// `full_night_flow`). With one, nothing has ever been `active` for as
    /// long as the lobby's running — that must not be mistaken for "the
    /// night hasn't started yet" and auto-launch the first warm game out
    /// from under whoever's still deciding in the lobby.
    #[test]
    fn ready_first_game_does_not_autostart_over_a_lobby() {
        let mut night = GameNight::default();
        night.set_lobby_game(Some(GameId::new("lobby")));
        night.set_library(vec![meta("lobby"), meta("towerfall")]);

        night.handle(Command::GameConnected {
            game: GameId::new("lobby"),
        });
        let fx = night.handle(Command::GameConnected {
            game: GameId::new("towerfall"),
        });
        let (_, warm) = prepared_session(&fx).expect("towerfall warms");

        let fx = night.handle(Command::SessionReady { session: warm });
        assert_eq!(started_session(&fx), None);
        assert!(night.snapshot().active_session.is_none());

        // An explicit Next actually starts it.
        let fx = night.handle(Command::Next);
        assert_eq!(started_session(&fx), Some(warm));
    }

    fn lobby_focus(fx: &[Effect]) -> Option<bool> {
        fx.iter().find_map(|e| match e {
            Effect::LobbyFocus { active, .. } => Some(*active),
            _ => None,
        })
    }

    /// The lobby needs to know when to mute itself and step out of the way
    /// (some other game just took over), and when to reclaim the screen
    /// (that game's gone and nothing replaced it) — exactly once per actual
    /// change, not spammed on every unrelated command.
    #[test]
    fn lobby_focus_follows_whether_anything_else_is_active() {
        let mut night = GameNight::default();
        night.set_lobby_game(Some(GameId::new("lobby")));
        night.set_library(vec![meta("lobby"), meta("towerfall")]);

        // The lobby connecting is always told where it stands — it has no way
        // to know (see `a_freshly_connected_lobby_is_told_whether_it_has_the
        // _screen`). Nothing else is running, so: the screen is yours.
        let fx = night.handle(Command::GameConnected {
            game: GameId::new("lobby"),
        });
        assert_eq!(lobby_focus(&fx), Some(true));

        let fx = night.handle(Command::GameConnected {
            game: GameId::new("towerfall"),
        });
        let (_, warm) = prepared_session(&fx).expect("towerfall warms");
        // Warming isn't playing yet — the lobby still has the room.
        assert_eq!(lobby_focus(&fx), None);

        // Ready + an explicit Next actually starts towerfall — now the lobby
        // yields.
        night.handle(Command::SessionReady { session: warm });
        let fx = night.handle(Command::Next);
        assert_eq!(started_session(&fx), Some(warm));
        assert_eq!(lobby_focus(&fx), Some(false));

        // Repeating a no-op command doesn't re-fire it.
        let fx = night.handle(Command::GameConnected {
            game: GameId::new("towerfall"),
        });
        assert_eq!(lobby_focus(&fx), None);

        // towerfall crashes with nothing warm to replace it — the lobby
        // reclaims focus.
        let fx = night.handle(Command::GameDisconnected {
            game: GameId::new("towerfall"),
        });
        assert_eq!(lobby_focus(&fx), Some(true));
    }

    /// A warming game may report how far along it is, so the lobby's screen
    /// can show the party something that moves. Optional, clamped, and only
    /// ever about the session that's actually still loading.
    #[test]
    fn a_warming_game_can_report_its_loading_progress() {
        let mut night = GameNight::default();
        night.set_lobby_game(Some(GameId::new("lobby")));
        night.set_library(vec![meta("lobby"), meta("towerfall")]);

        night.handle(Command::GameConnected {
            game: GameId::new("lobby"),
        });
        let fx = night.handle(Command::GameConnected {
            game: GameId::new("towerfall"),
        });
        let (_, warm) = prepared_session(&fx).expect("towerfall warms");

        // Nothing reported yet: no invented number.
        assert_eq!(night.snapshot().warm_session.unwrap().progress, None);

        night.handle(Command::SessionProgress {
            session: warm,
            percent: 40,
            label: Some("loading the arena".into()),
        });
        let info = night.snapshot().warm_session.unwrap();
        assert_eq!(info.progress, Some(40));
        assert_eq!(info.progress_label.as_deref(), Some("loading the arena"));

        // A game that overshoots doesn't get to put 250% on the TV.
        night.handle(Command::SessionProgress {
            session: warm,
            percent: 250,
            label: None,
        });
        assert_eq!(night.snapshot().warm_session.unwrap().progress, Some(100));

        // Repeating the same value changes nothing, so screens aren't woken
        // for a report that says what they already show.
        let fx = night.handle(Command::SessionProgress {
            session: warm,
            percent: 100,
            label: None,
        });
        assert!(
            fx.is_empty(),
            "unchanged progress should produce no effects"
        );

        // Progress for a session that isn't the warm one is a normal race
        // (it just started, or was disposed), not an error to surface.
        let fx = night.handle(Command::SessionProgress {
            session: gamenight_protocol::SessionId::new(),
            percent: 10,
            label: None,
        });
        assert!(fx.is_empty());
    }

    /// A game downloading in the background is visible to every screen before
    /// it is playable, so the party can watch it arrive instead of staring at
    /// a shelf that silently grows.
    #[test]
    fn install_progress_reaches_the_snapshot() {
        let mut night = GameNight::default();

        let status = |state, percent| gamenight_protocol::InstallStatus {
            game: GameId::new("growing-guns"),
            title: "Growing Guns".into(),
            state,
            percent,
            label: None,
        };

        let fx = night.handle(Command::InstallProgress {
            status: status(gamenight_protocol::InstallState::Downloading, Some(30)),
        });
        assert!(fx.contains(&Effect::StateChanged));
        let installs = night.snapshot().installs;
        assert_eq!(installs.len(), 1);
        assert_eq!(installs[0].percent, Some(30));

        // The same report twice doesn't wake every screen in the house.
        let fx = night.handle(Command::InstallProgress {
            status: status(gamenight_protocol::InstallState::Downloading, Some(30)),
        });
        assert!(
            fx.is_empty(),
            "an unchanged report should produce no effects"
        );

        // One entry per game, updated in place — not a growing log.
        night.handle(Command::InstallProgress {
            status: status(gamenight_protocol::InstallState::Downloading, Some(70)),
        });
        let installs = night.snapshot().installs;
        assert_eq!(installs.len(), 1);
        assert_eq!(installs[0].percent, Some(70));

        // An installer that overshoots doesn't get to put 250% on the TV.
        night.handle(Command::InstallProgress {
            status: status(gamenight_protocol::InstallState::Downloading, Some(250)),
        });
        assert_eq!(night.snapshot().installs[0].percent, Some(100));
    }

    /// The host's music reaches every screen, and only says so when it
    /// actually changed — the watcher polls far more often than a track
    /// changes, and each broadcast is a whole party snapshot.
    #[test]
    fn now_playing_reaches_the_snapshot_only_when_it_changes() {
        let mut night = GameNight::default();
        let track = |title: &str, playing| gamenight_protocol::NowPlaying {
            title: title.into(),
            artist: "Gabriel Fauré".into(),
            playing,
            source: "Spotify".into(),
        };

        // Nothing on: nothing to render, and nothing said about it.
        assert!(night.snapshot().now_playing.is_none());
        assert!(night.handle(Command::NowPlaying { track: None }).is_empty());

        let fx = night.handle(Command::NowPlaying {
            track: Some(track("In Paradisum", true)),
        });
        assert!(fx.contains(&Effect::StateChanged));
        assert_eq!(
            night.snapshot().now_playing.map(|t| t.title),
            Some("In Paradisum".to_string())
        );

        let fx = night.handle(Command::NowPlaying {
            track: Some(track("In Paradisum", true)),
        });
        assert!(fx.is_empty(), "the same track again should wake nobody");

        // The music stopping is a change like any other.
        let fx = night.handle(Command::NowPlaying { track: None });
        assert!(fx.contains(&Effect::StateChanged));
        assert!(night.snapshot().now_playing.is_none());
    }

    /// A pad press goes out to the host machine — and play/pause flips what
    /// the lobby shows immediately, rather than waiting a poll to admit
    /// anything happened.
    #[test]
    fn a_pad_press_controls_the_hosts_music() {
        let mut night = GameNight::default();
        use gamenight_protocol::MediaAction;

        // Nothing playing: nothing to control, and no complaint about it.
        assert!(night
            .handle(Command::MediaControl {
                action: MediaAction::PlayPause,
            })
            .is_empty());

        night.handle(Command::NowPlaying {
            track: Some(gamenight_protocol::NowPlaying {
                title: "In Paradisum".into(),
                artist: "Gabriel Fauré".into(),
                playing: true,
                source: "Spotify".into(),
            }),
        });

        let fx = night.handle(Command::MediaControl {
            action: MediaAction::PlayPause,
        });
        assert!(fx.contains(&Effect::MediaControl {
            action: MediaAction::PlayPause
        }));
        assert!(fx.contains(&Effect::StateChanged));
        assert_eq!(night.snapshot().now_playing.map(|t| t.playing), Some(false));

        // A skip is sent on, but the title stays whatever the host's player
        // last said it was — inventing the next one would only be wrong.
        let fx = night.handle(Command::MediaControl {
            action: MediaAction::NextTrack,
        });
        assert_eq!(
            fx,
            vec![Effect::MediaControl {
                action: MediaAction::NextTrack
            }]
        );
        assert_eq!(
            night.snapshot().now_playing.map(|t| t.title),
            Some("In Paradisum".to_string())
        );
    }

    /// Whatever is actually moving leads the list, so a screen that shows one
    /// line shows the right one without knowing the ordering rules.
    #[test]
    fn installs_are_ordered_by_what_is_actually_happening() {
        let mut night = GameNight::default();
        let status = |id: &str, state| gamenight_protocol::InstallStatus {
            game: GameId::new(id),
            title: id.to_uppercase(),
            state,
            percent: None,
            label: None,
        };
        use gamenight_protocol::InstallState::*;

        for (id, state) in [
            ("done", Installed),
            ("queued", Queued),
            ("broken", Failed),
            ("moving", Downloading),
        ] {
            night.handle(Command::InstallProgress {
                status: status(id, state),
            });
        }

        let order: Vec<_> = night
            .snapshot()
            .installs
            .iter()
            .map(|i| i.game.0.clone())
            .collect();
        assert_eq!(order, vec!["moving", "queued", "done", "broken"]);
    }

    /// The payoff for all the progress plumbing: when the download lands, the
    /// game is playable *now*. Without this the party watches a bar reach
    /// 100% and then has nothing to press until the daemon restarts.
    #[test]
    fn a_finished_install_joins_the_shelf_and_the_playlist() {
        let mut night = GameNight::default();
        night.set_library(vec![meta("lobby")]);

        let fx = night.add_to_library(meta("growing-guns"));
        assert!(fx.contains(&Effect::StateChanged));

        let snap = night.snapshot();
        assert!(snap
            .library
            .iter()
            .any(|m| m.id == GameId::new("growing-guns")));
        assert!(
            snap.playlist
                .entries
                .iter()
                .any(|e| e.game == GameId::new("growing-guns")),
            "a game nobody can queue is not really on the shelf"
        );

        // A re-install must not produce the game twice.
        night.add_to_library(meta("growing-guns"));
        let snap = night.snapshot();
        assert_eq!(snap.library.len(), 2);
        assert_eq!(snap.playlist.entries.len(), 2);
    }

    /// Calling up the party overlay mid-match is the way back to the lobby:
    /// the game pauses and the lobby takes the screen, and closing the
    /// overlay hands both back. Without this the only exit from a running
    /// game is ending it.
    #[test]
    fn the_overlay_hands_the_screen_back_to_the_lobby_and_returns_it() {
        let mut night = GameNight::default();
        night.set_lobby_game(Some(GameId::new("lobby")));
        night.set_library(vec![meta("lobby"), meta("towerfall")]);

        night.handle(Command::GameConnected {
            game: GameId::new("lobby"),
        });
        let fx = night.handle(Command::GameConnected {
            game: GameId::new("towerfall"),
        });
        let (_, warm) = prepared_session(&fx).expect("towerfall warms");
        night.handle(Command::SessionReady { session: warm });
        let fx = night.handle(Command::Next);
        assert_eq!(lobby_focus(&fx), Some(false), "towerfall took the screen");

        // Overlay up: towerfall pauses and the lobby is what to look at.
        let fx = night.handle(Command::OverlayOpened);
        assert_eq!(lobby_focus(&fx), Some(true));
        assert_eq!(
            night.snapshot().active_session.map(|s| s.phase),
            Some(SessionPhase::Paused),
        );

        // Overlay away: towerfall resumes and takes the screen back.
        let fx = night.handle(Command::OverlayClosed);
        assert_eq!(lobby_focus(&fx), Some(false));
        assert_eq!(
            night.snapshot().active_session.map(|s| s.phase),
            Some(SessionPhase::Running),
        );
    }

    /// Cmd+Tab is a "go".
    ///
    /// The party can always reach for a window, and the window server has the
    /// final say over who gets the screen — so reaching for a game is the
    /// clearest statement of intent there is. A warm game switched to starts;
    /// a paused game switched to resumes; a game with nothing ready to play
    /// does nothing at all, because a stray focus event must never be able to
    /// change the night's plan.
    #[test]
    fn reaching_for_a_games_window_is_a_go_signal() {
        let mut night = GameNight::default();
        night.set_lobby_game(Some(GameId::new("lobby")));
        night.set_library(vec![meta("lobby"), meta("towerfall")]);

        night.handle(Command::GameConnected {
            game: GameId::new("lobby"),
        });
        let fx = night.handle(Command::GameConnected {
            game: GameId::new("towerfall"),
        });
        let (_, warm) = prepared_session(&fx).expect("towerfall warms");

        // Still loading: reaching for it can't start what isn't ready, and it
        // must not quietly rearrange the night either.
        let fx = night.handle(Command::RequestStart {
            game: GameId::new("towerfall"),
        });
        assert_eq!(started_session(&fx), None);
        assert_eq!(night.snapshot().active_session, None);

        // Ready and warm: switching to its window is the party asking to play.
        night.handle(Command::SessionReady { session: warm });
        let fx = night.handle(Command::RequestStart {
            game: GameId::new("towerfall"),
        });
        assert_eq!(started_session(&fx), Some(warm));
        assert_eq!(lobby_focus(&fx), Some(false), "the lobby steps back");

        // Out to the party, then back to the game's window: that's "back in".
        night.handle(Command::OverlayOpened);
        assert_eq!(
            night.snapshot().active_session.map(|s| s.phase),
            Some(SessionPhase::Paused),
        );
        let fx = night.handle(Command::RequestStart {
            game: GameId::new("towerfall"),
        });
        assert_eq!(
            night.snapshot().active_session.map(|s| s.phase),
            Some(SessionPhase::Running),
        );
        assert_eq!(lobby_focus(&fx), Some(false));

        // A game nobody warmed, whose window happened to get focus: nothing.
        let before = night.snapshot();
        let fx = night.handle(Command::RequestStart {
            game: GameId::new("some-other-game"),
        });
        assert!(fx.is_empty());
        assert_eq!(night.snapshot().active_session, before.active_session);
    }

    /// An explicitly paused night stays paused: reaching for the game's window
    /// is not a licence to undo a pause the party asked for by hand.
    #[test]
    fn reaching_for_a_deliberately_paused_game_leaves_it_paused() {
        let mut night = GameNight::default();
        night.set_lobby_game(Some(GameId::new("lobby")));
        night.set_library(vec![meta("lobby"), meta("towerfall")]);

        night.handle(Command::GameConnected {
            game: GameId::new("lobby"),
        });
        let fx = night.handle(Command::GameConnected {
            game: GameId::new("towerfall"),
        });
        let (_, warm) = prepared_session(&fx).expect("towerfall warms");
        night.handle(Command::SessionReady { session: warm });
        night.handle(Command::Next);

        night.handle(Command::Pause);
        night.handle(Command::RequestStart {
            game: GameId::new("towerfall"),
        });
        assert_eq!(
            night.snapshot().active_session.map(|s| s.phase),
            Some(SessionPhase::Paused),
            "only the party un-pauses what the party paused",
        );
    }

    /// A lobby process that has just connected is told where it stands, both
    /// ways round. It cannot know: it comes up as the daemon's background
    /// child, which is not the same as having the couch's attention — and if
    /// it restarted mid-match, coming up "focused by default" would put it on
    /// top of the game the party is playing.
    #[test]
    fn a_freshly_connected_lobby_is_told_whether_it_has_the_screen() {
        let mut night = GameNight::default();
        night.set_lobby_game(Some(GameId::new("lobby")));
        night.set_library(vec![meta("lobby"), meta("towerfall")]);

        // Nothing playing: the lobby is what the couch should be looking at,
        // and nobody else is going to bring it forward.
        let fx = night.handle(Command::GameConnected {
            game: GameId::new("lobby"),
        });
        assert_eq!(lobby_focus(&fx), Some(true));

        let fx = night.handle(Command::GameConnected {
            game: GameId::new("towerfall"),
        });
        let (_, warm) = prepared_session(&fx).expect("towerfall warms");
        night.handle(Command::SessionReady { session: warm });
        night.handle(Command::Next);

        // The lobby crashed and came back mid-match: it does not get the
        // screen just because it is new.
        night.handle(Command::GameDisconnected {
            game: GameId::new("lobby"),
        });
        let fx = night.handle(Command::GameConnected {
            game: GameId::new("lobby"),
        });
        assert_eq!(lobby_focus(&fx), Some(false));
    }

    /// The game that's playing is not a game that's loading. On a shelf of
    /// one playable title, rotation's next target is the title already on
    /// screen — and `maybe_warm` won't touch it, since one process hosts one
    /// session. Reporting it as `warming` anyway left the lobby's TV stuck on
    /// "LOADING… <the game you are currently playing>" for the whole match.
    #[test]
    fn the_game_thats_playing_is_never_reported_as_warming() {
        let mut night = GameNight::default();
        night.set_lobby_game(Some(GameId::new("lobby")));
        night.set_library(vec![meta("towerfall"), meta("lobby")]);

        night.handle(Command::GameConnected {
            game: GameId::new("lobby"),
        });
        let fx = night.handle(Command::GameConnected {
            game: GameId::new("towerfall"),
        });
        let (_, warm) = prepared_session(&fx).expect("towerfall warms");

        // Still warming: that's a truthful "loading".
        assert_eq!(
            night.snapshot().warming.map(|e| e.game),
            None,
            "a warm session reports through warm_session, not warming"
        );
        night.handle(Command::SessionReady { session: warm });
        night.handle(Command::Next);

        // Now it's the active game, and the only other shelf entry is the
        // lobby — so there is nothing left to warm and nothing to claim is.
        let snapshot = night.snapshot();
        assert_eq!(
            snapshot.active_session.map(|s| s.game),
            Some(GameId::new("towerfall"))
        );
        assert_eq!(snapshot.warm_session, None);
        assert_eq!(snapshot.warming, None, "the running game is not loading");
    }
}

#[cfg(test)]
mod player_count_fit_tests {
    use super::night::*;
    use gamenight_protocol::*;

    /// Session ids the effects say to dispose.
    fn disposed_sessions(fx: &[Effect]) -> Vec<SessionId> {
        fx.iter()
            .filter_map(|e| match e {
                Effect::ToGame {
                    session,
                    command: GameCommand::Dispose,
                    ..
                } => Some(*session),
                _ => None,
            })
            .collect()
    }

    /// The game and session of the single `Prepare` effect, if present.
    fn prepared_session(fx: &[Effect]) -> Option<(GameId, SessionId)> {
        fx.iter().find_map(|e| match e {
            Effect::ToGame {
                game,
                session,
                command: GameCommand::Prepare { .. },
            } => Some((game.clone(), *session)),
            _ => None,
        })
    }

    /// The seats carried by the single `Prepare` effect, if present.
    fn prepared_seats(fx: &[Effect]) -> Option<Vec<Seat>> {
        fx.iter().find_map(|e| match e {
            Effect::ToGame {
                command: GameCommand::Prepare { seats, .. },
                ..
            } => Some(seats.clone()),
            _ => None,
        })
    }

    fn game(id: &str, min: u8, max: u8, best: Option<u8>) -> GameMeta {
        GameMeta {
            id: GameId::new(id),
            title: id.into(),
            tagline: None,
            cover: None,
            color: None,
            emoji: None,
            players: None,
            min_players: Some(min),
            max_players: Some(max),
            best_players: best,
            launch: Some(LaunchSpec {
                command: "/bin/true".into(),
                args: vec![],
                cwd: None,
                env: Default::default(),
            }),
        }
    }

    fn join(name: &str) -> Command {
        Command::JoinParty {
            name: name.into(),
            seat: None,
            color: None,
            avatar: None,
            library: vec![],
        }
    }

    /// A game whose range excludes the party must not be warmed.
    #[test]
    fn warms_a_game_that_fits_the_party() {
        let mut night = GameNight::default();
        // "four-only" is first in rotation, so only fit-filtering can keep it
        // from being chosen.
        night.set_library(vec![game("four-only", 4, 4, None), game("duo", 2, 2, None)]);
        night.handle(join("a"));
        night.handle(join("b"));
        night.handle(Command::GameConnected {
            game: GameId::new("duo"),
        });

        let warm = night.snapshot().warm_session.map(|s| s.game);
        assert_eq!(
            warm,
            Some(GameId::new("duo")),
            "two players must not be handed a four-player-only game"
        );
    }

    /// The promise is that the next game is always warm *and correct*. Gaining
    /// a player must swap a game that no longer fits.
    #[test]
    fn a_new_seat_rewarms_when_the_game_stops_fitting() {
        let mut night = GameNight::default();
        night.set_library(vec![game("duo", 2, 2, None), game("quad", 3, 4, None)]);
        night.handle(join("a"));
        night.handle(join("b"));
        night.handle(Command::GameConnected {
            game: GameId::new("duo"),
        });
        assert_eq!(
            night.snapshot().warm_session.map(|s| s.game),
            Some(GameId::new("duo")),
            "two players start on the two-player game"
        );

        // A third person sits down: "duo" is now wrong.
        night.handle(join("c"));
        night.handle(Command::GameConnected {
            game: GameId::new("quad"),
        });
        assert_eq!(
            night.snapshot().warm_session.map(|s| s.game),
            Some(GameId::new("quad")),
            "a third player must swap the warm game for one that fits"
        );
    }

    /// …and shrinking counts too.
    #[test]
    fn leaving_rewarms_when_the_game_stops_fitting() {
        let mut night = GameNight::default();
        night.set_library(vec![game("quad", 3, 4, None), game("duo", 1, 2, None)]);
        for n in ["a", "b", "c"] {
            night.handle(join(n));
        }
        night.handle(Command::GameConnected {
            game: GameId::new("quad"),
        });
        assert_eq!(
            night.snapshot().warm_session.map(|s| s.game),
            Some(GameId::new("quad"))
        );

        let leaver = night.snapshot().players[0].id;
        night.handle(Command::LeaveParty { player_id: leaver });
        night.handle(Command::GameConnected {
            game: GameId::new("duo"),
        });
        assert_eq!(
            night.snapshot().warm_session.map(|s| s.game),
            Some(GameId::new("duo")),
            "dropping to two players must swap off the 3-4 player game"
        );
    }

    /// A game that still fits keeps its slot — but not its session: it was
    /// prepared for a party of one and there are two people now. `prepare`
    /// is the only time a game is told who is playing, so the seating change
    /// has to arrive as a fresh session or it never arrives at all.
    #[test]
    fn a_join_rewarms_a_still_fitting_game_for_the_new_seating() {
        let mut night = GameNight::default();
        night.set_library(vec![game("wide", 1, 4, None), game("other", 1, 4, None)]);
        night.handle(join("a"));
        night.handle(Command::GameConnected {
            game: GameId::new("wide"),
        });
        let before = night.snapshot().warm_session.map(|s| s.id);
        assert!(before.is_some());

        let fx = night.handle(join("b"));
        assert_eq!(
            disposed_sessions(&fx),
            before.into_iter().collect::<Vec<_>>()
        );
        let (game_id, after) = prepared_session(&fx).expect("warms again for two");
        assert_eq!(game_id, GameId::new("wide"), "same game, new session");
        assert_ne!(Some(after), before);
        let seats = prepared_seats(&fx).expect("prepare carries the new seating");
        assert_eq!(
            seats.iter().filter(|s| !s.occupant.is_empty()).count(),
            2,
            "the second player must be in the seats the game is given"
        );
    }

    /// Re-warming throws away a loaded process, so only seating does it.
    /// Everything else about a player — their name, their avatar — leaves the
    /// warm session exactly where it is.
    #[test]
    fn a_rename_leaves_the_warm_session_alone() {
        let mut night = GameNight::default();
        night.set_library(vec![game("wide", 1, 4, None)]);
        night.handle(join("a"));
        night.handle(Command::GameConnected {
            game: GameId::new("wide"),
        });
        let before = night.snapshot().warm_session.map(|s| s.id);
        assert!(before.is_some());

        let player_id = night.snapshot().players[0].id;
        night.handle(Command::RenamePlayer {
            player_id,
            name: "Ada".into(),
        });
        assert_eq!(
            night.snapshot().warm_session.map(|s| s.id),
            before,
            "a rename is not a seating change"
        );
    }

    /// Nothing fits: warm something anyway. A lobby that can't start a game
    /// is worse than one offering an imperfect fit.
    #[test]
    fn warms_something_even_when_nothing_fits() {
        let mut night = GameNight::default();
        night.set_library(vec![game("five-plus", 5, 8, None)]);
        for n in ["a", "b"] {
            night.handle(join(n));
        }
        night.handle(Command::GameConnected {
            game: GameId::new("five-plus"),
        });
        assert!(
            night.snapshot().warm_session.is_some(),
            "a bad fit still beats nothing warm at all"
        );
    }

    /// One person can start a two-player game: the missing seat arrives as a
    /// bot, decided here rather than guessed at by every game separately.
    #[test]
    fn prepare_fills_empty_seats_with_bots_up_to_min_players() {
        let mut night = GameNight::default();
        night.set_library(vec![game("duo", 2, 4, None)]);
        night.handle(join("Ada"));
        let fx = night.handle(Command::GameConnected {
            game: GameId::new("duo"),
        });
        let seats = prepared_seats(&fx).expect("warms for the party of one");
        assert!(
            matches!(seats[0].occupant, SeatOccupant::Local { .. }),
            "the person keeps their seat"
        );
        assert_eq!(seats[1].occupant, SeatOccupant::Ai, "the game gets a bot");
        assert!(seats[2].occupant.is_empty(), "and not one seat more");
        assert!(seats[3].occupant.is_empty());

        // The party itself is untouched: seat 2 is still free for a person.
        assert_eq!(night.seated_count(), 1);
        assert!(night.snapshot().seats[1].occupant.is_empty());
    }

    /// A game that never said how many players it needs gets the seats as
    /// they are — filling them would be inventing a requirement.
    #[test]
    fn prepare_leaves_seats_alone_without_a_declared_minimum() {
        let mut night = GameNight::default();
        let mut open = game("open", 2, 4, None);
        open.min_players = None;
        open.max_players = None;
        night.set_library(vec![open]);
        night.handle(join("Ada"));
        let fx = night.handle(Command::GameConnected {
            game: GameId::new("open"),
        });
        let seats = prepared_seats(&fx).expect("warms for the party of one");
        assert!(seats[1..].iter().all(|s| s.occupant.is_empty()));
    }

    /// An empty party fits everything, so the shelf is warm before anyone sits.
    #[test]
    fn an_empty_party_can_still_warm() {
        let mut night = GameNight::default();
        night.set_library(vec![game("quad", 4, 4, None)]);
        night.handle(Command::GameConnected {
            game: GameId::new("quad"),
        });
        assert!(
            night.snapshot().warm_session.is_some(),
            "warming must not wait for the first join"
        );
    }
}
