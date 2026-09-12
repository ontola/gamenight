//! Isolated, empty-library host for manual cloud relay acceptance. No controllers or games.
use std::sync::{Arc, Mutex};
#[tokio::main]
async fn main() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:17912")
        .await
        .unwrap();
    tokio::spawn(gamenight_daemon::run_with_library(listener, Vec::new()));
    let state = Arc::new(Mutex::new(gamenight_local_web::ServerState::new(
        "127.0.0.1:17912".into(),
    )));
    gamenight_local_web::run_server("127.0.0.1:17913".parse().unwrap(), state)
        .await
        .unwrap();
}
