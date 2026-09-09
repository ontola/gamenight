//! The conformance harness certifying our own demo game — both a self-test of
//! the harness and a guarantee that the reference integration stays exemplary.

use std::time::Duration;

use gamenight_certify::{certify, Config, Outcome};
use gamenight_protocol::LaunchSpec;

#[tokio::test]
async fn demo_game_is_party_ready() {
    let mut config = Config::new("certme");
    config.launch = Some(LaunchSpec {
        command: env!("CARGO_BIN_EXE_demo-game").to_string(),
        args: vec!["3".into()], // 3s matches: long enough to pause mid-match
        cwd: None,
        env: Default::default(),
    });
    config.match_timeout = Duration::from_secs(30);
    config.cycles = 3;

    let report = certify(config).await.expect("harness ran");
    for check in &report.checks {
        assert_eq!(
            check.outcome,
            Outcome::Pass,
            "check '{}' failed: {}",
            check.name,
            check.detail
        );
    }
    assert!(report.passed());
}
