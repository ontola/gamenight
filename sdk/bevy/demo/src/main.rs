//! Star Catch: a small Bevy party game that uses every GameNight feature.
//!
//! Everyone is a ball in their own colour with their own face. Catch the
//! falling stars; bombs flash before they go off and knock stars out of you.
//! A round lasts a minute, the winner goes in the room log, and the next
//! round starts by itself. Start opens the menu; Back returns to the party.
//!
//! Run it standalone with `cargo run -p bevy-demo` (keyboard plus every
//! gamepad, `-- --bots 3` adds bots). GameNight launches it the same way
//! and the plugin takes over the window, audio and input.

// Bevy systems take many parameters and nested query filters.
#![allow(clippy::too_many_arguments, clippy::type_complexity)]

use std::f32::consts::TAU;
use std::sync::Arc;

use bevy::audio::{AudioSource, PlaybackMode, Volume};
use bevy::camera::ScalingMode;
use bevy::prelude::*;
use bevy::render::view::screenshot::{save_to_disk, Screenshot};
use gamenight_bevy::prelude::*;
use gamenight_bevy::{avatar_image, hex_color, PlayerId};
use serde_json::json;

mod sound;

const TITLE: &str = "Star Catch";
const ARENA: Vec2 = Vec2::new(1600.0, 900.0);
const BODY: f32 = 34.0;
const HEAD: f32 = 21.0;
const SPEED: f32 = 520.0;
const DASH_SPEED: f32 = 1500.0;
const RESULTS_SECONDS: f32 = 5.0;
const BOMB_FUSE: f32 = 1.4;
const BOMB_RADIUS: f32 = 150.0;

fn main() {
    let args = Args::parse();
    App::new()
        .add_plugins(DefaultPlugins.set(WindowPlugin {
            primary_window: Some(managed_window(Window {
                title: TITLE.into(),
                resolution: (1280u32, 720u32).into(),
                ..default()
            })),
            ..default()
        }))
        .add_plugins(GameNightPlugin::new("bevy-demo"))
        .insert_resource(ClearColor(Color::srgb(0.06, 0.07, 0.13)))
        .insert_resource(Match {
            rules: Rules {
                round_seconds: args.round.unwrap_or(60),
                ..default()
            },
            ..default()
        })
        .insert_resource(args)
        .init_resource::<Menu>()
        .add_systems(Startup, (setup, declare))
        .add_systems(
            Update,
            (
                gamenight_events,
                standalone_start,
                menu_input,
                (steer, bots, physics, stars, bombs, round_clock)
                    .chain()
                    .run_if(gameplay_runs)
                    .run_if(menu_closed),
                (draw_hud, draw_menu, phone_updates, music_volume, shot),
            )
                .chain(),
        )
        .run();
}

// ── Command line ───────────────────────────────────────────────────────────

#[derive(Resource, Clone, Default)]
struct Args {
    bots: usize,
    /// Round length in seconds before any setting changes it (tests use 5).
    round: Option<i64>,
    shot: Option<String>,
    menu: bool,
}

impl Args {
    fn parse() -> Self {
        let mut args = Args::default();
        let mut it = std::env::args().skip(1);
        while let Some(arg) = it.next() {
            match arg.as_str() {
                "--bots" => args.bots = it.next().and_then(|n| n.parse().ok()).unwrap_or(3),
                "--shot" => args.shot = it.next(),
                "--round" => args.round = it.next().and_then(|n| n.parse().ok()),
                "--menu" => args.menu = true,
                _ => {}
            }
        }
        args
    }
}

// ── Settings ───────────────────────────────────────────────────────────────

fn settings() -> Vec<SettingSpec> {
    vec![
        SettingSpec {
            key: "round_seconds".into(),
            label: "Round length (next round)".into(),
            description: Some("Seconds per round.".into()),
            kind: SettingKind::Number {
                default: 60,
                min: 20,
                max: 180,
            },
            scope: SettingScope::Party,
        },
        SettingSpec {
            key: "stars".into(),
            label: "Stars".into(),
            description: None,
            kind: SettingKind::Choice {
                default: "normal".into(),
                options: vec!["few".into(), "normal".into(), "lots".into()],
            },
            scope: SettingScope::Party,
        },
        SettingSpec {
            key: "bombs".into(),
            label: "Bombs".into(),
            description: Some("Bombs flash, then knock stars out of everyone nearby.".into()),
            kind: SettingKind::Toggle { default: true },
            scope: SettingScope::Party,
        },
        SettingSpec {
            key: "shape".into(),
            label: "My shape".into(),
            description: Some("Every player picks their own.".into()),
            kind: SettingKind::Choice {
                default: "round".into(),
                options: vec!["round".into(), "square".into()],
            },
            scope: SettingScope::Player,
        },
    ]
}

#[derive(Clone)]
struct Rules {
    round_seconds: i64,
    stars: String,
    bombs: bool,
}

impl Default for Rules {
    fn default() -> Self {
        Rules {
            round_seconds: 60,
            stars: "normal".into(),
            bombs: true,
        }
    }
}

impl Rules {
    fn apply(&mut self, key: &str, value: &SettingValue) {
        match (key, value) {
            ("round_seconds", SettingValue::Number(n)) => self.round_seconds = *n,
            ("stars", SettingValue::Choice(c)) => self.stars = c.clone(),
            ("bombs", SettingValue::Toggle(b)) => self.bombs = *b,
            _ => {}
        }
    }

    fn value(&self, key: &str) -> SettingValue {
        match key {
            "round_seconds" => SettingValue::Number(self.round_seconds),
            "stars" => SettingValue::Choice(self.stars.clone()),
            _ => SettingValue::Toggle(self.bombs),
        }
    }

    fn star_count(&self, players: usize) -> usize {
        let per = match self.stars.as_str() {
            "few" => 1,
            "lots" => 4,
            _ => 2,
        };
        (players.max(1) * per).clamp(3, 24)
    }
}

