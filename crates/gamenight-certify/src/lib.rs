//! The GameNight conformance harness.
//!
//! Embeds a real daemon, drives a scripted night against one game, and grades
//! the observable half of the integration checklist from
//! `docs/integrating-your-game.md`: launch handshake, warm-up, match flow,
//! replay, pause/resume, mid-match skips, and residency across rapid cycles.
//!
//! What a protocol harness cannot see — rendering before `start`, audio,
//! actual input handling — stays on the manual checklist it prints at the end.

use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::Message;

use gamenight_protocol::{
    ClientMessage, GameId, GameMeta, LaunchSpec, PartySnapshot, PlayerId, Role, ServerMessage,
    SessionId, SessionPhase, SettingKind, SettingValue, VoteOption, ENV_ADDR, ENV_GAMENIGHT,
    ENV_GAME_ID,
};

#[derive(Debug, Clone)]
pub struct Config {
    /// The title id under certification.
    pub game: GameId,
    /// How the daemon should launch the game. `None` = wait for the dev to
    /// start the process by hand.
    pub launch: Option<LaunchSpec>,
    /// Port for the embedded daemon. `None` = ephemeral (launch mode);
    /// wait mode wants a fixed, known port.
    pub port: Option<u16>,
    /// How long the game gets to connect (spawn + hello).
    pub connect_timeout: Duration,
    /// How long one full match may take (long for human-played games).
    pub match_timeout: Duration,
    /// Rapid prepare/dispose cycles in the residency check.
    pub cycles: usize,
    /// This game's catalogue entry, if one exists — graded for background
    /// pre-warm eligibility. `None` skips that check (no entry yet, e.g. a
    /// game certifying before its catalogue PR).
    pub catalog_entry: Option<gamenight_catalog::CatalogEntry>,
    /// How many certifiers to seat. Couch multiplayer means two occupied
    /// seats is the realistic case — one seat exercises the vs-bot/empty-seat
    /// fallback path instead of real seat-mapping. Minimum 1.
    pub players: usize,
    /// Hard ceiling on the whole scripted night (steps 1-8 combined), on top
    /// of the individual per-step timeouts above. Defaults short (10s) so a
    /// bare run is a quick smoke test that fails fast on a hang; raise it
    /// (past `match_timeout`) for a real, fully human-played certification.
    /// When it fires, whatever was spawned is still force-killed before
    /// returning — it just means the report grades whatever got done as a
    /// failure past this point.
    pub timeout: Duration,
}

impl Config {
    pub fn new(game: impl Into<String>) -> Self {
        Self {
            game: GameId::new(game),
            launch: None,
            port: None,
            connect_timeout: Duration::from_secs(30),
            match_timeout: Duration::from_secs(300),
            cycles: 5,
            catalog_entry: None,
            players: 2,
            timeout: Duration::from_secs(10),
        }
    }
}

#[derive(Debug)]
pub struct Check {
    pub name: &'static str,
    pub outcome: Outcome,
    pub detail: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Pass,
    Fail,
    Skipped,
}

/// One seated certifier's assigned identity — what the human was told to
/// look for (`name` in the game's UI, `color_label` as a human word) versus
/// what actually went over the wire (`color_hex`, the protocol's
/// [`Player::color`](gamenight_protocol::Player::color) hint).
#[derive(Debug, Clone)]
pub struct Identity {
    pub name: String,
    pub color_hex: String,
    pub color_label: String,
}

/// Short, unmistakable-at-a-glance identities for up to 4 seated certifiers —
/// picked so a human glancing at the screen can immediately tell "is that me
/// showing up as A/RED?" without squinting.
const IDENTITY_PALETTE: &[(&str, &str, &str)] = &[
    ("A", "#e0433a", "RED"),
    ("B", "#3b82c4", "BLUE"),
    ("C", "#3fae56", "GREEN"),
    ("D", "#d9a83b", "YELLOW"),
];

#[derive(Debug, Default)]
pub struct Report {
    pub checks: Vec<Check>,
    /// The identities assigned to seated certifiers this run — empty until
    /// `certify` seats them. Used to phrase the manual checklist concretely.
    pub identities: Vec<Identity>,
}

