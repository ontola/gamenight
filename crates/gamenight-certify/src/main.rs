//! CLI for the GameNight conformance harness.
//!
//!     # daemon-launch mode (recommended): everything after `--` is your game
//!     gamenight-certify my-game -- /path/to/my-game --windowed
//!
//!     # wait mode: start your game by hand against the printed address
//!     gamenight-certify my-game --port 7912
//!
//! Flags: --cycles N (default 5) · --match-timeout SECS (default 300)
//!        --port N (wait mode listen port, default 7912)
//!        --players N (default 2 — seated certifiers, real seat-mapping
//!        instead of the vs-bot/empty-seat fallback)
//!        --timeout SECS (default 10 — hard ceiling on the whole scripted
//!        night; whatever was launched is force-killed when it fires). The
//!        short default makes a bare invocation a quick smoke test — raise
//!        it (well past --match-timeout) for a real, fully human-played run.
//!
//! When stdin is a terminal, the automated run is followed by the manual
//! checklist as interactive y/n questions (grading what you just watched);
//! piped/CI runs skip straight to the printed checklist and grade only the
//! automated report. Either way, the launched game process does not outlive
//! this one — certify spawns and owns it directly, and kills it before
//! exiting no matter how the run ends.

use std::time::Duration;

use gamenight_certify::{certify, print_summary, run_manual_checklist, Config};
use gamenight_protocol::LaunchSpec;

fn usage() -> ! {
    eprintln!(
        "usage: gamenight-certify <game-id> [--cycles N] [--match-timeout SECS] \
         [--players N] [--timeout SECS] [--port N] [-- <command> [args…]]"
    );
    std::process::exit(2);
}

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1).peekable();
    let Some(game_id) = args.next().filter(|a| !a.starts_with('-')) else {
        usage()
    };
    let mut config = Config::new(&game_id);
    config.catalog_entry = gamenight_catalog::load_dir(&gamenight_catalog::workspace_catalog_dir())
        .ok()
        .and_then(|entries| entries.into_iter().find(|e| e.id == game_id));

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--cycles" => match args.next().and_then(|v| v.parse().ok()) {
                Some(n) => config.cycles = n,
                None => usage(),
            },
            "--match-timeout" => match args.next().and_then(|v| v.parse().ok()) {
                Some(secs) => config.match_timeout = Duration::from_secs(secs),
                None => usage(),
            },
            "--port" => match args.next().and_then(|v| v.parse().ok()) {
                Some(p) => config.port = Some(p),
                None => usage(),
            },
            "--players" => match args.next().and_then(|v| v.parse().ok()) {
                Some(n) => config.players = n,
                None => usage(),
            },
            "--timeout" => match args.next().and_then(|v| v.parse().ok()) {
                Some(secs) => config.timeout = Duration::from_secs(secs),
                None => usage(),
            },
            "--" => {
                let Some(command) = args.next() else { usage() };
                config.launch = Some(LaunchSpec {
                    command,
                    args: args.collect(),
                    cwd: None,
                    env: Default::default(),
                });
                break;
            }
            _ => usage(),
        }
    }
    // Wait mode wants a known port so the dev's game can find us.
    if config.launch.is_none() && config.port.is_none() {
        config.port = Some(7912);
    }

    match certify(config).await {
        Ok(report) => {
            print_summary(&gamenight_protocol::GameId::new(game_id), &report);
            let manual_ok = run_manual_checklist(&report).await;
            std::process::exit(if report.passed() && manual_ok { 0 } else { 1 });
        }
        Err(e) => {
            eprintln!("certification could not run: {e}");
            std::process::exit(2);
        }
    }
}