// ── State ──────────────────────────────────────────────────────────────────

#[derive(Resource)]
struct Match {
    rules: Rules,
    /// Round length for the round in progress (changes apply next round).
    length: f32,
    clock: f32,
    results: f32,
    round: u32,
    /// Stars per seat this round; a player who leaves keeps theirs until it ends.
    scores: Vec<Score>,
    /// Seats with a pawn right now.
    present: Vec<u8>,
    bomb_timer: f32,
    phones_at: f32,
    started: bool,
    rng: u64,
}

impl Default for Match {
    fn default() -> Self {
        Match {
            rules: Rules::default(),
            length: 60.0,
            clock: 60.0,
            results: 0.0,
            round: 0,
            scores: Vec::new(),
            present: Vec::new(),
            bomb_timer: 4.0,
            phones_at: 0.0,
            started: false,
            rng: 0x2545_f491_4f6c_dd1d,
        }
    }
}

impl Match {
    fn random(&mut self) -> f32 {
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 7;
        self.rng ^= self.rng << 17;
        (self.rng >> 40) as f32 / (1u64 << 24) as f32
    }

    fn spot(&mut self) -> Vec2 {
        Vec2::new(
            (self.random() - 0.5) * (ARENA.x - 160.0),
            (self.random() - 0.5) * (ARENA.y - 220.0) - 30.0,
        )
    }

    fn score(&mut self, seat: u8, player: Option<PlayerId>) -> &mut u32 {
        let i = match self
            .scores
            .iter()
            .position(|e| e.seat == seat && e.player == player)
        {
            Some(i) => i,
            None => {
                self.scores.push(Score {
                    seat,
                    player,
                    stars: 0,
                });
                self.scores.len() - 1
            }
        };
        &mut self.scores[i].stars
    }

    fn in_results(&self) -> bool {
        self.results > 0.0
    }
}

#[derive(Clone, Copy, Debug)]
struct Score {
    seat: u8,
    player: Option<PlayerId>,
    stars: u32,
}

#[derive(Component)]
struct Ball {
    seat: u8,
    player: Option<PlayerId>,
    bot: bool,
    velocity: Vec2,
    dash: f32,
    stunned: f32,
    phone_dash: bool,
}

#[derive(Component)]
struct Body;
#[derive(Component)]
struct Face;
#[derive(Component)]
struct Star {
    spin: f32,
}
#[derive(Component)]
struct Bomb {
    fuse: f32,
}
#[derive(Component)]
struct Blast(f32);
#[derive(Component)]
struct Hud;
#[derive(Component)]
struct ClockText;
#[derive(Component)]
struct MenuRoot;
#[derive(Component)]
struct Music;

#[derive(Resource)]
struct Art {
    circle: Handle<Mesh>,
    square: Handle<Mesh>,
    star: Handle<Mesh>,
    ring: Handle<Mesh>,
    dark: Handle<ColorMaterial>,
    star_color: Handle<ColorMaterial>,
    pickup: Handle<AudioSource>,
    boom: Handle<AudioSource>,
}

#[derive(Resource)]
struct UiFont(Handle<Font>);

#[derive(Resource, Default)]
struct Menu {
    open: bool,
    row: usize,
}

const MENU_ROWS: [&str; 5] = ["Resume", "New round", "round_seconds", "stars", "bombs"];

fn menu_closed(menu: Res<Menu>) -> bool {
    !menu.open
}

// ── Setup ──────────────────────────────────────────────────────────────────

fn setup(
    mut commands: Commands,
    mut meshes: ResMut<Assets<Mesh>>,
    mut materials: ResMut<Assets<ColorMaterial>>,
    mut audio: ResMut<Assets<AudioSource>>,
    mut fonts: ResMut<Assets<Font>>,
) {
    // Outfit, GameNight's UI font, embedded so the binary needs no asset folder.
    let ui = UiFont(fonts.add(Font::from_bytes(
        include_bytes!("../assets/fonts/Outfit-700.ttf").to_vec(),
    )));
    commands.spawn((
        Camera2d,
        Projection::Orthographic(OrthographicProjection {
            scaling_mode: ScalingMode::AutoMin {
                min_width: ARENA.x,
                min_height: ARENA.y,
            },
            ..OrthographicProjection::default_2d()
        }),
    ));
    let art = Art {
        circle: meshes.add(Circle::new(1.0)),
        square: meshes.add(Rectangle::new(1.8, 1.8)),
        star: meshes.add(star_mesh()),
        ring: meshes.add(Annulus::new(0.94, 1.0)),
        dark: materials.add(Color::srgb(0.05, 0.05, 0.08)),
        star_color: materials.add(Color::srgb(1.0, 0.85, 0.3)),
        pickup: audio.add(AudioSource {
            bytes: Arc::from(sound::pickup()),
        }),
        boom: audio.add(AudioSource {
            bytes: Arc::from(sound::boom()),
        }),
    };
    // The floor: a slightly lighter rounded field.
    commands.spawn((
        Mesh2d(meshes.add(Rectangle::new(ARENA.x - 40.0, ARENA.y - 120.0))),
        MeshMaterial2d(materials.add(Color::srgb(0.09, 0.11, 0.2))),
        Transform::from_xyz(0.0, -30.0, -10.0),
    ));
    commands.spawn((
        AudioPlayer::new(audio.add(AudioSource {
            bytes: Arc::from(sound::music()),
        })),
        PlaybackSettings {
            mode: PlaybackMode::Loop,
            volume: Volume::Linear(0.35),
            ..default()
        },
        Music,
    ));
    commands.spawn((
        Hud,
        Node {
            position_type: PositionType::Absolute,
            top: Val::Vh(2.0),
            left: Val::Vw(3.0),
            right: Val::Vw(3.0),
            column_gap: Val::Vw(2.5),
            align_items: AlignItems::Center,
            ..default()
        },
    ));
    commands.spawn((
        ClockText,
        Text::new(""),
        TextFont {
            font: ui.0.clone().into(),
            font_size: FontSize::Vh(5.0),
            ..default()
        },
        TextColor(Color::WHITE),
        Node {
            position_type: PositionType::Absolute,
            top: Val::Vh(1.5),
            right: Val::Vw(3.0),
            ..default()
        },
    ));
    commands.insert_resource(art);
    commands.insert_resource(ui);
}