impl Report {
    /// A game is party-ready if nothing failed outright. `Skipped` isn't a
    /// failure on its own — some checks (e.g. replay-vote) only apply if the
    /// game opts into optional protocol surface like `finished`; a check
    /// only skips *because* of a real failure upstream, which is itself
    /// already recorded as `Fail` and catches this in the check below.
    pub fn passed(&self) -> bool {
        !self.checks.is_empty() && !self.checks.iter().any(|c| c.outcome == Outcome::Fail)
    }

    pub fn summary(&self) -> String {
        let pass = self
            .checks
            .iter()
            .filter(|c| c.outcome == Outcome::Pass)
            .count();
        format!("{pass}/{} passed", self.checks.len())
    }
}

/// The manual items a protocol harness cannot grade. Printed with the report.
pub const MANUAL_CHECKS: &[&str] = &[
    "nothing rendered and no audio before `start`",
    "gameplay (not a menu) within ~1 second of `start`",
    "seats mapped to your input slots by index; empty seats hidden",
    "player names from the snapshot shown in your UI",
    "daemon killed mid-match -> your game exits or returns to its own menu",
];

struct Overlay {
    ws: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    party: Option<PartySnapshot>,
}

impl Overlay {
    async fn connect(addr: &str) -> Result<Self, String> {
        let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .map_err(|e| format!("cannot reach embedded daemon: {e}"))?;
        ws.send(Message::Text(
            ClientMessage::Hello {
                role: Role::Overlay,
                game: None,
                token: None,
            }
            .to_json(),
        ))
        .await
        .map_err(|e| e.to_string())?;
        Ok(Self { ws, party: None })
    }

    async fn send(&mut self, msg: ClientMessage) -> Result<(), String> {
        self.ws
            .send(Message::Text(msg.to_json()))
            .await
            .map_err(|e| e.to_string())
    }

    /// Wait until a snapshot satisfies `pred`, or time out.
    async fn wait_for(
        &mut self,
        timeout: Duration,
        pred: impl Fn(&PartySnapshot) -> bool,
    ) -> Result<PartySnapshot, ()> {
        if let Some(p) = &self.party {
            if pred(p) {
                return Ok(p.clone());
            }
        }
        let deadline = Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(());
            }
            let msg = match tokio::time::timeout(remaining, self.ws.next()).await {
                Ok(Some(Ok(m))) => m,
                Ok(_) => return Err(()),  // closed
                Err(_) => return Err(()), // timeout
            };
            let Message::Text(text) = msg else { continue };
            match serde_json::from_str::<ServerMessage>(&text) {
                Ok(ServerMessage::Welcome { party, .. })
                | Ok(ServerMessage::PartyState { party }) => {
                    let hit = pred(&party);
                    self.party = Some(party);
                    if hit {
                        return Ok(self.party.clone().expect("just set"));
                    }
                }
                _ => {} // errors are informational; other frames irrelevant
            }
        }
    }
}

/// Grades whether this catalogue entry can be silently pre-fetched in the
/// background: free (no login/store wall to click through) and a direct,
/// hash-verified binary for the platform running this check. Judges the
/// *declaration* — no network I/O here, actually fetching is the daemon's
/// job at prewarm time.
pub fn check_auto_downloadable(entry: &gamenight_catalog::CatalogEntry) -> Check {
    let platform = gamenight_catalog::current_platform();
    match entry.auto_download_here() {
        Some(dl) => Check {
            name: "auto-downloadable in the background",
            outcome: Outcome::Pass,
            detail: format!("free, direct {platform} binary ({})", dl.url),
        },
        None if entry.price != gamenight_catalog::Price::Free => Check {
            name: "auto-downloadable in the background",
            outcome: Outcome::Skipped,
            detail: "not free — paid/store games are never silently installed".into(),
        },
        None => Check {
            name: "auto-downloadable in the background",
            outcome: Outcome::Skipped,
            detail: format!("no direct {platform} download declared"),
        },
    }
}

fn push_check(report: &mut Report, check: Check) {
    let icon = match check.outcome {
        Outcome::Pass => "✔",
        Outcome::Fail => "✘",
        Outcome::Skipped => "–",
    };
    println!(
        " {icon} {}{}",
        check.name,
        if check.detail.is_empty() {
            String::new()
        } else {
            format!("  ({})", check.detail)
        }
    );
    report.checks.push(check);
}

fn active_of<'a>(
    p: &'a PartySnapshot,
    game: &GameId,
) -> Option<&'a gamenight_protocol::SessionInfo> {
    p.active_session.as_ref().filter(|s| &s.game == game)
}

