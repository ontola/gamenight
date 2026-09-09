//! Player avatars: the pixel art someone draws for themselves in the studio.
//!
//! [`Player::avatar`](crate::Player::avatar) travels as an opaque string so
//! the wire format can change without a protocol bump. This module *is* that
//! format, and the decoder every integrator should use rather than
//! reimplementing — a game that wants to show who's playing needs pixels,
//! not a string.
//!
//! ```no_run
//! # use gamenight_protocol::Avatar;
//! # let player_avatar: Option<String> = None;
//! if let Some(art) = player_avatar.as_deref().and_then(Avatar::parse) {
//!     let rgba = art.to_rgba();            // width * height * 4 bytes
//!     // upload as a texture, tint a nameplate, draw over the character…
//! }
//! ```
//!
//! ## Encoding
//!
//! Self-describing JSON, so a decoder can tell what it's holding:
//!
//! ```json
//! { "v": 1, "w": 16, "h": 16, "px": ["#ff0000", null, "#00ff00", ...] }
//! ```
//!
//! `px` is row-major, `null` means transparent. Transparency is explicit
//! because the first version of this format encoded it as the literal colour
//! `#0f172a` — the studio's background — which meant any player who painted
//! with that exact shade punched a hole in their own art, and every consumer
//! had to hardcode a magic colour. The legacy form is still parsed so
//! existing profiles keep working.

use serde::{Deserialize, Serialize};

/// Decoded pixel art. Small by construction — this is a face, not a texture.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Avatar {
    pub width: u32,
    pub height: u32,
    /// Row-major, one entry per pixel. `None` is transparent.
    pub pixels: Vec<Option<[u8; 3]>>,
}

/// The colour the original studio build used for "empty". Retained only to
/// decode avatars saved before transparency was explicit.
const LEGACY_TRANSPARENT: &str = "#0f172a";

/// Guard against a hostile or corrupt payload allocating unbounded memory.
/// Avatars are hand-drawn in a small grid; anything larger is not one.
const MAX_SIDE: u32 = 256;

#[derive(Serialize, Deserialize)]
struct Encoded {
    v: u32,
    w: u32,
    h: u32,
    px: Vec<Option<String>>,
}

impl Avatar {
    /// Decode an avatar payload. Returns `None` for anything malformed —
    /// this is arbitrary text off the wire, so callers get a clean absence
    /// rather than an error to handle or a panic to debug.
    pub fn parse(data: &str) -> Option<Self> {
        let data = data.trim();
        if data.is_empty() {
            return None;
        }
        Self::parse_v1(data).or_else(|| Self::parse_legacy(data))
    }

    fn parse_v1(data: &str) -> Option<Self> {
        let enc: Encoded = serde_json::from_str(data).ok()?;
        if enc.v != 1 {
            return None;
        }
        Self::build(enc.w, enc.h, enc.px.iter().map(|p| p.as_deref()))
    }

    /// The original format: a bare array of colour strings, 16x16 assumed,
    /// with the studio's background colour standing in for transparency.
    fn parse_legacy(data: &str) -> Option<Self> {
        let cells: Vec<String> = serde_json::from_str(data).ok()?;
        let side = (cells.len() as f64).sqrt() as u32;
        if side == 0 || (side * side) as usize != cells.len() {
            return None;
        }
        Self::build(
            side,
            side,
            cells.iter().map(|c| {
                if c.eq_ignore_ascii_case(LEGACY_TRANSPARENT) {
                    None
                } else {
                    Some(c.as_str())
                }
            }),
        )
    }

    fn build<'a>(
        width: u32,
        height: u32,
        cells: impl Iterator<Item = Option<&'a str>>,
    ) -> Option<Self> {
        if width == 0 || height == 0 || width > MAX_SIDE || height > MAX_SIDE {
            return None;
        }
        let pixels: Vec<Option<[u8; 3]>> = cells
            // An unparseable colour is treated as a hole rather than
            // rejecting the whole avatar: one bad cell shouldn't cost a
            // player their drawing.
            .map(|c| c.and_then(parse_hex))
            .collect();
        if pixels.len() != (width * height) as usize {
            return None;
        }
        Some(Self {
            width,
            height,
            pixels,
        })
    }

    /// Encode in the current format.
    pub fn encode(&self) -> String {
        let enc = Encoded {
            v: 1,
            w: self.width,
            h: self.height,
            px: self
                .pixels
                .iter()
                .map(|p| p.map(|[r, g, b]| format!("#{r:02x}{g:02x}{b:02x}")))
                .collect(),
        };
        serde_json::to_string(&enc).unwrap_or_default()
    }

    /// Straight RGBA bytes, `width * height * 4`, ready to hand to a texture
    /// upload in any engine. Transparent pixels are fully zeroed so they
    /// blend correctly rather than fringing dark.
    pub fn to_rgba(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.pixels.len() * 4);
        for px in &self.pixels {
            match px {
                Some([r, g, b]) => out.extend_from_slice(&[*r, *g, *b, 255]),
                None => out.extend_from_slice(&[0, 0, 0, 0]),
            }
        }
        out
    }

    /// The same pixels scaled up by an integer factor, nearest-neighbour.
    ///
    /// Pixel art drawn at 16x16 and stretched by a renderer's default
    /// bilinear filter turns to mush; scaling here keeps the edges hard
    /// without every integrator needing to configure sampler state.
    pub fn to_rgba_scaled(&self, factor: u32) -> (u32, u32, Vec<u8>) {
        let factor = factor.max(1);
        let (w, h) = (self.width * factor, self.height * factor);
        let mut out = vec![0u8; (w * h * 4) as usize];
        for (idx, px) in self.pixels.iter().enumerate() {
            let (sx, sy) = (idx as u32 % self.width, idx as u32 / self.width);
            let [r, g, b, a] = match px {
                Some([r, g, b]) => [*r, *g, *b, 255],
                None => [0, 0, 0, 0],
            };
            for dy in 0..factor {
                for dx in 0..factor {
                    let o = (((sy * factor + dy) * w) + sx * factor + dx) as usize * 4;
                    out[o..o + 4].copy_from_slice(&[r, g, b, a]);
                }
            }
        }
        (w, h, out)
    }

    /// Whether anything was actually drawn. A grid of pure transparency is
    /// technically valid and worth skipping rather than rendering as a hole.
    pub fn is_blank(&self) -> bool {
        self.pixels.iter().all(|p| p.is_none())
    }
}

