//! Physical, controller-owned acceptance of cloud profiles waiting at the room door.
use super::{avatar_image, lobby_sign_in_pad, seat_world_position, GameNightBridge};
use crate::player_links::PlayerLinks;
use bevy::prelude::*;
use gamenight_protocol::PlayerId;
use std::collections::HashMap;
#[derive(Default, Resource)]
pub(super) struct Doors {
    slots: HashMap<String, usize>,
    holds: HashMap<String, (PlayerId, f32, f64)>,
}
#[derive(Component)]
pub(super) struct Door(String, String);
#[derive(Component)]
pub(super) struct Progress(String);
#[derive(Component)]
pub(super) struct RoomLabel(String);

pub(super) fn sync(
    mut commands: Commands,
    game: Res<bones_bevy_renderer::BonesGame>,
    links: Res<PlayerLinks>,
    assets: Res<AssetServer>,
    mut images: ResMut<Assets<Image>>,
    time: Res<Time>,
    mut state: ResMut<Doors>,
    existing: Query<(Entity, &Door)>,
    labels: Query<(Entity, &RoomLabel)>,
    mut bars: Query<(&Progress, &mut Sprite)>,
    windows: Query<&Window>,
) {
    let snapshot = links.snapshot();
    let room = snapshot.as_ref().and_then(|s| s.room.as_ref());
    let active = lobby_sign_in_pad(&game.0).is_some();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let pending: Vec<_> = room
        .into_iter()
        .flat_map(|r| r.pending.iter())
        .filter(|p| active && p.expires > now)
        .collect();
    state
        .slots
        .retain(|id, _| pending.iter().any(|p| &p.id == id));
    state
        .holds
        .retain(|id, _| pending.iter().any(|p| &p.id == id));
    let font: Handle<Font> = assets.load("ui/FairfaxSM.ttf");
    let code = room
        .filter(|_| active)
        .map(|r| r.room_code.as_str())
        .unwrap_or("");
    for (entity, label) in &labels {
        if label.0 != code || code.is_empty() {
            commands.entity(entity).despawn_recursive();
        }
    }
    if !code.is_empty() && !labels.iter().any(|(_, label)| label.0 == code) {
        commands.spawn((
            RoomLabel(code.into()),
            Text2dBundle {
                text: Text::from_section(
                    format!("ROOM  {code}"),
                    TextStyle {
                        font: font.clone(),
                        font_size: 20.,
                        color: Color::WHITE,
                    },
                ),
                transform: Transform::from_xyz(600., 235., -100.),
                ..default()
            },
        ));
    }
    for (entity, door) in &existing {
        if !pending.iter().any(|p| {
            p.id == door.0
                && format!(
                    "{}{}{}",
                    p.profile.display_name, p.profile.skin_color, p.profile.avatar
                ) == door.1
        }) {
            commands.entity(entity).despawn_recursive();
        }
    }
    let seats = game
        .0
        .shared_resource::<GameNightBridge>()
        .latest_seats
        .clone();
    let focused = windows.iter().any(|w| w.focused);
    for p in pending {
        if !state.slots.contains_key(&p.id) {
            let Some(slot) = (0..8).find(|s| !state.slots.values().any(|v| v == s)) else {
                continue;
            };
            state.slots.insert(p.id.clone(), slot);
        }
        let x = 220. + state.slots[&p.id] as f32 * 96.;
        let mark = format!(
            "{}{}{}",
            p.profile.display_name, p.profile.skin_color, p.profile.avatar
        );
        if !existing.iter().any(|(_, d)| d.0 == p.id && d.1 == mark) {
            let face = avatar_image(&p.profile.avatar).map(|i| images.add(i));
            commands
                .spawn((
                    Door(p.id.clone(), mark),
                    SpatialBundle {
                        transform: Transform::from_xyz(x, 138., -910.),
                        ..default()
                    },
                ))
                .with_children(|parent| {
                    parent.spawn(SpriteBundle {
                        sprite: Sprite {
                            color: Color::rgb_u8(99, 66, 46),
                            custom_size: Some(Vec2::new(88., 100.)),
                            ..default()
                        },
                        ..default()
                    });
                    parent.spawn(SpriteBundle {
                        sprite: Sprite {
                            color: Color::rgb_u8(19, 23, 37),
                            custom_size: Some(Vec2::new(76., 88.)),
                            ..default()
                        },
                        transform: Transform::from_xyz(0., 0., 1.),
                        ..default()
                    });
                    for (path, color, z) in [
                        (
                            "player/skins/fishy/fishy-body.png",
                            Color::rgb_u8(140, 155, 230),
                            2.,
                        ),
                        (
                            "player/skin-mask.png",
                            Color::hex(&p.profile.skin_color).unwrap_or(Color::WHITE),
                            3.,
                        ),
                    ] {
                        parent.spawn(SpriteBundle {
                            texture: assets.load(path),
                            sprite: Sprite {
                                color,
                                rect: Some(Rect::new(0., 0., 96., 80.)),
                                custom_size: Some(Vec2::new(96., 80.)),
                                ..default()
                            },
                            transform: Transform::from_xyz(0., 0., z),
                            ..default()
                        });
                    }
                    if let Some(texture) = face {
                        parent.spawn(SpriteBundle {
                            texture,
                            sprite: Sprite {
                                custom_size: Some(Vec2::splat(48.)),
                                ..default()
                            },
                            transform: Transform::from_xyz(0., 12., 4.),
                            ..default()
                        });
                    }
                    parent.spawn(Text2dBundle {
                        text: Text::from_section(
                            p.profile.display_name.chars().take(20).collect::<String>(),
                            TextStyle {
                                font: font.clone(),
                                font_size: 12.,
                                color: Color::WHITE,
                            },
                        ),
                        transform: Transform::from_xyz(0., 58., 5.),
                        ..default()
                    });
                    parent.spawn((
                        Progress(p.id.clone()),
                        SpriteBundle {
                            sprite: Sprite {
                                color: Color::rgb_u8(180, 155, 255),
                                custom_size: Some(Vec2::new(0., 4.)),
                                ..default()
                            },
                            transform: Transform::from_xyz(0., -48., 5.),
                            ..default()
                        },
                    ));
                });
        }
        let candidate = if focused {
            seats
                .iter()
                .filter_map(|seat| {
                    let id = seat.occupant.player_id()?;
                    if snapshot.as_ref()?.linked.contains(&id) {
                        return None;
                    }
                    let pos = seat_world_position(&game.0, seat.index)?;
                    ((pos.x - x).abs() < 30. && (pos.y - 118.).abs() < 30.).then_some(id)
                })
                .next()
        } else {
            None
        };
        if let Some(player) = candidate {
            let hold = state.holds.entry(p.id.clone()).or_insert((player, 0., 0.));
            if hold.0 != player {
                *hold = (player, 0., 0.);
            }
            if time.elapsed_seconds_f64() >= hold.2 {
                hold.1 += time.delta_seconds().min(0.1);
                if hold.1 >= 2. {
                    links.pickup(p.id.clone(), player);
                    hold.2 = time.elapsed_seconds_f64() + 5.;
                }
            }
        } else {
            state.holds.remove(&p.id);
        }
    }
    for (id, mut sprite) in &mut bars {
        sprite.custom_size = Some(Vec2::new(
            76. * state
                .holds
                .get(&id.0)
                .map(|h| (h.1 / 2.).min(1.))
                .unwrap_or(0.),
            4.,
        ));
    }
}
