use gamenight_local_web::{run_server, ServerState};
use std::sync::{Arc, Mutex};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    tracing_subscriber::fmt().init();
    let daemon_addr =
        std::env::var("GAMENIGHT_ADDR").unwrap_or_else(|_| gamenight_protocol::DEFAULT_ADDR.into());
    let addr = std::env::var("GAMENIGHT_WEB_ADDR")
        .unwrap_or_else(|_| "127.0.0.1:7913".into())
        .parse()?;
    run_server(addr, Arc::new(Mutex::new(ServerState::new(daemon_addr)))).await
}