/// Declare once; the plugin declares again after a reconnect.
fn declare(mut gn: ResMut<GameNight>) {
    gn.declare_settings(settings());
    gn.declare_actions(vec![GameAction {
        key: "new_round".into(),
        label: "New round".into(),
        description: Some("Ends this round for everyone.".into()),
        confirm: true,
    }]);
    gn.declare_companion_folder("phone", "index.html");
    gn.declare_commands(
        "Change the round length, the number of stars or bombs.",
        vec![
            "90 second rounds".into(),
            "lots of stars".into(),
            "no bombs".into(),
        ],
    );
}

// ── GameNight ──────────────────────────────────────────────────────────────

fn gamenight_events(
    mut commands: Commands,
    mut gn: ResMut<GameNight>,
    mut events: MessageReader<GameNightEvent>,
    mut game: ResMut<Match>,
    mut menu: ResMut<Menu>,
    art: Res<Art>,
    mut images: ResMut<Assets<Image>>,
    mut materials: ResMut<Assets<ColorMaterial>>,
    balls: Query<(Entity, &Ball)>,
    stars: Query<Entity, Or<(With<Star>, With<Bomb>, With<Blast>)>>,
    mut music: Query<&mut AudioSink, With<Music>>,
) {
    // Pawns despawned earlier in this batch (Dispose then Prepare arrive together).
    let mut gone = Vec::new();
    for event in events.read() {
        match event {
            GameNightEvent::Prepare { seats, players, .. } => {
                // Load everything while hidden. New players can drop in mid-round.
                gn.participation(true);
                *menu = Menu::default();
                let rules = game.rules.clone();
                *game = Match { rules, ..default() };
                clear(&mut gone, &mut commands, &balls, &stars);
                spawn_balls(
                    &mut commands,
                    &gn,
                    seats,
                    players,
                    &art,
                    &mut images,
                    &mut materials,
                    &mut game,
                );
                new_round(&mut commands, &mut game, &art);
                game.started = true;
                gn.ready();
            }
            // The plugin shows the window and plays audio on Start and Resume,
            // and hides and pauses them on Pause. Simulation systems run only
            // while `gameplay_runs`, so there is nothing else to do here.
            GameNightEvent::Start { .. }
            | GameNightEvent::Pause { .. }
            | GameNightEvent::Resume { .. } => {}
            GameNightEvent::Dispose { .. } => {
                clear(&mut gone, &mut commands, &balls, &stars);
                game.started = false;
            }
            GameNightEvent::RosterChanged { seats, players, .. } => {
                // Keep the match going: add newcomers, drop pawns of those who left.
                let mut known = Vec::new();
                let alive: Vec<(Entity, &Ball)> =
                    balls.iter().filter(|(e, _)| !gone.contains(e)).collect();
                for (entity, ball) in alive {
                    let still = seats
                        .iter()
                        .any(|s| s.index == ball.seat && s.occupant.player_id() == ball.player);
                    if still {
                        known.push(ball.seat);
                    } else {
                        commands.entity(entity).try_despawn();
                        gone.push(entity);
                    }
                }
                let fresh: Vec<Seat> = seats
                    .iter()
                    .filter(|s| !known.contains(&s.index))
                    .cloned()
                    .collect();
                spawn_balls(
                    &mut commands,
                    &gn,
                    &fresh,
                    players,
                    &art,
                    &mut images,
                    &mut materials,
                    &mut game,
                );
            }
            GameNightEvent::PlayersUpdated { players } => {
                // A new name, colour or face for the same player: repaint, never restart.
                for (entity, ball) in balls.iter().filter(|(e, _)| !gone.contains(e)) {
                    if let Some(player) = players.iter().find(|p| Some(p.id) == ball.player) {
                        commands.entity(entity).despawn_children();
                        dress(
                            &mut commands,
                            entity,
                            Some(player),
                            ball.seat,
                            &gn,
                            &art,
                            &mut images,
                            &mut materials,
                        );
                    }
                }
            }
            GameNightEvent::SettingChanged { key, value } => {
                game.rules.apply(key, value);
            }
            GameNightEvent::PlayerSettings { player_id, .. } => {
                for (entity, ball) in balls.iter().filter(|(e, _)| !gone.contains(e)) {
                    if ball.player == Some(*player_id) {
                        commands.entity(entity).despawn_children();
                        let player = gn.player(*player_id).cloned();
                        dress(
                            &mut commands,
                            entity,
                            player.as_ref(),
                            ball.seat,
                            &gn,
                            &art,
                            &mut images,
                            &mut materials,
                        );
                    }
                }
            }
            GameNightEvent::ActionTriggered { key, player_id } if key == "new_round" => {
                let who = gn
                    .player(*player_id)
                    .map_or("Someone".into(), |p| p.name.clone());
                info!("{who} asked for a new round");
                new_round(&mut commands, &mut game, &art);
            }
            GameNightEvent::CompanionMessage { player_id, data } => {
                if data.get("action").and_then(|a| a.as_str()) == Some("dash") {
                    for (entity, ball) in balls.iter().filter(|(e, _)| !gone.contains(e)) {
                        if ball.player == Some(*player_id) {
                            commands
                                .entity(entity)
                                .entry::<Ball>()
                                .and_modify(|mut b| b.phone_dash = true);
                        }
                    }
                }
            }
            GameNightEvent::CompanionPresence {
                player_id,
                connected: true,
            } => {
                let view = phone_view(&gn, &game, *player_id);
                gn.companion_message(Some(*player_id), view);
            }
            GameNightEvent::GameCommand { id, text, .. } => {
                let (ok, answer) = command(&mut gn, text);
                gn.command_result(id.clone(), ok, answer);
            }
            GameNightEvent::HostMusic { playing } => {
                if let Ok(mut sink) = music.single_mut() {
                    sink.set_volume(Volume::Linear(if *playing { 0.0 } else { 0.35 }));
                }
            }
            _ => {}
        }
    }
}

