//! Native window identity, independent of lobby assets and loading progress.
use bevy::prelude::*;

pub fn apply(
    mut windows: Query<(Entity, &mut Window), With<bevy::window::PrimaryWindow>>,
    native: NonSend<bevy::winit::WinitWindows>,
    mut branded: Local<Option<Entity>>,
) {
    let Ok((entity, mut window)) = windows.get_single_mut() else { return };
    if window.title != "GameNight" {
        window.title = "GameNight".into();
    }
    if *branded == Some(entity) { return; }
    let Some(native_window) = native.get_window(entity) else { return };
    let icon = winit::window::Icon::from_rgba(
        include_bytes!("../branding/icon-64.rgba").to_vec(), 64, 64,
    ).expect("embedded GameNight icon is 64x64 RGBA");
    native_window.set_window_icon(Some(icon));
    *branded = Some(entity);
}
