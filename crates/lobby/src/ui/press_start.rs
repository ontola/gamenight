//! The attract screen: an overlay asking someone — anyone — to join.
//!
//! Not a menu. It has no options and nothing to navigate; it is a sign held up
//! over the running lobby, and it disappears the instant a person is in the
//! party. The room keeps playing underneath the whole time, which is the point:
//! a GameNight never sits on a title card waiting for input.
//!
//! It tells the truth about what to do next. With no pad plugged in that is
//! "connect a controller"; with one connected but nobody joined it is "press A",
//! because telling someone to connect a controller they are already holding is
//! the kind of small lie that makes a room feel broken.
//!
//! Every line is *painted* at an absolute position rather than laid out in a
//! `Ui`. Laying it out meant the blinking headline had to reserve its own space
//! while dark, and reserved space never quite equals a rendered label's height —
//! so the line beneath it twitched once a second, which is exactly the sort of
//! thing that makes a screen feel cheap.

use crate::{gamenight::GameNightBridge, prelude::*};

pub fn session_plugin(session: &mut SessionBuilder) {
    session
        .install_plugin(DefaultSessionPlugin)
        .add_system_to_stage(Update, press_start_system);
}

/// How long a full blink takes, in seconds. Slow enough to read, quick enough
/// to catch the eye from across a room.
const BLINK_PERIOD: f64 = 1.6;
/// Seconds for the headline to travel once around its colour cycle.
const HUE_PERIOD: f64 = 6.0;
/// Seconds for the sign to swing once on its chains. Slow — a sign this size
/// hanging in a still room barely moves, and anything quicker reads as a wobble
/// rather than as weight.
const SWAY_PERIOD: f64 = 9.0;

/// The theme font at a screen-scaled size.
///
/// Built the same way `FontMeta::id()` does — cloning the family `Arc<str>`
/// rather than round-tripping it through a `String`. egui looks the family up
/// by name, and a rebuilt `Arc` that is not the registered one silently renders
/// nothing at all: no glyphs, no panic, no warning.
fn font_id(meta: &FontMeta, scale: f32) -> egui::FontId {
    egui::FontId::new(meta.size * scale, egui::FontFamily::Name(meta.family.clone()))
}

/// Draw centred text with a chunky outline behind it.
///
/// egui has no text stroke, so the outline is the same string drawn eight times
/// around the centre. Eight rather than four: at four, the diagonals of a pixel
/// font stay bare and the letters look chewed.
fn outlined(
    painter: &egui::Painter,
    pos: egui::Pos2,
    text: &str,
    font: egui::FontId,
    fill: egui::Color32,
    outline: egui::Color32,
    width: f32,
) {
    for (dx, dy) in [
        (-1.0, -1.0),
        (0.0, -1.0),
        (1.0, -1.0),
        (-1.0, 0.0),
        (1.0, 0.0),
        (-1.0, 1.0),
        (0.0, 1.0),
        (1.0, 1.0),
    ] {
        painter.text(
            egui::pos2(pos.x + dx * width, pos.y + dy * width),
            egui::Align2::CENTER_CENTER,
            text,
            font.clone(),
            outline,
        );
    }
    painter.text(pos, egui::Align2::CENTER_CENTER, text, font, fill);
}

/// Measure a line so the plate behind it can be sized to fit.
fn measure(ctx: &egui::Context, text: &str, font: egui::FontId) -> egui::Vec2 {
    ctx.fonts(|f| f.layout_no_wrap(text.to_owned(), font, egui::Color32::WHITE))
        .size()
}

/// Blend two colours, for the prompt's dim half-beat.
fn mix(a: egui::Color32, b: egui::Color32, t: f32) -> egui::Color32 {
    let f = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t) as u8;
    egui::Color32::from_rgb(f(a.r(), b.r()), f(a.g(), b.g()), f(a.b(), b.b()))
}