/// Plain-text requests from the GameNight app or assistant.
fn command(gn: &mut GameNight, text: &str) -> (bool, String) {
    let text = text.to_lowercase();
    if let Some(n) = text
        .split(|c: char| !c.is_ascii_digit())
        .find_map(|w| w.parse::<i64>().ok())
    {
        let n = n.clamp(20, 180);
        gn.set_setting("round_seconds", SettingValue::Number(n));
        return (
            true,
            format!("Rounds last {n} seconds from the next round."),
        );
    }
    for (word, value) in [
        ("few", "few"),
        ("less", "few"),
        ("lots", "lots"),
        ("more", "lots"),
        ("normal", "normal"),
    ] {
        if text.contains(word) && text.contains("star") {
            gn.set_setting("stars", SettingValue::Choice(value.into()));
            return (true, format!("Stars: {value}."));
        }
    }
    if text.contains("bomb") {
        let on = !(text.contains("no ") || text.contains("off") || text.contains("geen"));
        gn.set_setting("bombs", SettingValue::Toggle(on));
        return (true, format!("Bombs {}.", if on { "on" } else { "off" }));
    }
    (
        false,
        "I can change the round length, the stars and the bombs.".into(),
    )
}

/// Standalone, the game starts at once with the local seats (and bots).
fn standalone_start(
    mut commands: Commands,
    gn: Res<GameNight>,
    args: Res<Args>,
    mut game: ResMut<Match>,
    mut menu: ResMut<Menu>,
    art: Res<Art>,
    mut images: ResMut<Assets<Image>>,
    mut materials: ResMut<Assets<ColorMaterial>>,
    balls: Query<(Entity, &Ball)>,
    mut seen: Local<usize>,
) {
    if gn.managed() || gn.seats.is_empty() {
        return;
    }
    if game.started && *seen == gn.seats.len() {
        return;
    }
    let mut seats = gn.seats.clone();
    let first_bot = seats.len() as u8;
    for i in 0..args.bots {
        seats.push(Seat {
            index: first_bot + i as u8,
            occupant: SeatOccupant::Ai,
            controller: None,
        });
    }
    let fresh: Vec<Seat> = seats
        .into_iter()
        .filter(|s| !balls.iter().any(|(_, b)| b.seat == s.index))
        .collect();
    let players = gn.players.clone();
    spawn_balls(
        &mut commands,
        &gn,
        &fresh,
        &players,
        &art,
        &mut images,
        &mut materials,
        &mut game,
    );
    if !game.started {
        game.started = true;
        new_round(&mut commands, &mut game, &art);
        menu.open = args.menu;
    }
    *seen = gn.seats.len();
}

fn clear(
    gone: &mut Vec<Entity>,
    commands: &mut Commands,
    balls: &Query<(Entity, &Ball)>,
    things: &Query<Entity, Or<(With<Star>, With<Bomb>, With<Blast>)>>,
) {
    for (entity, _) in balls {
        commands.entity(entity).try_despawn();
        gone.push(entity);
    }
    for entity in things {
        commands.entity(entity).try_despawn();
    }
}

fn spawn_balls(
    commands: &mut Commands,
    gn: &GameNight,
    seats: &[Seat],
    players: &[Player],
    art: &Art,
    images: &mut Assets<Image>,
    materials: &mut Assets<ColorMaterial>,
    game: &mut Match,
) {
    for seat in seats {
        let bot = matches!(seat.occupant, SeatOccupant::Ai);
        let player = seat
            .occupant
            .player_id()
            .and_then(|id| players.iter().find(|p| p.id == id));
        if player.is_none() && !bot {
            continue; // An empty seat gets no pawn.
        }
        game.score(seat.index, player.map(|p| p.id));
        let at = game.spot();
        let entity = commands
            .spawn((
                Ball {
                    seat: seat.index,
                    player: player.map(|p| p.id),
                    bot,
                    velocity: Vec2::ZERO,
                    dash: 0.0,
                    stunned: 0.0,
                    phone_dash: false,
                },
                Transform::from_translation(at.extend(1.0)),
                Visibility::default(),
            ))
            .id();
        dress(
            commands, entity, player, seat.index, gn, art, images, materials,
        );
    }
}

const BOT_COLORS: [&str; 4] = ["#94a3b8", "#a3a3a3", "#9ca3af", "#a8a29e"];

fn bot_color(seat: u8) -> Color {
    hex_color(Some(BOT_COLORS[seat as usize % 4]), Color::WHITE)
}