/// Run the certification. Prints progress; returns the graded report.
pub async fn certify(config: Config) -> Result<Report, String> {
    let mut report = Report::default();
    let game = config.game.clone();

    // The embedded, completely real daemon.
    let port = config.port.unwrap_or(0);
    let listener = TcpListener::bind(("127.0.0.1", port))
        .await
        .map_err(|e| format!("cannot bind 127.0.0.1:{port}: {e}"))?;
    let addr = listener
        .local_addr()
        .map_err(|e| e.to_string())?
        .to_string();
    // The library never carries a `launch` spec: the daemon's own launcher
    // only ever tears a process down via the party's end-of-night consensus
    // vote (`kill_all_children`, reached through `VoteOption::Quit`), which
    // requires an *open* vote — one only opens after `finished` fires, and
    // manual skip (`next`) explicitly bypasses voting. A one-shot harness has
    // no party to reach consensus with, so this crate spawns and owns the
    // process itself instead — see the direct kill/wait below, which doesn't
    // depend on any of that machinery.
    let library = vec![GameMeta {
        id: game.clone(),
        title: game.0.clone(),
        tagline: None,
        cover: None,
        color: None,
        emoji: None,
        players: None,
        min_players: None,
        max_players: None,
        best_players: None,
        launch: None,
    }];
    let daemon = tokio::spawn(gamenight_daemon::run_with_library(listener, library));

    println!("─────────────────────────────────────────────────────");
    println!(" GameNight conformance · {game}");
    println!(" daemon: ws://{addr}");

    // Spawn and own the game process ourselves (if launch mode). Token-less:
    // the daemon has no pending launch for this id (the library above never
    // declares one), and a token-less hello is accepted whenever nothing is
    // pending — same "dev mode" path wait-mode already relies on.
    let mut child: Option<tokio::process::Child> = None;
    if let Some(spec) = &config.launch {
        let mut cmd = tokio::process::Command::new(&spec.command);
        cmd.args(&spec.args)
            .envs(&spec.env)
            .env(ENV_GAMENIGHT, "1")
            .env(ENV_ADDR, &addr)
            .env(ENV_GAME_ID, &game.0)
            .kill_on_drop(true);
        if let Some(cwd) = &spec.cwd {
            cmd.current_dir(cwd);
        }
        match cmd.spawn() {
            Ok(c) => child = Some(c),
            Err(e) => {
                daemon.abort();
                return Err(format!("failed to launch {}: {e}", spec.command));
            }
        }
    } else {
        println!();
        println!(" waiting for your game — start it with:");
        println!("   GAMENIGHT_ADDR={addr} <your-game>");
        println!(" (or connect it to ws://{addr} and say hello)");
    }
    println!("─────────────────────────────────────────────────────");

    if let Some(entry) = &config.catalog_entry {
        push_check(&mut report, check_auto_downloadable(entry));
    }

    let mut overlay = Overlay::connect(&addr).await?;
    // Seated certifiers: give the game real occupants (seat-mapping, not the
    // vs-bot/empty-seat fallback) and give us votes for the consensus below.
    // Real names + colors (not "Certifier N") so there's something concrete
    // to look for on screen: "did A/RED actually show up as A/RED?"
    let wanted = config.players.max(1);
    let identities: Vec<Identity> = (0..wanted)
        .map(|i| {
            let (name, hex, label) = IDENTITY_PALETTE[i % IDENTITY_PALETTE.len()];
            Identity {
                name: name.into(),
                color_hex: hex.into(),
                color_label: label.into(),
            }
        })
        .collect();
    report.identities = identities.clone();
    for id in &identities {
        overlay
            .send(ClientMessage::JoinParty {
                name: id.name.clone(),
                seat: None,
                color: Some(id.color_hex.clone()),
                avatar: None,
                library: Vec::new(),
            })
            .await?;
    }
    let snap = overlay
        .wait_for(Duration::from_secs(5), |p| p.players.len() >= wanted)
        .await
        .map_err(|_| "daemon never seated the certifier(s)".to_string())?;
    let certifiers: Vec<PlayerId> = snap.players.iter().take(wanted).map(|p| p.id).collect();

    // The whole scripted night (checks 1-8) gets one hard ceiling on top of
    // its per-step timeouts — a backstop for a hang nothing else catches.
    // Force-kill-on-quit below always runs after, timeout or not.
    let scripted_night = async {
        // ── 1. connect ────────────────────────────────────────────────────────
        let t = Instant::now();
        overlay
            .send(ClientMessage::PlayNext { game: game.clone() })
            .await?;
        let connected = overlay
            .wait_for(config.connect_timeout, |p| {
                p.connected_games.contains(&game)
            })
            .await;
        let go_on = record(
            &mut report,
            "process connects and says hello",
            connected
                .map(|_| format!("{} ms", t.elapsed().as_millis()))
                .map_err(|_| "never connected (spawn failed? wrong game id? bad hello?)".into()),
        );

        // ── 2. warm up: prepare -> ready -> auto-start ────────────────────────
        let mut current: Option<SessionId> = None;
        if go_on {
            println!();
            println!(" ⏳ WARMING GAME… nothing should appear on screen and there should be no audio yet!");
            let t = Instant::now();
            let started = overlay
                .wait_for(config.connect_timeout, |p| {
                    active_of(p, &game).is_some_and(|s| s.phase == SessionPhase::Running)
                })
                .await;
            current = started
                .as_ref()
                .ok()
                .and_then(|p| Some(active_of(p, &game)?.id));
            if started.is_ok() {
                let names = identities
                    .iter()
                    .map(|id| id.name.as_str())
                    .collect::<Vec<_>>()
                    .join(", ");
                let colors = identities
                    .iter()
                    .map(|id| id.color_label.as_str())
                    .collect::<Vec<_>>()
                    .join(", ");
                println!();
                println!(" ✅ GAME READY — go play! Note the player names ({names}) and colors ({colors}).");
            }
            record(
                &mut report,
                "prepare -> ready -> instant start",
                started
                    .map(|_| format!("warm in {} ms", t.elapsed().as_millis()))
                    .map_err(|_| "no running session (is `ready` being sent?)".into()),
            );
        } else {
            skip(&mut report, "prepare -> ready -> instant start");
        }

        // ── 3. a match reaches a stopping point ─────────────────────────────
        // `finished` is optional (docs/protocol.md): a game may just keep
        // playing rounds forever and let the party end the session with Skip.
        // Either path is a pass; only an unresponsive game fails this check.
        let mut sent_finished = false;
        if current.is_some() {
            let finished = overlay
                .wait_for(config.match_timeout, |p| {
                    active_of(p, &game).is_some_and(|s| s.phase == SessionPhase::Finished)
                })
                .await;
            match finished {
                Ok(_) => {
                    sent_finished = true;
                    record(
                        &mut report,
                        "match reaches a stopping point",
                        Ok("`finished` sent — vote opened".into()),
                    );
                }
                Err(()) => {
                    // No `finished` — fall back to a manual skip, exactly what
                    // the overlay's Skip button does. Only a genuine failure to
                    // respond to `next` fails this check.
                    let old = current.expect("had a session");
                    overlay.send(ClientMessage::Next).await?;
                    let skipped = overlay
                        .wait_for(config.connect_timeout, |p| {
                            active_of(p, &game)
                                .is_some_and(|s| s.phase == SessionPhase::Running && s.id != old)
                        })
                        .await;
                    current = skipped
                        .as_ref()
                        .ok()
                        .and_then(|p| Some(active_of(p, &game)?.id));
                    record(
                        &mut report,
                        "match reaches a stopping point",
                        skipped
                            .map(|_| {
                                "no `finished` — advanced via manual skip (fine, it's optional)"
                                    .into()
                            })
                            .map_err(|_| {
                                "neither `finished` nor a manual skip produced a fresh session"
                                    .into()
                            }),
                    );
                }
            }
        } else {
            skip(&mut report, "match reaches a stopping point");
        }

        // ── 4. replay is a brand-new session ────────────────────────────────
        // Only meaningful if the game actually sent `finished` — a manual skip
        // doesn't open the party vote, so there's no "replay" to test.
        if sent_finished
            && report
                .checks
                .last()
                .is_some_and(|c| c.outcome == Outcome::Pass)
        {
            // Consensus of the seated: every certifier must stand on `replay`.
            for id in &certifiers {
                overlay
                    .send(ClientMessage::Vote {
                        player_id: *id,
                        option: VoteOption::Replay,
                    })
                    .await?;
            }
            let old = current.expect("had a session");
            let result = overlay
                .wait_for(config.connect_timeout, |p| {
                    active_of(p, &game)
                        .is_some_and(|s| s.phase == SessionPhase::Running && s.id != old)
                })
                .await;
            current = result
                .as_ref()
                .ok()
                .and_then(|p| Some(active_of(p, &game)?.id));
            record(
                &mut report,
                "replay vote -> fresh session, same process",
                result
                    .map(|_| "new session id, re-prepared, re-readied".into())
                    .map_err(|_| "replay never produced a fresh running session".into()),
            );
        } else if !sent_finished {
            skip(
                &mut report,
                "replay vote -> fresh session, same process (no `finished` to replay after)",
            );
        } else {
            skip(&mut report, "replay vote -> fresh session, same process");
        }

        // ── 5. pause / resume ─────────────────────────────────────────────────
        if current.is_some() {
            overlay.send(ClientMessage::Pause).await?;
            let paused = overlay
                .wait_for(Duration::from_secs(5), |p| {
                    active_of(p, &game).is_some_and(|s| s.phase == SessionPhase::Paused)
                })
                .await;
            overlay.send(ClientMessage::Resume).await?;
            let resumed = overlay
                .wait_for(Duration::from_secs(5), |p| {
                    active_of(p, &game).is_some_and(|s| s.phase == SessionPhase::Running)
                })
                .await;
            record(
                &mut report,
                "pause and resume tolerated mid-match",
                paused
                    .and(resumed)
                    .map(|_| "still connected".into())
                    .map_err(|_| "pause or resume did not round-trip".into()),
            );
        } else {
            skip(&mut report, "pause and resume tolerated mid-match");
        }

        // ── 6. match settings (optional surface) ──────────────────────────────
        // If the game declared settings, prove the pipeline end to end: flip one
        // value through the daemon and watch the snapshot agree. Games that
        // declare nothing skip this — it's optional, like `finished`.
        let declared = overlay
            .wait_for(Duration::from_secs(2), |p| {
                p.settings
                    .iter()
                    .any(|s| s.game == game && !s.specs.is_empty())
            })
            .await;
        match declared {
            Ok(snap) => {
                let entry = snap.settings.iter().find(|s| s.game == game).expect("pred");
                let spec = &entry.specs[0];
                // A value that differs from the current one wherever possible.
                let current = entry.values.get(&spec.key);
                let target = match &spec.kind {
                    SettingKind::Toggle { .. } => match current {
                        Some(SettingValue::Toggle(b)) => SettingValue::Toggle(!b),
                        _ => spec.kind.default_value(),
                    },
                    SettingKind::Number { min, max, .. } => {
                        if current == Some(&SettingValue::Number(*min)) {
                            SettingValue::Number(*max)
                        } else {
                            SettingValue::Number(*min)
                        }
                    }
                    SettingKind::Choice { options, .. } => SettingValue::Choice(
                        options
                            .iter()
                            .find(|o| current != Some(&SettingValue::Choice((*o).clone())))
                            .cloned()
                            .unwrap_or_else(|| options[0].clone()),
                    ),
                };
                overlay
                    .send(ClientMessage::SetSetting {
                        game: Some(game.clone()),
                        key: spec.key.clone(),
                        value: target.clone(),
                    })
                    .await?;
                let key = spec.key.clone();
                let n = entry.specs.len();
                let applied = overlay
                    .wait_for(Duration::from_secs(5), |p| {
                        p.settings
                            .iter()
                            .find(|s| s.game == game)
                            .and_then(|s| s.values.get(&key))
                            == Some(&target)
                    })
                    .await;
                record(
                    &mut report,
                    "match settings declared and writable",
                    applied
                        .map(|_| format!("{n} setting(s); '{key}' round-tripped"))
                        .map_err(|_| format!("set_setting on '{key}' never reached the snapshot")),
                );
            }
            Err(()) => skip(
                &mut report,
                "match settings declared and writable (none declared — optional)",
            ),
        }

        // ── 7. skip mid-match + rapid prepare/dispose cycles ──────────────────
        if let Some(mut prev) = current {
            let mut times = Vec::new();
            let mut failed_at = None;
            for i in 0..config.cycles {
                let t = Instant::now();
                overlay.send(ClientMessage::Next).await?;
                match overlay
                    .wait_for(config.connect_timeout, |p| {
                        active_of(p, &game)
                            .is_some_and(|s| s.phase == SessionPhase::Running && s.id != prev)
                    })
                    .await
                {
                    Ok(snap) => {
                        prev = active_of(&snap, &game).expect("pred").id;
                        times.push(t.elapsed().as_millis());
                    }
                    Err(()) => {
                        failed_at = Some(i + 1);
                        break;
                    }
                }
            }
            let result = match failed_at {
                None => {
                    let avg = times.iter().sum::<u128>() / times.len().max(1) as u128;
                    Ok(format!(
                        "{} skips survived, avg {} ms dispose->running",
                        config.cycles, avg
                    ))
                }
                Some(i) => Err(format!("died or stalled on cycle {i}/{}", config.cycles)),
            };
            record(
                &mut report,
                "mid-match skips: dispose, re-prepare, stay resident",
                result,
            );
        } else {
            skip(
                &mut report,
                "mid-match skips: dispose, re-prepare, stay resident",
            );
        }

        // ── 8. still resident at the end ──────────────────────────────────────
        let resident = overlay
            .wait_for(Duration::from_secs(3), |p| {
                p.connected_games.contains(&game)
            })
            .await;
        record(
            &mut report,
            "process resident for the whole night",
            resident
                .map(|_| "connected through every cycle".into())
                .map_err(|_| "process gone before the night ended".into()),
        );

        Ok::<(), String>(())
    };

    let outcome = tokio::time::timeout(config.timeout, scripted_night).await;
    let send_err = match outcome {
        Ok(Ok(())) => None,
        Ok(Err(e)) => Some(e),
        Err(_) => {
            push_check(
                &mut report,
                Check {
                    name: "completes within the overall test timeout",
                    outcome: Outcome::Fail,
                    detail: format!(
                        "no result after {}s — treating as stuck; forcing shutdown",
                        config.timeout.as_secs()
                    ),
                },
            );
            None
        }
    };

    // ── 9. the process does not outlive this run ────────────────────────────
    // Always attempted — success, failure, or timeout above. We own `child`
    // directly (see the spawn above), so this doesn't depend on the daemon,
    // the game's cooperation, or any protocol round-trip: kill it, then
    // block on the OS actually reaping it.
    if let Some(mut child) = child {
        let _ = child.start_kill();
        let reaped = tokio::time::timeout(Duration::from_secs(5), child.wait()).await;
        push_check(
            &mut report,
            Check {
                name: "process does not outlive the certification run",
                outcome: if reaped.is_ok() {
                    Outcome::Pass
                } else {
                    Outcome::Fail
                },
                detail: match reaped {
                    Ok(Ok(status)) => format!("killed, exited with {status}"),
                    Ok(Err(e)) => format!("killed, but couldn't confirm exit: {e}"),
                    Err(_) => "still alive 5s after being killed — leaking a process".into(),
                },
            },
        );
    } else {
        skip(
            &mut report,
            "process does not outlive the certification run (wait mode — yours to close)",
        );
    }

    daemon.abort();
    if let Some(e) = send_err {
        return Err(e);
    }
    Ok(report)
}

