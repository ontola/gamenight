//! The GameNight conformance harness runs the real demo binary against a real
//! host: hello, prepare, ready, start, rounds, replay, pause, settings, skips.
//! It needs a display (CI uses xvfb with Mesa's software Vulkan).

use std::time::Duration;

use gamenight_certify::{certify, Config, Outcome};
use gamenight_protocol::LaunchSpec;

#[tokio::test]
async fn star_catch_is_party_ready() {
    if cfg!(target_os = "linux")
        && std::env::var_os("DISPLAY").is_none()
        && std::env::var_os("WAYLAND_DISPLAY").is_none()
    {
        eprintln!("skipped: no display (run under xvfb-run)");
        return;
    }
    let mut config = Config::new("bevy-demo");
    config.launch = Some(LaunchSpec {
        command: env!("CARGO_BIN_EXE_bevy-demo").to_string(),
        // Five-second rounds: long enough to pause mid-match.
        args: vec!["--round".into(), "5".into()],
        cwd: None,
        env: Default::default(),
    });
    config.players = 2;
    config.cycles = 3;
    config.match_timeout = Duration::from_secs(40);
    config.timeout = Duration::from_secs(240);

    let report = certify(config).await.expect("harness ran");
    for check in &report.checks {
        assert_ne!(
            check.outcome,
            Outcome::Fail,
            "check '{}' failed: {}",
            check.name,
            check.detail
        );
    }
    assert!(report.passed());
}
