//! A deliberately hand-pixelled fist; animation moves one consistent drawing.
use bevy::prelude::*;
use crate::core::player::punch::{Punch, DURATION};
#[derive(Component)]
pub(super) struct Fist;

pub(super) fn sync(mut commands: Commands, game: Res<bones_bevy_renderer::BonesGame>,
    mut images: ResMut<Assets<Image>>, mut texture: Local<Option<Handle<Image>>>,
    existing: Query<Entity, With<Fist>>) {
    for entity in &existing { commands.entity(entity).despawn_recursive(); }
    let Some(session) = game.0.sessions.get(crate::SessionNames::GAME) else {return;};
    if texture.is_none() {
        use bevy::render::render_resource::{Extent3d, TextureDimension, TextureFormat};
        let rows = ["....######..", "...#WWWWWW#.", "..#WWWWWWWW#", "###WW#W#W#W#",
                    "#WWWWWWWWWW#", "#WWWWWWSSSS#", "####WSSSSS#.", "....######.."];
        let data = rows.iter().flat_map(|row| row.bytes()).flat_map(|p| match p {
            b'#'=>[20,24,30,255], b'W'=>[255,255,255,255], b'S'=>[180,180,180,255], _=>[0,0,0,0]
        }).collect();
        let mut image = Image::new(Extent3d {width:12,height:8,depth_or_array_layers:1}, TextureDimension::D2, data, TextureFormat::Rgba8UnormSrgb);
        image.sampler_descriptor = bevy::render::texture::ImageSampler::nearest();
        *texture = Some(images.add(image));
    }
    let world=&session.world;
    let entities=world.resource::<bones_framework::prelude::Entities>();
    let punches=world.components.get::<Punch>().borrow();
    let positions=world.components.get::<bones_framework::prelude::Transform>().borrow();
    let indices=world.components.get::<crate::core::player::PlayerIdx>().borrow();
    let bridge=game.0.shared_resource::<super::GameNightBridge>();
    for (_, (punch,position,index)) in entities.iter_with((&punches,&positions,&indices)) {
        if punch.remaining <= 0. {continue;}
        let age=DURATION-punch.remaining;
        // Wind up, snap forward at impact, then retract. Both facing directions
        // share these exact pixels; no regenerated whole-body animation drift.
        let reach=if age<0.06 {12.-age*80.} else if age<0.12 {34.} else {34.*punch.remaining/0.12};
        let id=bridge.latest_seats.iter().find(|s|s.index as u32==index.0).and_then(|s|s.occupant.player_id());
        let colour=id.and_then(|id|bridge.latest_players.iter().find(|p|p.id==id))
            .and_then(|p|p.skin_color.as_deref()).and_then(|s|Color::hex(s).ok()).unwrap_or(Color::rgb_u8(245,233,190));
        commands.spawn((Fist,SpriteBundle {
            texture:texture.as_ref().unwrap().clone(),
            sprite:Sprite {color:colour,flip_x:punch.direction<0.,custom_size:Some(Vec2::new(24.,16.)),..default()},
            transform:Transform::from_xyz((position.translation.x+punch.direction*reach).round(),(position.translation.y+1.).round(),-90.),
            ..default()
        }));
    }
}