/// The body in the player's colour, a head in their skin colour and their face.
fn dress(
    commands: &mut Commands,
    entity: Entity,
    player: Option<&Player>,
    seat: u8,
    gn: &GameNight,
    art: &Art,
    images: &mut Assets<Image>,
    materials: &mut Assets<ColorMaterial>,
) {
    let fallback = bot_color(seat);
    let color = hex_color(player.and_then(|p| p.color.as_deref()), fallback);
    let skin = hex_color(
        player.and_then(|p| p.skin_color.as_deref()),
        Color::srgb(0.96, 0.8, 0.66),
    );
    let square = player
        .and_then(|p| gn.player_setting(p.id, "shape"))
        .is_some_and(|v| v == SettingValue::Choice("square".into()));
    let body = if square {
        art.square.clone()
    } else {
        art.circle.clone()
    };
    commands.entity(entity).with_children(|parent| {
        parent.spawn((
            Body,
            Mesh2d(body),
            MeshMaterial2d(materials.add(color)),
            Transform::from_scale(Vec3::splat(BODY)),
        ));
        parent.spawn((
            Mesh2d(art.circle.clone()),
            MeshMaterial2d(materials.add(skin)),
            Transform::from_xyz(0.0, 4.0, 0.1).with_scale(Vec3::splat(HEAD)),
        ));
        match player.and_then(avatar_image) {
            Some((image, head)) => {
                // Put the head centre of the drawing on the head circle.
                let scale = HEAD / head.radius;
                let size = Vec2::new(image.width() as f32, image.height() as f32);
                let offset = (size / 2.0 - Vec2::from(head.center)) * Vec2::new(1.0, -1.0) * scale;
                parent.spawn((
                    Face,
                    Sprite {
                        image: images.add(image),
                        custom_size: Some(size * scale),
                        ..default()
                    },
                    Transform::from_xyz(offset.x, 4.0 + offset.y, 0.2),
                ));
            }
            None => {
                for x in [-7.0, 7.0] {
                    parent.spawn((
                        Mesh2d(art.circle.clone()),
                        MeshMaterial2d(art.dark.clone()),
                        Transform::from_xyz(x, 7.0, 0.2).with_scale(Vec3::splat(3.2)),
                    ));
                }
            }
        }
    });
}

/// A five-pointed star, radius 1.
fn star_mesh() -> Mesh {
    use bevy::asset::RenderAssetUsages;
    use bevy::mesh::{Indices, PrimitiveTopology};
    let mut positions = vec![[0.0, 0.0, 0.0]];
    for i in 0..10 {
        let a = i as f32 * TAU / 10.0;
        let r = if i % 2 == 0 { 1.0 } else { 0.45 };
        positions.push([r * a.sin(), r * a.cos(), 0.0]);
    }
    let uvs: Vec<[f32; 2]> = positions
        .iter()
        .map(|p| [p[0] * 0.5 + 0.5, 0.5 - p[1] * 0.5])
        .collect();
    let normals = vec![[0.0, 0.0, 1.0]; positions.len()];
    let mut indices = vec![0, 10, 1];
    for i in 2..=10 {
        indices.extend_from_slice(&[0, i - 1, i]);
    }
    Mesh::new(
        PrimitiveTopology::TriangleList,
        RenderAssetUsages::default(),
    )
    .with_inserted_attribute(Mesh::ATTRIBUTE_POSITION, positions)
    .with_inserted_attribute(Mesh::ATTRIBUTE_NORMAL, normals)
    .with_inserted_attribute(Mesh::ATTRIBUTE_UV_0, uvs)
    .with_inserted_indices(Indices::U32(indices))
}

fn new_round(commands: &mut Commands, game: &mut Match, art: &Art) {
    game.round += 1;
    game.length = game.rules.round_seconds as f32;
    game.clock = game.length;
    game.results = 0.0;
    game.bomb_timer = 4.0;
    let present = game.present.clone();
    game.scores
        .retain(|e| present.is_empty() || present.contains(&e.seat));
    for entry in game.scores.iter_mut() {
        entry.stars = 0;
    }
    let count = game.rules.star_count(game.scores.len());
    for _ in 0..count {
        spawn_star(commands, game, art);
    }
}

fn spawn_star(commands: &mut Commands, game: &mut Match, art: &Art) {
    let at = game.spot();
    let spin = game.random() * TAU;
    commands.spawn((
        Star { spin },
        Mesh2d(art.star.clone()),
        MeshMaterial2d(art.star_color.clone()),
        Transform::from_translation(at.extend(0.5)).with_scale(Vec3::splat(26.0)),
    ));
}

// ── Play ───────────────────────────────────────────────────────────────────

fn steer(
    gn: Res<GameNight>,
    mut game: ResMut<Match>,
    mut balls: Query<&mut Ball>,
    time: Res<Time>,
) {
    let dt = time.delta_secs();
    game.present = balls.iter().map(|b| b.seat).collect();
    for mut ball in &mut balls {
        ball.dash = (ball.dash - dt).max(-0.6);
        ball.stunned = (ball.stunned - dt).max(0.0);
        if ball.bot || ball.stunned > 0.0 {
            continue;
        }
        let pad = gn.pad(ball.seat);
        let target = pad.stick(0)
            + Vec2::new(
                pad.pressed(PadButton::Right) as i32 as f32
                    - pad.pressed(PadButton::Left) as i32 as f32,
                pad.pressed(PadButton::Up) as i32 as f32
                    - pad.pressed(PadButton::Down) as i32 as f32,
            );
        let target = target.clamp_length_max(1.0) * SPEED;
        ball.velocity = ball.velocity.lerp(target, (dt * 12.0).min(1.0));
        let dash = pad.just_pressed(PadButton::A) || std::mem::take(&mut ball.phone_dash);
        if dash && ball.dash <= -0.6 {
            let dir = if target != Vec2::ZERO {
                target.normalize()
            } else {
                ball.velocity.normalize_or(Vec2::X)
            };
            ball.velocity = dir * DASH_SPEED;
            ball.dash = 0.18;
        }
    }
}

fn bots(
    mut balls: Query<(&mut Ball, &Transform)>,
    stars: Query<&Transform, With<Star>>,
    time: Res<Time>,
) {
    let dt = time.delta_secs();
    for (mut ball, at) in &mut balls {
        if !ball.bot || ball.stunned > 0.0 {
            continue;
        }
        let here = at.translation.truncate();
        let nearest = stars
            .iter()
            .map(|s| s.translation.truncate())
            .min_by(|a, b| a.distance(here).total_cmp(&b.distance(here)));
        let target = nearest.map_or(Vec2::ZERO, |s| {
            (s - here).normalize_or_zero() * SPEED * 0.75
        });
        ball.velocity = ball.velocity.lerp(target, (dt * 4.0).min(1.0));
    }
}

