//! Procedural guest artwork in the shared 48px head space.
//! Keep the head at (24, 28), with features looking right; saved profiles are untouched.
type Color = [u8; 3];
const INK: Color = [26, 26, 26];
const WHITE: Color = [255, 255, 255];

/// Generate the same 48px face and headwear used by the bundled lobby.
/// Persist this payload on the player; do not generate a new face each frame.
pub fn avatar(seed: &[u8; 16]) -> crate::Avatar {
    crate::Avatar {
        width: 48,
        height: 48,
        pixels: pixels(seed),
    }
}

pub const COLORS: [&str; 8] = [
    "#4daf7c", "#e36c76", "#648cdd", "#d7ad43", "#a67bdd", "#49b8bc", "#d88950", "#cf7aaf",
];
pub const SKINS: [&str; 6] = [
    "#f5e9be", "#efc39a", "#d99b72", "#bf855b", "#905c40", "#654332",
];

pub fn pixels(seed: &[u8; 16]) -> Vec<Option<Color>> {
    let mut pixels = vec![None; 48 * 48];
    let hair = [
        [48, 35, 29],
        [107, 57, 38],
        [192, 120, 50],
        [239, 208, 120],
        [220, 227, 239],
    ][seed[0] as usize % 5];
    let hat = [
        [214, 76, 100],
        [67, 123, 209],
        [117, 82, 184],
        [54, 166, 154],
    ][seed[1] as usize % 4];
    let shade = |color: Color| color.map(|v| (v as f32 * 0.72).round() as u8);
    let mut rect = |x: usize, y: usize, w: usize, h: usize, color: Color| {
        for row in y..(y + h).min(48) {
            for col in x..(x + w).min(48) {
                pixels[row * 48 + col] = Some(color);
            }
        }
    };
    // Every band is centred on the head and rests above the brows at y=23.
    // The cap alone has a deliberate three-pixel visor to the right.
    match seed[2] % 4 {
        0 => {
            rect(18, 12, 12, 2, hair);
            rect(14, 14, 20, 4, hair);
            rect(12, 18, 24, 4, hair);
            rect(12, 21, 4, 10, hair);
            rect(16, 21, 6, 2, hair);
            rect(19, 14, 1, 5, shade(hair));
        }
        1 => {
            rect(22, 7, 4, 13, hair);
            rect(20, 17, 8, 5, hair);
            rect(25, 9, 1, 8, shade(hair));
        }
        2 => {
            rect(18, 12, 12, 2, hat);
            rect(14, 14, 20, 4, hat);
            rect(12, 18, 24, 4, hat);
            rect(26, 15, 3, 3, WHITE);
            rect(12, 20, 27, 2, hat);
            rect(12, 22, 27, 1, shade(hat));
        }
        _ => {
            rect(18, 12, 12, 2, hat);
            rect(14, 14, 20, 4, hat);
            rect(12, 18, 24, 4, hat);
            rect(22, 8, 4, 4, WHITE);
            rect(11, 20, 26, 3, shade(hat));
            rect(12, 20, 24, 1, WHITE);
        }
    }
    for x in [22, 30] {
        if seed[3].is_multiple_of(3) {
            rect(x, 27, 4, 2, INK);
        } else {
            rect(x, 25, 5, 5, WHITE);
            rect(x + 2, 26, 2, 3, INK);
        }
    }
    rect(24, 33, 8, 2, INK);
    if seed[4].is_multiple_of(2) {
        rect(26, 35, 4, 1, INK);
    }
    pixels
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn every_guest_expression_stays_on_the_head() {
        for style in 0..4 {
            for eye in 0..3 {
                for mouth in 0..2 {
                    let mut seed = [0; 16];
                    seed[2] = style;
                    seed[3] = eye;
                    seed[4] = mouth;
                    let face = pixels(&seed);
                    assert_eq!(face.len(), 48 * 48);
                    for y in 24..48 {
                        for x in 17..48 {
                            if face[y * 48 + x].is_some() {
                                let dx = x as f32 + 0.5 - 24.;
                                let dy = y as f32 + 0.5 - 28.;
                                assert!(
                                    dx * dx + dy * dy <= 144.,
                                    "style {style}: facial pixel {x},{y} falls off the head"
                                );
                            }
                        }
                    }
                    assert!(face[26 * 48 + 24].is_some() || face[27 * 48 + 24].is_some());
                    assert!(face[33 * 48 + 28].is_some());
                }
            }
        }
    }
    #[test]
    fn headwear_reaches_the_forehead_and_preserves_clear_face_space() {
        for style in 0..4 {
            let mut seed = [0; 16];
            seed[2] = style;
            let face = pixels(&seed);
            assert!(face[21 * 48 + 24].is_some());
            for x in 17..32 {
                assert_eq!(face[23 * 48 + x], None);
            }
        }
    }
}