fn record(report: &mut Report, name: &'static str, result: Result<String, String>) -> bool {
    let (outcome, detail) = match result {
        Ok(d) => (Outcome::Pass, d),
        Err(e) => (Outcome::Fail, e),
    };
    let pass = outcome == Outcome::Pass;
    println!(
        " {} {name}{}",
        if pass { "✔" } else { "✘" },
        if detail.is_empty() {
            String::new()
        } else {
            format!("  ({detail})")
        }
    );
    report.checks.push(Check {
        name,
        outcome,
        detail,
    });
    pass
}

fn skip(report: &mut Report, name: &'static str) {
    println!(" – {name}  (skipped)");
    report.checks.push(Check {
        name,
        outcome: Outcome::Skipped,
        detail: "skipped".into(),
    });
}

/// Print the closing summary + the manual half of the checklist.
pub fn print_summary(game: &GameId, report: &Report) {
    println!("─────────────────────────────────────────────────────");
    if report.passed() {
        println!(" {} — {game} is party-ready 🎉", report.summary());
    } else {
        println!(" {} — not there yet", report.summary());
    }
    println!();
    println!(" still on you (a protocol harness can't see the screen):");
    for item in MANUAL_CHECKS {
        println!("   □ {item}");
    }
    println!("─────────────────────────────────────────────────────");
}

