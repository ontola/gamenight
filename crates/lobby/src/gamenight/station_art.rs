//! Small pixel-aligned furniture landmarks; no collision or input lives here.
use bevy::prelude::*;

fn rect(parent: &mut ChildBuilder, x: f32, y: f32, w: f32, h: f32, z: f32, rgb: [u8; 3]) {
    parent.spawn(SpriteBundle {
        sprite: Sprite { color: Color::rgb_u8(rgb[0], rgb[1], rgb[2]), custom_size: Some(Vec2::new(w, h)), ..default() },
        transform: Transform::from_xyz(x, y, z), ..default()
    });
}

pub(super) fn front_door(parent: &mut ChildBuilder, floor: f32) {
    let mut r = |x,y,w,h,z,c| rect(parent,x,floor+y,w,h,z,c);
    r(3.,48.,65.,96.,0.,[25,27,30]);
    r(0.,48.,62.,96.,1.,[82,51,36]);
    r(0.,48.,52.,88.,2.,[177,120,65]);
    r(0.,47.,44.,82.,3.,[92,56,37]);
    r(0.,48.,38.,76.,4.,[133,83,47]);
    r(0.,72.,30.,21.,5.,[47,69,73]);
    r(0.,73.,24.,15.,6.,[140,192,190]);
    r(0.,73.,2.,17.,7.,[72,49,35]);
    r(0.,73.,26.,2.,7.,[72,49,35]);
    r(0.,29.,28.,27.,5.,[94,55,34]);
    r(0.,30.,22.,21.,6.,[152,97,53]);
    r(14.,46.,4.,4.,7.,[244,198,98]);
    r(0.,3.,66.,6.,8.,[195,149,87]);
    r(0.,97.,68.,6.,8.,[195,149,87]);
}
