//! Timestamp render submission, separately from process/window construction.
use bevy::{prelude::*, render::{extract_resource::{ExtractResource, ExtractResourcePlugin},
    view::window::ExtractedWindows, Render, RenderApp, RenderSet, renderer::render_system}};
use std::time::Instant;

#[derive(Resource, Clone)]
struct Startup {
    started: Instant,
    scene_ready: bool,
}
impl ExtractResource for Startup {
    type Source = Self;
    fn extract_resource(source: &Self) -> Self { source.clone() }
}

#[derive(Resource, Default)]
struct Frames {
    acquired: bool,
    first: bool,
    scene: bool,
}

pub fn install(app: &mut App, started: Instant) {
    app.insert_resource(Startup { started, scene_ready: false })
        .add_plugins(ExtractResourcePlugin::<Startup>::default())
        .add_systems(PostUpdate, scene_ready);
    if let Ok(render) = app.get_sub_app_mut(RenderApp) {
        render.init_resource::<Frames>().add_systems(Render, (
            before_present.before(render_system).in_set(RenderSet::Render),
            after_present.after(render_system).in_set(RenderSet::Render),
        ));
    }
}

fn scene_ready(game: Res<bones_bevy_renderer::BonesGame>, mut startup: ResMut<Startup>) {
    if startup.scene_ready { return; }
    let assets = game.0.shared_resource::<bones_framework::prelude::AssetServer>();
    if game.0.sessions.get(crate::SessionNames::GAME).is_some()
        && assets.load_progress.is_finished() && assets.load_progress.errored() == 0 {
        startup.scene_ready = true;
        info!(elapsed_ms = startup.started.elapsed().as_millis() as u64, "lobby_scene_ready");
    }
}

fn before_present(windows: Res<ExtractedWindows>, mut frames: ResMut<Frames>) {
    frames.acquired = windows.values().any(|w| w.swap_chain_texture.is_some());
}

fn after_present(startup: Res<Startup>, mut frames: ResMut<Frames>) {
    if !frames.acquired { return; }
    if !frames.first {
        frames.first = true;
        info!(elapsed_ms = startup.started.elapsed().as_millis() as u64, "first_window_frame_submitted");
    }
    if startup.scene_ready && !frames.scene {
        frames.scene = true;
        info!(elapsed_ms = startup.started.elapsed().as_millis() as u64, "first_lobby_frame_submitted");
    }
}