fn physics(mut balls: Query<(&mut Ball, &mut Transform)>, time: Res<Time>) {
    let dt = time.delta_secs();
    let bounds = Vec2::new(ARENA.x / 2.0 - 20.0 - BODY, ARENA.y / 2.0 - 80.0 - BODY);
    for (mut ball, mut at) in &mut balls {
        if ball.dash > 0.0 {
            // Dashing keeps its speed; afterwards it eases back.
        } else if ball.velocity.length() > SPEED {
            ball.velocity *= 0.9;
        }
        let mut p = at.translation.truncate() + ball.velocity * dt;
        let centre = Vec2::new(0.0, -30.0);
        let rel = p - centre;
        if rel.x.abs() > bounds.x {
            ball.velocity.x = -ball.velocity.x * 0.5;
        }
        if rel.y.abs() > bounds.y {
            ball.velocity.y = -ball.velocity.y * 0.5;
        }
        p = centre + rel.clamp(-bounds, bounds);
        at.translation = p.extend(1.0);
    }
    // Balls push each other apart.
    let mut list: Vec<_> = balls.iter_mut().collect();
    for i in 0..list.len() {
        for j in i + 1..list.len() {
            let (a, b) = list.split_at_mut(j);
            let (ta, tb) = (&mut a[i].1, &mut b[0].1);
            let d = tb.translation.truncate() - ta.translation.truncate();
            let overlap = BODY * 2.0 - d.length();
            if overlap > 0.0 {
                let push = d.normalize_or(Vec2::X) * overlap / 2.0;
                ta.translation -= push.extend(0.0);
                tb.translation += push.extend(0.0);
            }
        }
    }
}

fn stars(
    mut commands: Commands,
    mut gn: ResMut<GameNight>,
    mut game: ResMut<Match>,
    art: Res<Art>,
    balls: Query<(&Ball, &Transform)>,
    mut stars: Query<(Entity, &mut Star, &mut Transform), Without<Ball>>,
    time: Res<Time>,
) {
    let want = game.rules.star_count(game.scores.len());
    let mut have = 0;
    for (entity, mut star, mut at) in &mut stars {
        star.spin += time.delta_secs();
        at.rotation = Quat::from_rotation_z(star.spin);
        have += 1;
        if game.in_results() {
            continue;
        }
        let hit = balls.iter().find(|(_, b)| {
            b.translation.truncate().distance(at.translation.truncate()) < BODY + 16.0
        });
        if let Some((ball, _)) = hit {
            commands.entity(entity).try_despawn();
            have -= 1;
            commands.spawn((
                AudioPlayer::new(art.pickup.clone()),
                PlaybackSettings::DESPAWN,
            ));
            gn.rumble(ball.seat, 0.4, 0.0, 0.08);
            *game.score(ball.seat, ball.player) += 1;
        }
    }
    for _ in have..want {
        spawn_star(&mut commands, &mut game, &art);
    }
}

fn bombs(
    mut commands: Commands,
    mut gn: ResMut<GameNight>,
    mut game: ResMut<Match>,
    art: Res<Art>,
    mut materials: ResMut<Assets<ColorMaterial>>,
    mut balls: Query<(&mut Ball, &Transform)>,
    mut bombs: Query<(
        Entity,
        &mut Bomb,
        &Transform,
        &MeshMaterial2d<ColorMaterial>,
    )>,
    mut blasts: Query<(Entity, &mut Blast, &mut Transform), (Without<Bomb>, Without<Ball>)>,
    time: Res<Time>,
) {
    let dt = time.delta_secs();
    for (entity, mut blast, mut at) in &mut blasts {
        blast.0 -= dt;
        at.scale = Vec3::splat(BOMB_RADIUS * (1.2 - blast.0));
        if blast.0 <= 0.0 {
            commands.entity(entity).try_despawn();
        }
    }
    if game.rules.bombs && !game.in_results() {
        game.bomb_timer -= dt;
        if game.bomb_timer <= 0.0 {
            game.bomb_timer = 3.0 + game.random() * 3.0;
            let at = game.spot();
            // The warning ring shows exactly where it will hit.
            commands.spawn((
                Bomb { fuse: BOMB_FUSE },
                Mesh2d(art.ring.clone()),
                MeshMaterial2d(materials.add(Color::srgba(1.0, 0.3, 0.25, 0.8))),
                Transform::from_translation(at.extend(0.2)).with_scale(Vec3::splat(BOMB_RADIUS)),
            ));
        }
    }
    for (entity, mut bomb, at, material) in &mut bombs {
        bomb.fuse -= dt;
        let flash = (bomb.fuse * 14.0).sin() > 0.0;
        if let Some(mut m) = materials.get_mut(&material.0) {
            m.color = if flash {
                Color::srgba(1.0, 0.3, 0.25, 0.9)
            } else {
                Color::srgba(1.0, 0.85, 0.4, 0.5)
            };
        }
        if bomb.fuse > 0.0 {
            continue;
        }
        commands.entity(entity).try_despawn();
        commands.spawn((
            AudioPlayer::new(art.boom.clone()),
            PlaybackSettings::DESPAWN,
        ));
        commands.spawn((
            Blast(0.35),
            Mesh2d(art.circle.clone()),
            MeshMaterial2d(materials.add(Color::srgba(1.0, 0.95, 0.8, 0.55))),
            Transform::from_translation(at.translation.truncate().extend(0.3)),
        ));
        for (mut ball, b) in &mut balls {
            let d = b.translation.truncate() - at.translation.truncate();
            if d.length() < BOMB_RADIUS + BODY * 0.5 {
                ball.velocity = d.normalize_or(Vec2::Y) * 900.0;
                ball.stunned = 0.5;
                gn.rumble(ball.seat, 0.3, 0.9, 0.3);
                let s = game.score(ball.seat, ball.player);
                *s = s.saturating_sub(2);
            }
        }
    }
}

