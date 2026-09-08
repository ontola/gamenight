//! The simplest possible GameNight integration: a "game" that pretends to
//! load, plays a timed match, and reports finished.
//!
//! The normal way to run it is to not run it at all: give the daemon a
//! library with a launch spec pointing here, and it spawns this process when
//! the game needs warming (identity and daemon address arrive via the
//! `GAMENIGHT_*` environment, like a real launched game).
//!
//! It also runs standalone for development:
//!
//!     demo-game towerfall 5      # id + match length in seconds
//!
//! Arguments are positional but forgiving: a number is the match length,
//! anything else is the game id. The environment wins over arguments.

use std::time::Duration;

use gamenight_protocol::{SeatOccupant, SessionId, SettingKind, SettingSpec, SettingValue};
use gamenight_sdk::{GameEvent, GameNight};
use tokio::time::{sleep, Instant};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut game_id: Option<String> = None;
    let mut match_seconds: u64 = 10;
    for arg in std::env::args().skip(1) {
        match arg.parse::<u64>() {
            Ok(secs) => match_seconds = secs,
            Err(_) => game_id = Some(arg),
        }
    }
    // Launched by a daemon? The environment is the source of truth.
    let game_id = std::env::var(gamenight_protocol::ENV_GAME_ID)
        .ok()
        .or(game_id)
        .unwrap_or_else(|| "demo".to_string());

    let mut gn = GameNight::connect(&game_id, None).await?;
    if GameNight::launched_by_daemon() {
        println!("[{game_id}] launched by the daemon, reporting for duty");
    } else {
        println!("[{game_id}] connected to the party, waiting for our turn");
    }

    // The knobs the party (overlay, or an LLM via gamenight-mcp) may turn.
    gn.declare_settings(vec![
        SettingSpec {
            key: "match_seconds".into(),
            label: "Match length".into(),
            description: Some("How long one match lasts, in seconds.".into()),
            kind: SettingKind::Number {
                default: match_seconds as i64,
                min: 1,
                max: 600,
            },
        },
        SettingSpec {
            key: "items".into(),
            label: "Items".into(),
            description: Some("Whether power-up items spawn during a match.".into()),
            kind: SettingKind::Toggle { default: true },
        },
        SettingSpec {
            key: "arena".into(),
            label: "Arena".into(),
            description: Some("Which arena the match is fought in.".into()),
            kind: SettingKind::Choice {
                default: "meadow".into(),
                options: vec!["meadow".into(), "volcano".into(), "space".into()],
            },
        },
    ])
    .await?;

    // The match currently in play: (session, when it ends).
    let mut playing: Option<(SessionId, Instant)> = None;
    let mut paused_remaining: Option<(SessionId, Duration)> = None;

    loop {
        // While a match runs, race its end against daemon events.
        if let Some((session, ends_at)) = playing {
            tokio::select! {
                _ = sleep(ends_at.saturating_duration_since(Instant::now())) => {
                    println!("[{game_id}] match over! reporting finished");
                    playing = None;
                    gn.finished(session).await?;
                }
                event = gn.next_event() => {
                    match event? {
                        Some(GameEvent::Pause { session: s }) if s == session => {
                            println!("[{game_id}] paused");
                            paused_remaining =
                                Some((session, ends_at.saturating_duration_since(Instant::now())));
                            playing = None;
                        }
                        Some(GameEvent::Dispose { session: s }) if s == session => {
                            println!("[{game_id}] session disposed mid-match (skipped)");
                            playing = None;
                        }
                        Some(GameEvent::SettingChanged { key, value }) => {
                            apply_setting(&game_id, &mut match_seconds, &key, &value);
                        }
                        Some(other) => println!("[{game_id}] ignoring {other:?} mid-match"),
                        None => break,
                    }
                }
            }
            continue;
        }

        // Idle (or paused): just wait for lifecycle events.
        match gn.next_event().await? {
            Some(GameEvent::Prepare {
                session,
                seats,
                players,
            }) => {
                let seated: Vec<String> = seats
                    .iter()
                    .filter_map(|s| match &s.occupant {
                        SeatOccupant::Empty => None,
                        SeatOccupant::Ai => Some(format!("P{}:bot", s.index + 1)),
                        occ => occ
                            .player_id()
                            .and_then(|id| players.iter().find(|p| p.id == id))
                            .map(|p| format!("P{}:{}", s.index + 1, p.name)),
                    })
                    .collect();
                println!("[{game_id}] warming up for [{}]", seated.join(", "));
                // Pretend to load assets, then report ready.
                sleep(Duration::from_millis(300)).await;
                gn.ready(session).await?;
                println!("[{game_id}] ready — warm and waiting");
            }
            Some(GameEvent::Start { session }) => {
                println!("[{game_id}] GO! playing a {match_seconds}s match");
                playing = Some((session, Instant::now() + Duration::from_secs(match_seconds)));
            }
            Some(GameEvent::Resume { session }) => {
                if let Some((s, remaining)) = paused_remaining.take() {
                    if s == session {
                        println!("[{game_id}] resumed");
                        playing = Some((session, Instant::now() + remaining));
                    }
                }
            }
            Some(GameEvent::Dispose { .. }) => {
                println!("[{game_id}] session disposed, back to the bench");
                paused_remaining = None;
            }
            Some(GameEvent::SettingChanged { key, value }) => {
                apply_setting(&game_id, &mut match_seconds, &key, &value);
            }
            Some(other) => println!("[{game_id}] ignoring {other:?}"),
            None => break,
        }
    }

    println!("[{game_id}] daemon went away, exiting");
    Ok(())
}

/// The party turned a knob. `match_seconds` steers real behavior (from the
/// next match); the rest is what a real game would wire into its rules.
fn apply_setting(game_id: &str, match_seconds: &mut u64, key: &str, value: &SettingValue) {
    println!("[{game_id}] setting changed: {key} = {value}");
    if key == "match_seconds" {
        if let SettingValue::Number(n) = value {
            *match_seconds = *n as u64;
        }
    }
}