/// `MANUAL_CHECKS`, phrased against what this specific run actually primed
/// the certifier to look for — the names/colors item names the real
/// identities instead of asking generically.
fn manual_questions(report: &Report) -> Vec<String> {
    let mut questions: Vec<String> = MANUAL_CHECKS.iter().map(|s| s.to_string()).collect();
    if let Some(item) = questions.iter_mut().find(|q| q.starts_with("player names")) {
        let names = report
            .identities
            .iter()
            .map(|id| id.name.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        let colors = report
            .identities
            .iter()
            .map(|id| id.color_label.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        *item = format!("the names ({names}) and colors ({colors}) you were shown actually appeared in the game");
    }
    questions
}

/// How long one manual question waits for an answer before giving up on the
/// whole checklist. A `.is_terminal()` stdin isn't proof someone's there to
/// type — a pty with nobody attached reports the same — so this is the real
/// backstop against hanging forever: [`run_manual_checklist`] must always
/// return and let the process exit, on an unattended run or an attended one
/// where the certifier wandered off.
const MANUAL_ANSWER_TIMEOUT: Duration = Duration::from_secs(120);

/// Walk the manual checklist as interactive y/n questions instead of leaving
/// them as a printed reminder — you just watched the match (primed at
/// warm-up and ready time with what to look for), so answer for it now.
/// A no-op that returns `true` when stdin isn't a terminal (CI, piped runs):
/// there's nobody to ask, and the printed checklist from [`print_summary`]
/// remains the record for those runs. If nobody answers a question within
/// [`MANUAL_ANSWER_TIMEOUT`], stops asking and counts the checklist as
/// unconfirmed rather than waiting on the rest too.
pub async fn run_manual_checklist(report: &Report) -> bool {
    use std::io::{IsTerminal, Write};

    if !std::io::stdin().is_terminal() {
        return true;
    }

    println!();
    println!(
        " now grade what you just watched (no answer in {}s stops here):",
        MANUAL_ANSWER_TIMEOUT.as_secs()
    );
    let mut all_confirmed = true;
    for item in manual_questions(report) {
        print!("   {item}? [y/N] ");
        std::io::stdout().flush().ok();
        let answer = tokio::time::timeout(
            MANUAL_ANSWER_TIMEOUT,
            tokio::task::spawn_blocking(|| {
                let mut line = String::new();
                std::io::stdin().read_line(&mut line).map(|_| line)
            }),
        )
        .await;
        let Ok(Ok(Ok(line))) = answer else {
            println!();
            println!("   (no answer — stopping the checklist here)");
            all_confirmed = false;
            break;
        };
        if !matches!(line.trim().to_lowercase().as_str(), "y" | "yes") {
            all_confirmed = false;
        }
    }
    println!("─────────────────────────────────────────────────────");
    if all_confirmed {
        println!(" ✔ manual checklist confirmed");
    } else {
        println!(" ✘ manual checklist incomplete — not party-ready yet");
    }
    println!("─────────────────────────────────────────────────────");
    all_confirmed
}

#[cfg(test)]
mod tests {
    use super::*;
    use gamenight_catalog::{CatalogEntry, Download};

    fn minimal(price: gamenight_catalog::Price) -> CatalogEntry {
        serde_json::from_value::<CatalogEntry>(serde_json::json!({
            "id": "x", "title": "X",
            "players": { "min": 1, "max": 4 },
            "price": "free",
            "integration": { "level": "planned" }
        }))
        .map(|mut e| {
            e.price = price;
            e
        })
        .unwrap()
    }

    #[test]
    fn free_with_a_direct_binary_here_passes() {
        let mut entry = minimal(gamenight_catalog::Price::Free);
        entry.downloads.insert(
            gamenight_catalog::current_platform().into(),
            Download {
                runtime: None,
                url: "https://example.com/x.tar.gz".into(),
                sha256: "a".repeat(64),
                size_mb: None,
                entrypoint: Some("x/game".into()),
            },
        );
        let check = check_auto_downloadable(&entry);
        assert_eq!(check.outcome, Outcome::Pass);
    }

    #[test]
    fn paid_games_never_pass_even_with_a_download_declared() {
        let entry = minimal(gamenight_catalog::Price::Paid);
        let check = check_auto_downloadable(&entry);
        assert_eq!(check.outcome, Outcome::Skipped);
        assert!(check.detail.contains("not free"));
    }

    #[test]
    fn free_without_a_binary_for_this_platform_skips() {
        let entry = minimal(gamenight_catalog::Price::Free);
        let check = check_auto_downloadable(&entry);
        assert_eq!(check.outcome, Outcome::Skipped);
        assert!(check.detail.contains("no direct"));
    }
}