fn press_start_system(meta: Root<GameMeta>, ctx: Res<EguiCtx>, game: Res<GameNightBridge>) {
    // Clean, real-frame captures for remote layout reviews without a controller.
    if std::env::var_os("LOBBY_SHOT").is_some()
        && std::env::var("LOBBY_SHOT_CLEAN").as_deref() == Ok("1") { return; }

    // Somebody is here — nothing to ask for.
    if !game.latest_players.is_empty() {
        return;
    }

    let screen = ctx.screen_rect();

    // Sized against the screen, not in fixed points. The theme's font sizes are
    // tuned for a small window; at 1440p they came out as a caption on a
    // wall-sized picture. 480 is the nominal design height — the camera's own
    // `default_height` is 448.
    let scale = (screen.height() / 480.0).clamp(1.0, 6.0);

    let time = ctx.input(|i| i.time);
    let headline = if game.pads_connected == 0 {
        "CONNECT A CONTROLLER"
    } else {
        "PRESS A TO JOIN"
    };

    let painter = ctx.layer_painter(egui::LayerId::new(
        egui::Order::Foreground,
        egui::Id::new("press_start"),
    ));

    // A scrim, not a curtain: the room stays visible and animated behind it.
    painter.rect_filled(screen, 0.0, egui::Color32::from_black_alpha(120));

    // Vignette. Nested rings of low-alpha black, heaviest at the edge — it
    // pulls the eye to the middle without hiding the room, which a single
    // heavier scrim would.
    let rings = 14;
    for i in 0..rings {
        let t = i as f32 / rings as f32;
        let inset = screen.width() * 0.5 * t * 0.9;
        painter.rect_stroke(
            screen.shrink(inset),
            0.0,
            egui::Stroke::new(
                screen.width() * 0.5 / rings as f32 * 0.95,
                egui::Color32::from_black_alpha(16),
            ),
        );
    }

    let styles = &meta.theme.font_styles;

    // Everything on this overlay is built from whole `px` blocks and hard edges.
    //
    // An earlier pass decorated the sign with round bulbs and a little drawn
    // gamepad, and they looked pasted on from another program — because they
    // were. egui antialiases circles and diagonals, so they arrived with smooth
    // grey edges into a room where every edge is a hard pixel boundary. Nothing
    // here draws a circle or a diagonal, and every coordinate lands on the grid.
    let px = scale.round().max(1.0);
    let snap = |v: f32| (v / px).round() * px;

    // The sign swings, so everything on it swings together — in whole pixels,
    // or the lettering shimmers as it slides between them.
    let sway = snap(((time / SWAY_PERIOD * std::f64::consts::TAU).sin() * 2.5) as f32 * scale);
    let cx = snap(screen.center().x) + sway;

    let title_font = font_id(&styles.heading, scale);
    let sub_font = font_id(&styles.normal, scale);
    let prompt_font = font_id(&styles.bigger, scale * 1.25);
    let hint_font = font_id(&styles.smaller, scale);

    let title_sz = measure(&ctx, "GAMENIGHT", title_font.clone());
    let sub_sz = measure(&ctx, "the couch is warm", sub_font.clone());
    let prompt_sz = measure(&ctx, headline, prompt_font.clone());
    let hint_sz = measure(&ctx, "then press Start to link your phone", hint_font.clone());

    // The plate. Text over patterned wallpaper and fairy lights was unreadable
    // wherever it happened to land; a marquee gives it its own ground and makes
    // the screen look designed rather than overlaid.
    let pad = 22.0 * scale;
    let gap_title = 6.0 * scale;
    let gap_prompt = 18.0 * scale;
    let gap_hint = 12.0 * scale;
    let inner_h = title_sz.y + gap_title + sub_sz.y + gap_prompt + prompt_sz.y
        + gap_hint + hint_sz.y;
    let inner_w = title_sz.x.max(sub_sz.x).max(prompt_sz.x).max(hint_sz.x);
    let half_w = snap((inner_w + pad * 2.0) * 0.5);
    let half_h = snap((inner_h + pad * 2.0) * 0.5);
    let mid_y = snap(screen.top() + screen.height() * 0.29);
    let plate = egui::Rect::from_min_max(
        egui::pos2(cx - half_w, mid_y - half_h),
        egui::pos2(cx + half_w, mid_y + half_h),
    );

    // Chains up to the ceiling. The plate was floating in mid-air, which is the
    // last thing that made it read as drawn over the room rather than hung in
    // it — and a hanging sign matches the fairy lights already strung across
    // the same wall.
    //
    // Drawn as a stack of separate square links rather than a stroked line: a
    // line at any angle other than vertical arrives antialiased, which on this
    // wall looks like a smudge rather than a chain.
    let link = px * 2.0;
    for side in [-1.0f32, 1.0] {
        let anchor_x = plate.center().x + side * snap(plate.width() * 0.36);
        // The ceiling end does not sway — it is screwed to the ceiling. Letting
        // it drift with the sign gave two parallel chains sliding sideways,
        // which looks like the whole room is moving.
        let ceiling_x = snap(screen.center().x) + side * snap(plate.width() * 0.36 + 14.0 * scale);
        let mut y = screen.top();
        while y < plate.top() {
            let t = (y - screen.top()) / (plate.top() - screen.top()).max(1.0);
            let x = snap(ceiling_x + (anchor_x - ceiling_x) * t);
            painter.rect_filled(
                egui::Rect::from_min_size(egui::pos2(x, snap(y)), egui::vec2(link, link)),
                0.0,
                egui::Color32::from_rgb(92, 58, 42),
            );
            y += link * 2.0;
        }
    }

    // Hard drop shadow, offset down and right. It does the job the soft breathing
    // glow used to do — lifting the sign off the wall — without a gradient, which
    // is the one thing a pixel-art room cannot have on its edges.
    painter.rect_filled(
        plate.translate(egui::vec2(px * 3.0, px * 3.0)),
        0.0,
        egui::Color32::from_black_alpha(130),
    );
    painter.rect_filled(plate, 0.0, egui::Color32::from_rgba_unmultiplied(28, 14, 18, 238));
    // A banded light fall, lightest at the top, as though the wall lamps above
    // were catching the sign. Few enough bands that each one is a visible step —
    // a smooth 24-step ramp was trying to be a gradient, and this room does not
    // have gradients in it.
    let bands = 5;
    for i in 0..bands {
        let t = i as f32 / bands as f32;
        let band = egui::Rect::from_min_max(
            egui::pos2(plate.left(), snap(plate.top() + plate.height() * t)),
            egui::pos2(
                plate.right(),
                snap(plate.top() + plate.height() * (t + 1.0 / bands as f32)),
            ),
        );
        painter.rect_filled(
            band.intersect(plate),
            0.0,
            egui::Color32::from_rgba_unmultiplied(120, 70, 48, ((1.0 - t) * 22.0) as u8),
        );
    }
    // Two square borders, both whole pixels wide.
    painter.rect_stroke(
        plate.shrink(px * 0.5),
        0.0,
        egui::Stroke::new(px, egui::Color32::from_rgb(150, 92, 56)),
    );
    painter.rect_stroke(
        plate.shrink(px * 3.5),
        0.0,
        egui::Stroke::new(px, egui::Color32::from_rgb(86, 48, 36)),
    );

    // Scanlines, drifting slowly downward — the cheapest possible nod to a CRT,
    // and the one that survives being scaled up. Drawn last so they fall across
    // the plate too, tying it into the picture.
    let line = (2.0 * scale).round().max(2.0);
    let gap = line * 2.0;
    let mut y = screen.top() + ((time * 12.0) % gap as f64) as f32;
    while y < screen.bottom() {
        painter.rect_filled(
            egui::Rect::from_min_max(
                egui::pos2(screen.left(), y),
                egui::pos2(screen.right(), y + line),
            ),
            0.0,
            egui::Color32::from_black_alpha(30),
        );
        y += gap;
    }

    // Every line is painted from the plate's top edge, so the blinking prompt
    // can never shift the ones around it.
    let mut y = snap(plate.top() + pad + title_sz.y * 0.5);
    // Outlined, like the prompt. Plain white text on the plate read as the
    // renderer's default font sitting on top of a picture rather than as
    // lettering painted onto a sign.
    outlined(
        &painter,
        egui::pos2(cx, y),
        "GAMENIGHT",
        title_font,
        egui::Color32::from_rgb(252, 246, 232),
        egui::Color32::from_rgb(46, 20, 24),
        (2.0 * scale).round().max(2.0),
    );
    y += title_sz.y * 0.5 + gap_title + sub_sz.y * 0.5;
    painter.text(
        egui::pos2(cx, y),
        egui::Align2::CENTER_CENTER,
        "the couch is warm",
        sub_font,
        egui::Color32::from_rgb(196, 150, 92),
    );

    // The prompt blinks; the title does not. A blinking title reads as a fault,
    // a blinking prompt reads as an invitation.
    //
    // It dims rather than vanishing. Removing it outright left the sign with a
    // hole in the middle for a third of every blink — the plate is sized to fit
    // the prompt, so the space stayed reserved whether or not anything was in
    // it, and a big empty band under the title looked like a failed load. Going
    // dark and coming back is the same signal without the hole.
    let lit = (time % BLINK_PERIOD) / BLINK_PERIOD < 0.62;
    y += sub_sz.y * 0.5 + gap_prompt + prompt_sz.y * 0.5;
    {
        // Cycles through arcade-marquee warmth — gold to tangerine to hot pink
        // and back. Slower than the blink so the two never beat against each
        // other.
        let t = (time % HUE_PERIOD) / HUE_PERIOD;
        let wave = |o: f64| (((t + o) * std::f64::consts::TAU).sin() * 0.5 + 0.5) as f32;
        let bright = egui::Color32::from_rgb(
            255,
            (150.0 + 90.0 * wave(0.0)) as u8,
            (90.0 + 130.0 * wave(0.33)) as u8,
        );
        let fill = if lit {
            bright
        } else {
            mix(egui::Color32::from_rgb(58, 26, 34), bright, 0.34)
        };
        outlined(
            &painter,
            egui::pos2(cx, y),
            headline,
            prompt_font,
            fill,
            egui::Color32::from_rgb(38, 12, 30),
            (3.0 * scale).round().max(3.0),
        );
    }

    y += prompt_sz.y * 0.5 + gap_hint + hint_sz.y * 0.5;
    painter.text(
        egui::pos2(cx, y),
        egui::Align2::CENTER_CENTER,
        "then press Start to link your phone",
        hint_font,
        egui::Color32::from_rgb(186, 156, 132),
    );
}