fn parse_hex(hex: &str) -> Option<[u8; 3]> {
    let hex = hex.trim().trim_start_matches('#');
    if hex.len() != 6 {
        return None;
    }
    Some([
        u8::from_str_radix(&hex[0..2], 16).ok()?,
        u8::from_str_radix(&hex[2..4], 16).ok()?,
        u8::from_str_radix(&hex[4..6], 16).ok()?,
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(colour: &str, n: usize) -> String {
        serde_json::to_string(&vec![colour; n]).unwrap()
    }

    #[test]
    fn round_trips_through_the_current_format() {
        let art = Avatar {
            width: 2,
            height: 2,
            pixels: vec![Some([255, 0, 0]), None, Some([0, 255, 0]), None],
        };
        assert_eq!(Avatar::parse(&art.encode()), Some(art));
    }

    /// Avatars saved before transparency was explicit must keep working —
    /// people have already drawn these.
    #[test]
    fn parses_the_legacy_bare_array() {
        let art = Avatar::parse(&solid("#ff0000", 256)).expect("legacy 16x16");
        assert_eq!((art.width, art.height), (16, 16));
        assert!(art.pixels.iter().all(|p| *p == Some([255, 0, 0])));
    }

    #[test]
    fn legacy_background_colour_becomes_transparent() {
        let art = Avatar::parse(&solid(LEGACY_TRANSPARENT, 256)).unwrap();
        assert!(
            art.is_blank(),
            "the old sentinel colour must decode as holes"
        );
        assert!(art.to_rgba().chunks(4).all(|px| px[3] == 0));
    }

    /// The reason the format changed: under the legacy encoding a player who
    /// picked the background colour deliberately lost those pixels. Explicit
    /// `null` transparency means that shade is now paintable.
    #[test]
    fn current_format_can_paint_the_old_sentinel_colour() {
        let art = Avatar {
            width: 1,
            height: 1,
            pixels: vec![Some([0x0f, 0x17, 0x2a])],
        };
        let decoded = Avatar::parse(&art.encode()).unwrap();
        assert!(!decoded.is_blank(), "that shade must survive a round trip");
    }

    #[test]
    fn rgba_is_four_bytes_per_pixel() {
        let art = Avatar::parse(&solid("#010203", 256)).unwrap();
        let rgba = art.to_rgba();
        assert_eq!(rgba.len(), 16 * 16 * 4);
        assert_eq!(&rgba[0..4], &[1, 2, 3, 255]);
    }

    #[test]
    fn scaling_is_nearest_neighbour_and_sized_correctly() {
        let art = Avatar {
            width: 2,
            height: 1,
            pixels: vec![Some([255, 0, 0]), None],
        };
        let (w, h, rgba) = art.to_rgba_scaled(3);
        assert_eq!((w, h), (6, 3));
        assert_eq!(rgba.len(), (6 * 3 * 4) as usize);
        // Every pixel of the left block is the source colour, exactly.
        for y in 0..3 {
            for x in 0..3 {
                let o = ((y * 6 + x) * 4) as usize;
                assert_eq!(&rgba[o..o + 4], &[255, 0, 0, 255], "at {x},{y}");
            }
        }
        // …and the right block stayed transparent.
        for y in 0..3 {
            let o = ((y * 6 + 3) * 4) as usize;
            assert_eq!(rgba[o + 3], 0);
        }
    }

    #[test]
    fn scale_factor_zero_is_treated_as_one() {
        let art = Avatar::parse(&solid("#ffffff", 4)).unwrap();
        let (w, h, _) = art.to_rgba_scaled(0);
        assert_eq!((w, h), (2, 2));
    }

    /// Arbitrary text arrives here off the wire; none of it may panic.
    #[test]
    fn malformed_payloads_decode_to_none() {
        for bad in [
            "",
            "   ",
            "not json",
            "{}",
            "[]",
            "[1,2,3]",
            r##"{"v":99,"w":1,"h":1,"px":["#fff000"]}"##,
            r##"{"v":1,"w":0,"h":0,"px":[]}"##,
            // Not a square number of cells, so the legacy path can't infer a side.
            &solid("#ffffff", 5),
            // Dimensions disagreeing with the pixel count.
            r##"{"v":1,"w":4,"h":4,"px":["#ffffff"]}"##,
        ] {
            assert_eq!(Avatar::parse(bad), None, "should reject {bad:?}");
        }
    }

    /// A single unreadable colour costs that pixel, not the whole drawing.
    #[test]
    fn a_bad_colour_becomes_a_hole_not_a_failure() {
        let art =
            Avatar::parse(r##"{"v":1,"w":2,"h":1,"px":["#ff0000","nonsense"]}"##).expect("decodes");
        assert_eq!(art.pixels[0], Some([255, 0, 0]));
        assert_eq!(art.pixels[1], None);
    }

    /// An absurd size must be refused before it allocates.
    #[test]
    fn oversized_avatars_are_refused() {
        let huge = r#"{"v":1,"w":100000,"h":100000,"px":[]}"#;
        assert_eq!(Avatar::parse(huge), None);
    }
}