fn round_clock(
    mut commands: Commands,
    mut gn: ResMut<GameNight>,
    mut game: ResMut<Match>,
    art: Res<Art>,
    time: Res<Time>,
) {
    let dt = time.delta_secs();
    if game.in_results() {
        game.results -= dt;
        if game.results <= 0.0 {
            new_round(&mut commands, &mut game, &art);
        }
        return;
    }
    game.clock -= dt;
    if game.clock > 0.0 {
        return;
    }
    // Round over: show the result, tell GameNight, save stats, go again.
    game.clock = 0.0;
    game.results = RESULTS_SECONDS;
    let best = game.scores.iter().max_by_key(|e| e.stars).copied();
    if let Some(best) = best.filter(|e| e.stars > 0) {
        let name = best
            .player
            .and_then(|id| gn.player(id))
            .map_or("A bot".into(), |p| p.name.clone());
        gn.room_log(format!(
            "{name} wins round {} with {} stars",
            game.round, best.stars
        ));
    }
    // Lifetime stars and wins follow each profile to the next game night.
    for entry in game.scores.clone() {
        let Some(id) = entry.player else { continue };
        let old = gn.player_data(id).cloned().unwrap_or_else(|| json!({}));
        let total = old.get("stars").and_then(|v| v.as_u64()).unwrap_or(0) + entry.stars as u64;
        let won = best.is_some_and(|b| b.player == Some(id) && b.stars > 0);
        let wins = old.get("wins").and_then(|v| v.as_u64()).unwrap_or(0) + u64::from(won);
        gn.save_player_data(id, json!({ "stars": total, "wins": wins }));
    }
    gn.finished();
}

// ── Menu ───────────────────────────────────────────────────────────────────

/// Start opens and closes the menu for everyone; any player can use it.
/// Back is never read: it belongs to GameNight.
fn menu_input(
    mut commands: Commands,
    mut gn: ResMut<GameNight>,
    mut menu: ResMut<Menu>,
    mut game: ResMut<Match>,
    art: Res<Art>,
) {
    if !gn.is_running() {
        return;
    }
    let seats: Vec<u8> = gn.seats.iter().map(|s| s.index).collect();
    for seat in seats {
        let pad = gn.pad(seat);
        if pad.just_pressed(PadButton::Start) {
            menu.open = !menu.open;
            menu.row = 0;
            continue;
        }
        if !menu.open {
            continue;
        }
        let vertical =
            pad.just_pressed(PadButton::Down) as i32 - pad.just_pressed(PadButton::Up) as i32;
        menu.row = (menu.row as i32 + vertical).rem_euclid(MENU_ROWS.len() as i32) as usize;
        let step =
            pad.just_pressed(PadButton::Right) as i64 - pad.just_pressed(PadButton::Left) as i64;
        let row = MENU_ROWS[menu.row];
        match row {
            "Resume" if pad.just_pressed(PadButton::A) || pad.just_pressed(PadButton::B) => {
                menu.open = false
            }
            "New round" if pad.just_pressed(PadButton::A) => {
                menu.open = false;
                new_round(&mut commands, &mut game, &art);
            }
            "Resume" | "New round" => {
                if pad.just_pressed(PadButton::B) {
                    menu.open = false;
                }
            }
            key => {
                let step = if pad.just_pressed(PadButton::A) && step == 0 {
                    1
                } else {
                    step
                };
                if step != 0 {
                    let next = next_value(key, &game.rules.value(key), step);
                    // Through GameNight, so the apps show the same value.
                    gn.set_setting(key, next);
                }
                if pad.just_pressed(PadButton::B) {
                    menu.open = false;
                }
            }
        }
    }
}

fn next_value(key: &str, value: &SettingValue, step: i64) -> SettingValue {
    let spec = settings().into_iter().find(|s| s.key == key).unwrap();
    match (&spec.kind, value) {
        (SettingKind::Number { min, max, .. }, SettingValue::Number(n)) => {
            SettingValue::Number((n + step * 10).clamp(*min, *max))
        }
        (SettingKind::Choice { options, .. }, SettingValue::Choice(c)) => {
            let i = options.iter().position(|o| o == c).unwrap_or(0) as i64;
            SettingValue::Choice(
                options[(i + step).rem_euclid(options.len() as i64) as usize].clone(),
            )
        }
        (_, SettingValue::Toggle(b)) => SettingValue::Toggle(!b),
        (_, other) => other.clone(),
    }
}

fn draw_menu(
    mut commands: Commands,
    menu: Res<Menu>,
    game: Res<Match>,
    ui: Res<UiFont>,
    root: Query<Entity, With<MenuRoot>>,
) {
    if !menu.is_changed() && !game.is_changed() {
        return;
    }
    for entity in &root {
        commands.entity(entity).try_despawn();
    }
    if !menu.open {
        return;
    }
    let text = |s: String, size: f32, color: Color| {
        (
            Text::new(s),
            TextFont {
                font: ui.0.clone().into(),
                font_size: FontSize::Vh(size),
                ..default()
            },
            TextColor(color),
        )
    };
    commands
        .spawn((
            MenuRoot,
            Node {
                position_type: PositionType::Absolute,
                width: Val::Percent(100.0),
                height: Val::Percent(100.0),
                flex_direction: FlexDirection::Column,
                align_items: AlignItems::Center,
                justify_content: JustifyContent::Center,
                row_gap: Val::Vh(1.6),
                ..default()
            },
            BackgroundColor(Color::srgba(0.02, 0.02, 0.06, 0.8)),
            GlobalZIndex(10),
        ))
        .with_children(|menu_ui| {
            // The game's name heads the menu every time.
            menu_ui.spawn(text(TITLE.into(), 8.0, Color::srgb(1.0, 0.85, 0.3)));
            for (i, row) in MENU_ROWS.iter().enumerate() {
                let label = match *row {
                    "Resume" | "New round" => row.to_string(),
                    key => {
                        let spec = settings().into_iter().find(|s| s.key == key).unwrap();
                        let value = match game.rules.value(key) {
                            SettingValue::Toggle(b) => {
                                if b {
                                    "On".into()
                                } else {
                                    "Off".into()
                                }
                            }
                            SettingValue::Number(n) => format!("{n} s"),
                            SettingValue::Choice(c) => c,
                        };
                        format!("{}   ‹ {value} ›", spec.label)
                    }
                };
                let selected = i == menu.row;
                menu_ui
                    .spawn((
                        Node {
                            padding: UiRect::axes(Val::Vw(2.0), Val::Vh(0.8)),
                            ..default()
                        },
                        BackgroundColor(if selected {
                            Color::srgba(1.0, 1.0, 1.0, 0.14)
                        } else {
                            Color::NONE
                        }),
                    ))
                    .with_child(text(
                        label,
                        4.2,
                        if selected {
                            Color::WHITE
                        } else {
                            Color::srgb(0.7, 0.72, 0.8)
                        },
                    ));
            }
        });
}

