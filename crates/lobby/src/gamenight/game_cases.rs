//! Physical playlist cases. The host still owns selection and game launching.
use super::GameNightBridge;
use bevy::prelude::*;
use gamenight_protocol::{GameId, GameMeta, PlaylistEntry};

#[derive(Clone, Debug, PartialEq)]
pub(super) struct Case {
    id: GameId,
    title: String,
    color: String,
}

pub(super) fn queue(bridge: &GameNightBridge) -> Vec<Case> {
    let next = bridge
        .latest_warm
        .as_ref()
        .map(|s| &s.game)
        .or_else(|| bridge.latest_warming.as_ref().map(|s| &s.game));
    let lobby = GameId::new(std::env::var("GAMENIGHT_GAME_ID").unwrap_or_else(|_| "lobby".into()));
    ordered_cases(
        &bridge.latest_playlist,
        &bridge.latest_library,
        next,
        bridge.active_game(),
        &lobby,
        bridge.latest_players.len().min(255) as u8,
    )
}

fn ordered_cases(
    entries: &[PlaylistEntry],
    library: &[GameMeta],
    next: Option<&GameId>,
    current: Option<&GameId>,
    lobby: &GameId,
    players: u8,
) -> Vec<Case> {
    let start = next
        .and_then(|id| entries.iter().position(|e| &e.game == id))
        .unwrap_or(0);
    let mut cases = Vec::new();
    for entry in entries.iter().cycle().skip(start).take(entries.len()) {
        let meta = library.iter().find(|m| m.id == entry.game);
        if &entry.game == lobby
            || Some(&entry.game) == current
            || meta.is_some_and(|m| m.max_players.is_some_and(|max| players > max))
            || cases.iter().any(|c: &Case| c.id == entry.game)
        {
            continue;
        }
        cases.push(Case {
            id: entry.game.clone(),
            title: entry.title.clone(),
            color: meta
                .and_then(|m| m.color.clone())
                .unwrap_or_else(|| "#5fb8ad".into()),
        });
    }
    cases
}

/// A short slide on a real queue change, never on progress/status updates.
#[derive(Default)]
pub(super) struct ShelfMotion {
    ids: Vec<GameId>,
    elapsed: f32,
}
impl ShelfMotion {
    pub(super) fn update(&mut self, cases: &[Case], dt: f32) -> f32 {
        let ids: Vec<_> = cases.iter().map(|c| c.id.clone()).collect();
        if self.ids != ids {
            self.elapsed = if self.ids.is_empty() { 0.4 } else { 0.0 };
            self.ids = ids;
        }
        self.elapsed = (self.elapsed + dt).min(0.4);
        let remaining = 1.0 - self.elapsed / 0.4;
        remaining * remaining
    }
}

fn block(parent: &mut ChildBuilder, x: f32, y: f32, z: f32, w: f32, h: f32, color: Color) {
    parent.spawn(SpriteBundle {
        sprite: Sprite {
            color,
            custom_size: Some(Vec2::new(w, h)),
            ..default()
        },
        transform: Transform::from_xyz(x, y, z),
        ..default()
    });
}
fn label(
    parent: &mut ChildBuilder,
    text: &str,
    x: f32,
    y: f32,
    width: f32,
    size: f32,
    font: &Handle<Font>,
    color: Color,
) {
    parent.spawn(Text2dBundle {
        text: Text::from_section(
            text,
            TextStyle {
                font: font.clone(),
                font_size: size,
                color,
            },
        )
        .with_alignment(TextAlignment::Center),
        text_2d_bounds: bevy::text::Text2dBounds {
            size: Vec2::new(width, 36.0),
        },
        transform: Transform::from_xyz(x, y, 0.6),
        ..default()
    });
}

