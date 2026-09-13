use bevy::prelude::*;
use bevy::hierarchy::{BuildChildren,DespawnRecursiveExt};
use bones_bevy_renderer::BonesGame;
// Capture before the Bones simulation; render after it, never relying on
// unrelated Update systems happening to execute in a particular order.
pub(super) fn capture(game: Res<BonesGame>, input: Res<super::GlobalInput>,
    buttons: Res<Input<GamepadButton>>, windows: Query<&Window>) {
    let mut bridge = game.0.shared_resource_mut::<super::GameNightBridge>();
    bridge.interact_pressed.clear();
    if bridge.lobby_away || !windows.iter().any(|w| w.focused) { return; }
    for (&pad, &player) in &input.pad_player {
        if input.open_menus.contains_key(&player) { continue; }
        if buttons.just_pressed(GamepadButton::new(Gamepad::new(pad as usize), GamepadButtonType::North)) {
            if let Some(seat) = bridge.latest_seats.iter().find(|s| s.occupant.player_id() == Some(player)).map(|s| s.index) {
                bridge.interact_pressed.insert(seat as u32);
            }
        }
    }
}
#[derive(Component)]
pub(super) struct InteractionHint(u32, String);
#[derive(Component)]
pub(super) struct ButtonPixel { seat: u32, y: f32, letter: bool }
pub(super) fn sync(mut commands:Commands, game:Res<BonesGame>, assets:Res<AssetServer>, mut old:Query<(Entity,&InteractionHint,&mut Transform), Without<ButtonPixel>>, mut pixels:Query<(&ButtonPixel,&mut Transform,&mut Sprite), Without<InteractionHint>>, input:Res<super::GlobalInput>, buttons:Res<Input<GamepadButton>>) {
    let bridge=game.0.shared_resource::<super::GameNightBridge>();
    for (pixel, mut transform, mut sprite) in &mut pixels {
        let pressed=bridge.seat_player(pixel.seat).is_some_and(|player|input.pad_player.iter().any(|(&pad,&id)|id==player && buttons.pressed(GamepadButton::new(Gamepad::new(pad as usize),GamepadButtonType::North))));
        transform.translation.y=pixel.y-if pressed && pixel.letter {1.0}else{0.0};
        if !pixel.letter { sprite.color=if pressed && pixel.y >= 5. {Color::rgb_u8(157,119,25)}else{Color::rgb_u8(248,205,52)}; }
    }
    for (entity, hint, _) in &mut old {
        if bridge.lobby_away || !bridge.interaction_hints.get(&hint.0).is_some_and(|(label,_)| label == &hint.1) {
            commands.entity(entity).despawn_recursive();
        }
    }
    if bridge.lobby_away {return;}
    let font:Handle<Font>=assets.load("ui/ark-pixel-16px-latin.ttf");
    // Give each complete card its own depth band. Children occupy 0..=2,
    // so the next card's background must be in front of that entire range.
    // Sort by the displayed position; seat breaks ties deterministically.
    let mut hints: Vec<_> = bridge.interaction_hints.iter().filter_map(|(&seat, (label, position))| {
        super::seat_world_position(&game.0, seat as u8)
            .map(|player_position| (seat, label, position, player_position))
    }).collect();
    hints.sort_by(|a, b| a.3.x.total_cmp(&b.3.x).then(a.0.cmp(&b.0)));
    for (order, (seat, label, position, player_position)) in hints.into_iter().enumerate() {
        let Some(player)=bridge.seat_player(seat) else {continue;};
        if input.open_menus.contains_key(&player) {continue;}
        let pressed=input.pad_player.iter().any(|(&pad,&id)| id==player && buttons.pressed(GamepadButton::new(Gamepad::new(pad as usize),GamepadButtonType::North)));

        let width=(label.chars().count() as f32*6.5+34.).max(66.);
        let badge_x=-width/2.+12.;
        let translation=Vec3::new(player_position.x.round(),position.y.round()-13.,-70. + order as f32 * 4.);
        if let Some((_,_,mut transform))=old.iter_mut().find(|(_,hint,_)|hint.0==seat && hint.1==*label) {
            transform.translation=translation;
            continue;
        }
        commands.spawn((InteractionHint(seat,label.clone()),SpatialBundle {transform:Transform::from_translation(translation),..default()})).with_children(|p|{
            // Pixel-rounded capsule: radius matches the ten-pixel outer badge.
            for y in -9_i32..=9 {
                let cap=(100-y*y) as f32;
                let row_width=width-20.+2.*cap.sqrt().floor();
                p.spawn(SpriteBundle {sprite:Sprite {color:Color::rgb_u8(18,23,34),custom_size:Some(Vec2::new(row_width,1.)),..default()},transform:Transform::from_xyz(0.,y as f32,0.),..default()});
            }
            for y in -8_i32..=8 {
                let width=((64-y*y) as f32).sqrt().floor()*2.+1.;
                p.spawn((ButtonPixel {seat,y:y as f32,letter:false}, SpriteBundle {sprite:Sprite {color:if pressed && y>=5 {Color::rgb_u8(157,119,25)}else{Color::rgb_u8(248,205,52)},custom_size:Some(Vec2::new(width,1.)),..default()},transform:Transform::from_xyz(badge_x,y as f32,1.),..default()}));
            }
            for (y,row) in ["1100011","1100011","0110110","0011100","0001100","0001100","0001100"].iter().enumerate() {
                for (x,bit) in row.bytes().enumerate() {
                    if bit==49 {
                        p.spawn((ButtonPixel {seat,y:3.-y as f32,letter:true}, SpriteBundle {sprite:Sprite {color:Color::BLACK,custom_size:Some(Vec2::ONE),..default()},
                            transform:Transform::from_xyz(badge_x+x as f32-3.,3.-y as f32-if pressed {1.}else{0.},2.),..default()}));
                    }
                }
            }
            p.spawn(Text2dBundle {text:Text::from_section(label,TextStyle {font:font.clone(),font_size:11.,color:Color::WHITE}),text_anchor:bevy::sprite::Anchor::CenterLeft,transform:Transform::from_xyz(badge_x+12.,0.,2.),..default()});
        });
    }
}