// ── HUD, phones, music ─────────────────────────────────────────────────────

/// One dot and score per player, laid out in couch order. No text over the
/// players and no control hints.
fn draw_hud(
    mut commands: Commands,
    gn: Res<GameNight>,
    game: Res<Match>,
    ui: Res<UiFont>,
    hud: Single<Entity, With<Hud>>,
    mut clock: Single<&mut Text, With<ClockText>>,
    mut last: Local<String>,
) {
    let seconds = game.clock.ceil() as u32;
    clock.0 = if game.in_results() {
        String::new()
    } else {
        format!("{}:{:02}", seconds / 60, seconds % 60)
    };
    // Couch order for people (left to right as they sit), bots after them.
    let order = couch_order(&gn.seats, &gn.players);
    let place = |e: &Score| {
        order
            .iter()
            .position(|s| s.index == e.seat && s.occupant.player_id() == e.player)
            .unwrap_or(100 + e.seat as usize)
    };
    let mut entries = game.scores.clone();
    entries.sort_by_key(place);
    let rows: Vec<(String, Color, u32)> = entries
        .iter()
        .map(|e| match e.player.and_then(|id| gn.player(id)) {
            Some(p) => (
                p.name.clone(),
                hex_color(p.color.as_deref(), Color::WHITE),
                e.stars,
            ),
            None => ("Bot".into(), bot_color(e.seat), e.stars),
        })
        .collect();
    let best = rows.iter().map(|r| r.2).max().unwrap_or(0);
    let key = format!("{rows:?}{}", game.in_results());
    if *last == key {
        return;
    }
    *last = key;
    commands.entity(*hud).despawn_children();
    commands.entity(*hud).with_children(|bar| {
        for (name, color, score) in rows {
            let winner = game.in_results() && score == best && best > 0;
            bar.spawn(Node {
                align_items: AlignItems::Center,
                column_gap: Val::Vw(0.6),
                ..default()
            })
            .with_children(|cell| {
                cell.spawn((
                    Node {
                        width: Val::Vh(3.0),
                        height: Val::Vh(3.0),
                        border_radius: BorderRadius::MAX,
                        ..default()
                    },
                    BackgroundColor(color),
                ));
                let label = if game.in_results() {
                    format!("{name}: {score}")
                } else {
                    score.to_string()
                };
                cell.spawn((
                    Text::new(label),
                    TextFont {
                        font: ui.0.clone().into(),
                        font_size: FontSize::Vh(if winner { 5.0 } else { 4.0 }),
                        ..default()
                    },
                    TextColor(if winner {
                        Color::srgb(1.0, 0.85, 0.3)
                    } else {
                        Color::WHITE
                    }),
                ));
            });
        }
    });
}

fn phone_view(gn: &GameNight, game: &Match, player: PlayerId) -> serde_json::Value {
    let p = gn.player(player);
    json!({
        "name": p.map(|p| p.name.clone()),
        "color": p.and_then(|p| p.color.clone()),
        "score": game.scores.iter().find(|e| e.player == Some(player)).map_or(0, |e| e.stars),
        "seconds": game.clock.ceil() as u32,
        "results": game.in_results(),
    })
}

/// Each phone shows its own score and a dash button.
fn phone_updates(mut gn: ResMut<GameNight>, mut game: ResMut<Match>, time: Res<Time>) {
    if !gn.connected || !gn.is_running() {
        return;
    }
    game.phones_at -= time.delta_secs();
    if game.phones_at > 0.0 {
        return;
    }
    game.phones_at = 1.0;
    let ids: Vec<PlayerId> = gn.players.iter().map(|p| p.id).collect();
    for id in ids {
        let view = phone_view(&gn, &game, id);
        gn.companion_message(Some(id), view);
    }
}

fn music_volume(
    gn: Res<GameNight>,
    mut music: Query<&mut AudioSink, (With<Music>, Added<AudioSink>)>,
) {
    // A sink created while host music already plays starts muted too.
    for mut sink in &mut music {
        if gn.host_music_playing() {
            sink.set_volume(Volume::Linear(0.0));
        }
    }
}

/// `--shot file.png`: save a screenshot after two seconds of play and quit.
fn shot(
    mut commands: Commands,
    args: Res<Args>,
    time: Res<Time>,
    mut taken: Local<Option<f32>>,
    mut exit: MessageWriter<AppExit>,
) {
    let Some(path) = &args.shot else { return };
    let t = time.elapsed_secs();
    match *taken {
        None if t > 2.0 => {
            *taken = Some(t);
            commands
                .spawn(Screenshot::primary_window())
                .observe(save_to_disk(path.clone()));
        }
        Some(at) if std::path::Path::new(path).exists() || t > at + 20.0 => {
            exit.write(AppExit::Success);
        }
        _ => {}
    }
}
