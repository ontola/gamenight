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

/// Twenty-by-twelve pixel pads, resting on the same floor as the TV cabinet.
/// Body tint follows the seated player's clothing; controls keep their contrast.
pub(super) fn controllers(parent: &mut ChildBuilder, colors: &[String], x: f32, floor: f32) {
    const PIXELS: [&str; 12] = [
        "    OOOOOOOOOOOO    ",
        "  OOHHHHHHHHHHHHOO  ",
        " OHHBBBBBBBBBBBBHHO ",
        " OHBBBDBBBBBBYBBHBO ",
        " OHBBDDDBBBBGBRBBBO ",
        " OBBBBDBBBBBBABBBBO ",
        "OBBBBBBBWWBBBBBBBBBO",
        "OBBBSSBBBBBBBBSSBBBO",
        "OBBSSSBOOOOBBBSSSBBO",
        "OBSSSBO    OBSSSSBO ",
        " OSSSO      OSSSSO  ",
        "  OOO        OOOO   ",
    ];
    for (index, hex) in colors.iter().enumerate() {
        let rgba = Color::hex(hex).unwrap_or(Color::rgb_u8(124, 92, 255)).as_rgba_f32();
        let body = [rgba[0], rgba[1], rgba[2]].map(|v| (v * 255.0).round() as u8);
        let highlight = body.map(|v| (v as u16 + (255 - v as u16) / 3) as u8);
        let shade = body.map(|v| (v as f32 * 0.6) as u8);
        let center = x + (index as f32 - (colors.len() - 1) as f32 / 2.0) * 24.0;
        rect(parent, center, floor + 0.5, 22.0, 1.0, 0.2, [30, 25, 30]);
        for (row, pixels) in PIXELS.iter().enumerate() {
            // Merge adjacent pixels of the same color into one sprite.
            let bytes = pixels.as_bytes();
            let mut column = 0;
            while column < bytes.len() {
                let start = column;
                let key = bytes[column];
                while column < bytes.len() && bytes[column] == key { column += 1; }
                let rgb = match key {
                    b'O' => [25, 27, 38], b'B' => body, b'H' => highlight, b'S' => shade,
                    b'D' => [32, 35, 48], b'W' => [225, 225, 235],
                    b'Y' => [251, 208, 63], b'G' => [88, 183, 105],
                    b'R' => [233, 91, 103], b'A' => [93, 154, 226], _ => continue,
                };
                rect(parent, center - 10.0 + (start + column) as f32 / 2.0,
                    floor + 11.5 - row as f32, (column - start) as f32, 1.0, 0.3, rgb);
            }
        }
    }
}