pub(super) fn spawn_shelf(
    parent: &mut ChildBuilder,
    cases: &[Case],
    status: &str,
    motion: f32,
    font: Handle<Font>,
) {
    let wood = Color::rgb(0.46, 0.26, 0.16);
    block(parent, 60.0, -39.0, 0.0, 224.0, 8.0, wood);
    block(
        parent,
        60.0,
        -34.0,
        0.1,
        224.0,
        3.0,
        Color::rgb(0.82, 0.57, 0.32),
    );
    block(parent, -44.0, -45.0, 0.0, 8.0, 8.0, wood);
    block(parent, 164.0, -45.0, 0.0, 8.0, 8.0, wood);
    label(
        parent,
        "UP NEXT",
        3.0,
        43.0,
        100.0,
        11.0,
        &font,
        Color::rgb(1.0, 0.83, 0.48),
    );
    if cases.is_empty() {
        label(
            parent,
            "Nothing queued",
            60.0,
            0.0,
            210.0,
            12.0,
            &font,
            Color::WHITE,
        );
        return;
    }
    for (index, case) in cases.iter().take(4).enumerate().rev() {
        let x = -19.0 + index as f32 * 56.0 + motion * 32.0;
        let y = -1.0 + motion * 3.0;
        let accent =
            Color::hex(case.color.trim_start_matches('#')).unwrap_or(Color::rgb(0.37, 0.72, 0.68));
        // Thick dark case, coloured spine, paper cover and a tiny pixel motif.
        block(
            parent,
            x + 2.0,
            y - 1.0,
            0.1,
            52.0,
            68.0,
            Color::rgb(0.055, 0.07, 0.12),
        );
        block(parent, x, y, 0.2, 48.0, 66.0, Color::rgb(0.10, 0.13, 0.19));
        block(parent, x - 20.0, y, 0.3, 4.0, 62.0, accent);
        block(parent, x + 2.0, y + 7.0, 0.3, 38.0, 44.0, accent);
        let motif = motif(&case.id.0);
        for (row, pixels) in motif.iter().enumerate() {
            for (col, pixel) in pixels.bytes().enumerate() {
                if pixel == b'#' {
                    block(
                        parent,
                        x - 12.0 + col as f32 * 4.0,
                        y + 18.0 - row as f32 * 4.0,
                        0.4,
                        4.0,
                        4.0,
                        Color::rgb(0.98, 0.92, 0.74),
                    );
                }
            }
        }
        label(
            parent,
            &case.title,
            x + 2.0,
            y - 21.0,
            42.0,
            8.0,
            &font,
            Color::WHITE,
        );
    }
    // Loading belongs to the first case, not to the current game's TV.
    let hint = if status.contains("DOWNLOAD FAILED") {
        "DOWNLOAD FAILED"
    } else if status.contains("DOWNLOADING") {
        "DOWNLOADING"
    } else if status.contains("LOADING") {
        "LOADING"
    } else {
        ""
    };
    if !hint.is_empty() {
        label(
            parent,
            hint,
            80.0,
            43.0,
            120.0,
            9.0,
            &font,
            Color::rgb(1.0, 0.83, 0.48),
        );
    }
    if cases.len() > 4 {
        label(
            parent,
            &format!("+{}", cases.len() - 4),
            171.0,
            25.0,
            25.0,
            9.0,
            &font,
            Color::WHITE,
        );
    }
}

fn motif(id: &str) -> [&'static str; 7] {
    if id.contains("tank") {
        [
            "...#...", "...#...", ".#####.", "#######", "#######", ".#.#.#.", ".......",
        ]
    } else if id.contains("blast") || id.contains("bomb") {
        [
            "....##.", "...#...", "..###..", ".#####.", ".#####.", ".#####.", "..###..",
        ]
    } else if id.contains("neon") || id.contains("gun") {
        [
            "...#...", "..###..", ".#.#.#.", "#..#..#", "..###..", ".#...#.", ".......",
        ]
    } else if id.contains("pin") {
        [
            "..###..", ".#####.", ".#####.", "..###..", ".......", "##...##", ".##.##.",
        ]
    } else if id.contains("anti") || id.contains("paint") {
        [
            "...#...", "..###..", ".#####.", ".#####.", ".#####.", "..###..", ".......",
        ]
    } else {
        [
            "..###..", ".#...#.", "#.#.#.#", "#.....#", ".#####.", "..#.#..", ".#...#.",
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn entry(id: &str) -> PlaylistEntry {
        PlaylistEntry {
            game: GameId::new(id),
            title: id.into(),
        }
    }
    #[test]
    fn queue_starts_at_warm_and_excludes_current_and_lobby() {
        let entries = vec![entry("lobby"), entry("a"), entry("b"), entry("c")];
        let ids: Vec<_> = ordered_cases(
            &entries,
            &[],
            Some(&GameId::new("c")),
            Some(&GameId::new("a")),
            &GameId::new("lobby"),
            0,
        )
        .into_iter()
        .map(|c| c.id.0)
        .collect();
        assert_eq!(ids, vec!["c", "b"]);
    }
    #[test]
    fn games_that_do_not_fit_the_party_are_not_advertised() {
        let mut small =
            serde_json::from_value::<GameMeta>(serde_json::json!({"id":"a","title":"a"})).unwrap();
        small.max_players = Some(2);
        let cases = ordered_cases(
            &[entry("a"), entry("b"), entry("b")],
            &[small],
            None,
            None,
            &GameId::new("lobby"),
            3,
        );
        assert_eq!(cases.len(), 1);
        assert_eq!(cases[0].id, GameId::new("b"));
    }
    #[test]
    fn warm_game_below_minimum_stays_visible_like_host_fallback() {
        let mut meta =
            serde_json::from_value::<GameMeta>(serde_json::json!({"id":"a","title":"a"})).unwrap();
        meta.min_players = Some(2);
        let cases = ordered_cases(
            &[entry("a"), entry("b")],
            &[meta],
            Some(&GameId::new("a")),
            None,
            &GameId::new("lobby"),
            1,
        );
        assert_eq!(cases[0].id, GameId::new("a"));
    }
    #[test]
    fn same_queue_does_not_restart_slide() {
        let cases = ordered_cases(
            &[entry("a"), entry("b")],
            &[],
            None,
            None,
            &GameId::new("lobby"),
            0,
        );
        let mut motion = ShelfMotion::default();
        assert_eq!(motion.update(&cases, 0.01), 0.0);
        let reversed = vec![cases[1].clone(), cases[0].clone()];
        assert!(motion.update(&reversed, 0.01) > 0.0);
        assert_eq!(motion.update(&reversed, 0.5), 0.0);
        assert_eq!(motion.update(&reversed, 0.01), 0.0);
    }
}
