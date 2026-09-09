//! `gamenight-mcp` — MCP-over-stdio server for the GameNight daemon.
//!
//! Register it with any MCP client (stdout is protocol, logs go to stderr):
//!
//!     claude mcp add gamenight -- gamenight-mcp
//!
//! Connects to `GAMENIGHT_ADDR` (default `127.0.0.1:7912`).

#[tokio::main(flavor = "current_thread")]
async fn main() -> std::process::ExitCode {
    let addr = gamenight_mcp::daemon_addr();
    let client = match gamenight_mcp::DaemonClient::connect(&addr).await {
        Ok(client) => client,
        Err(e) => {
            eprintln!("gamenight-mcp: {e}");
            eprintln!("gamenight-mcp: is the daemon running? start it with: cargo run -p gamenight-daemon");
            return std::process::ExitCode::FAILURE;
        }
    };
    eprintln!("gamenight-mcp: connected to the daemon at {addr}, serving MCP on stdio");
    let stdin = tokio::io::BufReader::new(tokio::io::stdin());
    match gamenight_mcp::serve(client, stdin, tokio::io::stdout()).await {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("gamenight-mcp: stdio transport failed: {e}");
            std::process::ExitCode::FAILURE
        }
    }
}
