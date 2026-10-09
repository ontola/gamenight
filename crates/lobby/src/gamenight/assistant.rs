//! Optional assistant entry. Hosted AI and account credentials stay outside the lobby.
use bevy::prelude::*;
use bevy::hierarchy::BuildChildren;
use bones_bevy_renderer::BonesGame;
use std::collections::{HashMap, HashSet};

pub(super) fn url() -> Option<String> {
    std::env::var("GAMENIGHT_ASSISTANT_URL").ok()
        .filter(|s| (s.starts_with("http://127.0.0.1:") || s.starts_with("https://")) && !s.contains(['\n','\r']) && s.len() < 2048)
}

pub(super) fn open() {
    let Some(url) = url() else { return; };
    open_url(url);
}

pub(super) fn open_lobby_chooser() {
    let url = std::env::var("GAMENIGHT_LOBBY_CHOOSER_URL").ok()
        .filter(|s| s.starts_with("http://127.0.0.1:") && !s.contains(['\n','\r']))
        .unwrap_or_else(|| "http://127.0.0.1:7913/host/lobby".into());
    // Packaged hosts run lobbies in a kill-on-close job, where a browser
    // started from here never shows up. The launcher opens it instead.
    if let Some(request) = std::env::var_os("GAMENIGHT_BROWSER_REQUEST") {
        if std::fs::write(request, &url).is_ok() { return; }
    }
    open_url(url);
}

fn open_url(url: String) {
    // An argument, never shell code. This is a deliberate user-triggered window.
    #[cfg(target_os = "windows")]
    let result = std::process::Command::new("explorer.exe").arg(url).spawn();
    #[cfg(target_os = "macos")]
    let result = std::process::Command::new("open").arg(url).spawn();
    #[cfg(target_os = "linux")]
    let result = std::process::Command::new("xdg-open").arg(url).spawn();
    if result.is_err() { bevy::log::warn!("Could not open GameNight page"); }
}

#[derive(Component)]
pub(super) struct Computer;

#[derive(Default)]
pub(super) struct Interaction {
    released: HashSet<u32>,
    held: HashMap<u32, f32>,
}

pub(super) fn sync(mut commands: Commands, game: Res<BonesGame>, assets: Res<AssetServer>,
    input: Res<super::GlobalInput>, buttons: Res<Input<GamepadButton>>, time: Res<Time>,
    mut interaction: Local<Interaction>, mut computers: Query<&mut Transform, With<Computer>>) {
    if url().is_none() {return;}
    let Some((screen,size,foot,_)) = super::lobby_tv(&game.0) else {return;};
    let position = Vec3::new(screen.x-size.x/2.-42., foot.y+20., super::LOBBY_PROP_Z);
    if let Ok(mut transform) = computers.get_single_mut() {
        transform.translation = position;
    } else if computers.is_empty() {
        commands.spawn((Computer, SpatialBundle {transform:Transform::from_translation(position),..default()})).with_children(|p| {
            for (x,y,w,h,color) in [
                (0.,0.,38.,30.,Color::rgb_u8(169,130,82)),
                (0.,2.,30.,20.,Color::rgb_u8(19,32,34)),
                (0.,-18.,28.,5.,Color::rgb_u8(119,86,62)),
                (-14.,-22.,4.,7.,Color::rgb_u8(91,66,49)),
                (14.,-22.,4.,7.,Color::rgb_u8(91,66,49)),
            ] {
                p.spawn(SpriteBundle {sprite:Sprite{color,custom_size:Some(Vec2::new(w,h)),..default()},transform:Transform::from_xyz(x,y,0.),..default()});
            }
            p.spawn(Text2dBundle {text:Text::from_section(":)",TextStyle{font:assets.load("ui/ark-pixel-16px-latin.ttf"),font_size:15.,color:Color::rgb_u8(182,231,137)}),transform:Transform::from_xyz(0.,3.,1.),..default()});
        });
    }
    let mut bridge = game.0.shared_resource_mut::<super::GameNightBridge>();
    if bridge.lobby_away {interaction.held.clear(); interaction.released.clear();return;}
    let seats = bridge.latest_seats.clone();
    for seat in seats {
        let Some(player) = seat.occupant.player_id() else {continue;};
        let Some((&pad,_))=input.pad_player.iter().find(|(_,id)| **id==player) else {continue;};
        let down = buttons.pressed(GamepadButton::new(Gamepad::new(pad as usize),GamepadButtonType::North));
        if !down {interaction.released.insert(pad); interaction.held.remove(&pad);}
        let near = super::seat_world_position(&game.0,seat.index).is_some_and(|p| (p.x-position.x).abs()<27. && (p.y-position.y).abs()<45.);
        if !near || input.open_menus.contains_key(&player) {interaction.held.remove(&pad);continue;}
        bridge.interaction_hints.insert(seat.index as u32,("Hold: assistant".into(),Vec2::new(position.x,foot.y)));
        if down && interaction.released.contains(&pad) {
            let elapsed=interaction.held.entry(pad).or_default(); *elapsed+=time.delta_seconds();
            if *elapsed>=0.7 {interaction.released.remove(&pad);interaction.held.remove(&pad);open();}
        }
    }
}
