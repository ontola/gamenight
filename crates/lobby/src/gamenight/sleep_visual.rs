//! Sleep presentation is applied after simulation and restored before its next tick.
use bevy::prelude::*;
use bones_framework::prelude as bones;
use crate::core::player::{PlayerIdx, PlayerLayers};

#[derive(Resource, Default)]
pub(super) struct PoseBackup(Vec<(bones::Entity, bones::Transform)>);
#[derive(Component)]
pub(super) struct SleepEffect;

pub(super) fn restore(game: Res<bones_bevy_renderer::BonesGame>, mut saved: ResMut<PoseBackup>) {
    if let Some(session) = game.0.sessions.get(crate::SessionNames::GAME) {
        let mut transforms = session.world.components.get::<bones::Transform>().borrow_mut();
        for (entity, original) in saved.0.drain(..) {
            if let Some(t) = transforms.get_mut(entity) { *t = original; }
        }
    } else { saved.0.clear(); }
}

pub(super) fn pose(mut commands: Commands, game: Res<bones_bevy_renderer::BonesGame>,
    mut saved: ResMut<PoseBackup>, time: Res<Time>, assets: Res<AssetServer>,
    effects: Query<Entity, With<SleepEffect>>) {
    for entity in &effects { commands.entity(entity).despawn_recursive(); }
    let Some(session) = game.0.sessions.get(crate::SessionNames::GAME) else { return; };
    let world = &session.world;
    let entities = world.resource::<bones::Entities>();
    let indices = world.components.get::<PlayerIdx>().borrow();
    let layers = world.components.get::<PlayerLayers>().borrow();
    let animations = world.components.get::<bones::AnimationBankSprite>().borrow();
    let sprites = world.components.get::<bones::AtlasSprite>().borrow();
    let mut transforms = world.components.get::<bones::Transform>().borrow_mut();
    let bridge = game.0.shared_resource::<super::GameNightBridge>();
    for (entity, (index, layer, animation)) in entities.iter_with((&indices, &layers, &animations)) {
        if animation.current.as_str() != "sleep" { continue; }
        let Some(body) = transforms.get(entity).copied() else { continue; };
        let facing = if sprites.get(entity).is_some_and(|s|s.flip_x) {-1.0} else {1.0};
        let turn = Quat::from_rotation_z(-facing * std::f32::consts::FRAC_PI_2);
        let anchor = body.translation + Vec3::new(0., -12., 0.);
        for part in [Some(entity), Some(layer.fin_ent), Some(layer.face_ent), layer.hat_ent].into_iter().flatten() {
            if let Some(t) = transforms.get_mut(part) {
                saved.0.push((part, *t));
                let offset = turn * (t.translation - body.translation);
                t.translation = anchor + offset;
                t.rotation = turn * t.rotation;
            }
        }
        let id = bridge.latest_seats.iter().find(|s|s.index as u32==index.0).and_then(|s|s.occupant.player_id());
        let skin = id.and_then(|id|bridge.latest_players.iter().find(|p|p.id==id))
            .and_then(|p|p.skin_color.as_deref()).and_then(|c|Color::hex(c).ok())
            .unwrap_or(Color::rgb_u8(245,233,190));
        // Two overlapping pixel hands hide custom open eyes without changing saved artwork.
        let head = anchor + turn * Vec3::new(0., 14., 0.);
        commands.spawn((SleepEffect, SpatialBundle {transform: Transform::from_xyz(head.x, head.y, -85.), ..default()}))
            .with_children(|parent| {
                for (x,y,w,h,c,z) in [(0.,0.,23.,17.,Color::rgb_u8(34,29,35),0.),
                    (-4.,1.,12.,13.,skin,0.1),(5.,-1.,12.,13.,skin,0.2),
                    (0.,1.,1.,9.,Color::rgba(0.2,0.15,0.15,0.45),0.3)] {
                    parent.spawn(SpriteBundle {sprite:Sprite {color:c, custom_size:Some(Vec2::new(w,h)),..default()},
                        transform:Transform::from_xyz(x,y,z),..default()});
                }
            });
        for i in 0..3 {
            let phase = (time.elapsed_seconds()*0.45 + i as f32/3.).fract();
            let alpha = (phase*5.).min(1.) * ((1.-phase)*3.).min(1.);
            commands.spawn((SleepEffect,Text2dBundle {
                text:Text::from_section("Z",TextStyle {font:assets.load("ui/FairfaxSM.ttf"),font_size:9.+phase*5.,color:Color::rgba(0.85,0.9,1.,alpha)}),
                transform:Transform::from_xyz(head.x+facing*(10.+phase*14.),head.y+12.+phase*26.,-80.),..default()
            }));
        }
    }
}

