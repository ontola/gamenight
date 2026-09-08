//! Self-capture, for iterating on how the lobby looks.
//!
//! The lobby photographs its own framebuffer and quits. That is the whole
//! feature, and the reason for it is that the obvious alternative — a
//! screenshot tool pointed at the display — captures whatever happens to be in
//! front, which during this project twice turned out to be somebody's editor
//! rather than the game. This cannot do that: it can only ever see the game's
//! own window.
//!
//! Off unless `LOBBY_SHOT` names a file, so a normal run behaves normally.
//!
//!     LOBBY_SHOT=/tmp/lobby.png cargo run --profile dev-optimized
//!
//! `LOBBY_SHOT_AFTER` sets how many seconds to wait first (default 6). It needs
//! to be long enough for assets to finish loading and for the camera to settle,
//! or you photograph a half-built room.

use bevy::prelude::*;
use bevy::render::view::screenshot::ScreenshotManager;
use bevy::window::PrimaryWindow;

const DEFAULT_DELAY: f32 = 6.0;
/// Grace between asking for the shot and quitting, so the file is actually on
/// disk. The capture is asynchronous — it happens at the end of the render
/// pipeline, not when the call returns.
const WRITE_GRACE: f32 = 1.5;

#[derive(Resource)]
struct Shot {
    path: String,
    at: f32,
    taken: Option<f32>,
}

pub fn install(app: &mut App) {
    let Ok(path) = std::env::var("LOBBY_SHOT") else {
        return;
    };
    let at = std::env::var("LOBBY_SHOT_AFTER")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_DELAY);
    info!(%path, at, "lobby: will photograph itself and quit");
    app.insert_resource(Shot {
        path,
        at,
        taken: None,
    });
    app.add_systems(Update, capture);
}

fn capture(
    time: Res<Time>,
    mut shot: ResMut<Shot>,
    mut screenshots: ResMut<ScreenshotManager>,
    window: Query<Entity, With<PrimaryWindow>>,
    mut exit: EventWriter<bevy::app::AppExit>,
) {
    let now = time.elapsed_seconds();

    if let Some(taken) = shot.taken {
        if now - taken > WRITE_GRACE {
            exit.send(bevy::app::AppExit);
        }
        return;
    }

    if now < shot.at {
        return;
    }
    let Ok(window) = window.get_single() else {
        return;
    };
    match screenshots.save_screenshot_to_disk(window, &shot.path) {
        Ok(()) => info!(path = %shot.path, "lobby: screenshot requested"),
        Err(e) => error!("lobby: screenshot failed: {e}"),
    }
    shot.taken = Some(now);
}
