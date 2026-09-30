//! Protocol-only skeleton, compiled by the documentation CI.
use gamenight_sdk::{GameEvent, GameNight, SdkError};

#[tokio::main]
async fn main() -> Result<(), SdkError> {
    if !GameNight::launched_by_daemon() {
        println!("Standalone mode: open your game's menu here.");
        return Ok(());
    }
    let mut host = GameNight::connect_from_env().await?;
    while let Some(event) = host.next_event().await? {
        match event {
            GameEvent::Prepare {
                session,
                seats,
                players,
            } => {
                // Replace this with hidden loading, roster setup and first-frame work.
                println!(
                    "Prepare {} seats and {} profiles",
                    seats.len(),
                    players.len()
                );
                host.participation(session, false).await?;
                host.ready(session).await?;
            }
            GameEvent::Start { .. } | GameEvent::Resume { .. } => {
                // Show the prepared window; enable simulation and audio.
            }
            GameEvent::Pause { .. } => {
                // Freeze simulation and audio, then hide the window.
            }
            GameEvent::ControllerFrame { controllers } => {
                // Store receipt time. Match controllers by token, never list order.
                println!("{} controller states", controllers.len());
            }
            GameEvent::PartyUpdated { seats, players, .. } => {
                // Apply the roster and changed profiles without restarting the round.
                println!(
                    "Update {} seats and {} profiles",
                    seats.len(),
                    players.len()
                );
            }
            GameEvent::Dispose { .. } => {
                // Release session resources. Keep listening for another Prepare.
            }
            _ => {}
        }
    }
    // Host disconnected: leave no window or background game running.
    Ok(())
}
