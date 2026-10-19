//! Desktop entry point for the Windows package and macOS app bundle.
#![cfg_attr(windows, windows_subsystem = "windows")]
#[path = "launcher/browser.rs"]
mod browser;
#[path = "launcher/data.rs"]
mod data;
#[path = "launcher/links.rs"]
mod links;
#[cfg(windows)]
#[path = "launcher/windows.rs"]
mod windows;
#[cfg(windows)]
use std::io;
use std::{
    fs,
    io::Write,
    net::TcpListener,
    process::{Command, Stdio},
};

/// What the launcher does once the host has stopped.
enum Next {
    Quit,
    /// The party is waiting in the resume file for the same version (a
    /// lobby switch, or an update that turned out not to be there).
    #[cfg_attr(not(windows), allow(dead_code))]
    Restart,
}

fn run(restart: bool) -> Result<Next, Box<dyn std::error::Error>> {
    let executable = std::env::current_exe()?;
    let executable_dir = executable.parent().ok_or("No package directory")?;
    #[cfg(target_os = "macos")]
    let root = executable_dir.join("../Resources").canonicalize()?;
    #[cfg(not(target_os = "macos"))]
    let root = executable_dir.to_path_buf();
    // A restart is a plain start: links and lobby requests were handled.
    let args: Vec<String> = if restart {
        Vec::new()
    } else {
        std::env::args().skip(1).collect()
    };
    let choose_lobby = args.first().is_some_and(|arg| arg == "--choose-lobby");
    let requested = if args.first().is_some_and(|arg| arg == "--open-url") {
        Some(
            links::game(args.get(1).ok_or("Missing GameNight link")?)
                .filter(|_| args.len() == 2)
                .ok_or("Invalid GameNight link")?,
        )
    } else {
        None
    };
    let port: u16 = args
        .first()
        .filter(|_| requested.is_none() && !choose_lobby)
        .map(|v| v.parse())
        .transpose()?
        .unwrap_or(7912);
    if port == 0 {
        return Err("Port must not be zero".into());
    }
    // The Game Room lobby: Godot running the exported Game Room pack. On
    // macOS it is a helper app, so it gets its own Dock entry and name.
    #[cfg(target_os = "macos")]
    let daemon = root.join("bin/gamenight-daemon");
    #[cfg(target_os = "macos")]
    let game_room = root
        .join("../Helpers/GameNight.app/Contents/Resources")
        .canonicalize()?;
    #[cfg(target_os = "macos")]
    let game_room_command = game_room.join("../MacOS/GameNight").canonicalize()?;
    // Name the pack: Godot's own lookup in the helper bundle's Resources
    // did not find it on CI, while an explicit pack always runs the game.
    #[cfg(target_os = "macos")]
    let game_room_pack = game_room.join("GameNight.pck");
    #[cfg(target_os = "macos")]
    let game_room_args = vec![
        "--main-pack".to_string(),
        game_room_pack.display().to_string(),
    ];
    #[cfg(not(target_os = "macos"))]
    let daemon = root.join("bin/gamenight-daemon.exe");
    #[cfg(not(target_os = "macos"))]
    let game_room = root.join("lobbies/game-room");
    #[cfg(not(target_os = "macos"))]
    let game_room_command = game_room.join("GameRoom.exe");
    // The editor runs the same-named GameRoom.pck next to it.
    #[cfg(not(target_os = "macos"))]
    let game_room_pack = game_room.join("GameRoom.pck");
    #[cfg(not(target_os = "macos"))]
    let game_room_args: Vec<String> = Vec::new();
    for path in [
        &daemon,
        &game_room_command,
        &game_room_pack,
        &root.join("catalog/games/blast-party.json"),
    ] {
        if !path.is_file() {
            return Err(format!("Missing package file: {}", path.display()).into());
        }
    }
    let local = data::user_dir()?;
    fs::create_dir_all(&local)?;
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(local.join("launcher.lock"))?;
    if lock.try_lock().is_err() {
        if choose_lobby {
            browser::open_lobby_settings()?;
            return Ok(Next::Quit);
        }
        if let Some(game) = requested {
            links::request(&local, game)?;
            return Ok(Next::Quit);
        }
        return Err("GameNight is already running".into());
    }
    port_free(port, restart)?;
    if let Err(error) = links::register() {
        eprintln!("GameNight links: {error}");
    }
    // Only a fresh installation asks the browser for a catalog choice. Keep
    // pending setup across interrupted launches; never reset an existing party.
    let onboarding = local.join("onboarding.json");
    if let Some(game) = requested {
        fs::write(
            &onboarding,
            serde_json::json!({"complete":false,"game":game}).to_string(),
        )?;
    }
    if !local.join("shelf.json").exists() && !onboarding.exists() {
        fs::write(&onboarding, b"{\"complete\":false}")?;
    }
    let browser_request = local.join("onboarding-browser.txt");
    match fs::remove_file(&browser_request) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    #[cfg(windows)]
    let updates = windows::Updates::start(&local);
    // Lobbies shipped in the package. The first one is the default lobby.
    let bundled_lobbies = local.join("bundled-lobbies.json");
    let mut shelf = serde_json::json!([
        {"id":"game-room", "title":"Game Room", "players":"1-8",
         "min_players":1, "max_players":8, "emoji":"", "color":"#7c5cff",
         "launch":{"command":game_room_command, "args":game_room_args, "cwd":game_room,
                   "env":{"GAMENIGHT_LOBBY_API":"1"}}}
    ]);
    fs::write(&bundled_lobbies, serde_json::to_vec_pretty(&shelf)?)?;
    data::merge_local_games(&mut shelf, &local)?;
    let lobby_config = local.join("selected-lobby.json");
    let registrations = local.join("local-games.json");
    let lobby_id = gamenight_local_web::host_lobby::selected(
        &lobby_config,
        &registrations,
        Some(&bundled_lobbies),
    )
    .ok_or("The bundled Game Room lobby is not runnable")?
    .id
    .0;
    shelf
        .as_array_mut()
        .unwrap()
        .retain(|v| v["id"] == lobby_id || v["launch"]["env"]["GAMENIGHT_LOBBY_API"] != "1");

    let shelf_path = local.join("shelf.json");
    fs::write(&shelf_path, serde_json::to_vec_pretty(&shelf)?)?;
    // Keep the previous session's logs: a restart (an update, a crash) is
    // usually exactly when someone needs to read what happened before it.
    for name in ["daemon", "daemon-errors"] {
        let _ = fs::rename(
            local.join(format!("{name}.log")),
            local.join(format!("{name}.prev.log")),
        );
    }
    let mut command = Command::new(daemon);
    command
        .current_dir(&root)
        .env("GAMENIGHT_ADDR", format!("127.0.0.1:{port}"))
        .env("GAMENIGHT_LIBRARY", shelf_path)
        .env("GAMENIGHT_CATALOG", root.join("catalog/games"))
        .env("GAMENIGHT_INSTALL_DIR", local.join("games"))
        .env(
            "GAMENIGHT_PUBLISHED_CATALOG",
            local.join("published-catalog.json"),
        )
        .env(
            "GAMENIGHT_CATALOG_FEED",
            std::env::var("GAMENIGHT_CATALOG_FEED")
                .unwrap_or_else(|_| "https://gamenight.ontola.io/v1/game-catalog".into()),
        )
        .env_remove("GAMENIGHT_NO_PREWARM")
        .env("GAMENIGHT_EXIT_WITH_LOBBY", "1")
        .env("GAMENIGHT_STARTUP_GATE", "1")
        .env("GAMENIGHT_WEB", "1")
        .env("GAMENIGHT_LOBBY_GAME", &lobby_id)
        .env("GAMENIGHT_LOBBY_CONFIG", &lobby_config)
        .env("GAMENIGHT_LOCAL_GAMES", &registrations)
        .env("GAMENIGHT_BUNDLED_LOBBIES", &bundled_lobbies)
        .env("GAMENIGHT_ONBOARDING_FILE", onboarding)
        .env("GAMENIGHT_BROWSER_REQUEST", &browser_request)
        .env_remove("GAMENIGHT_UPDATE_READY_FILE")
        .env_remove("GAMENIGHT_RESUME_FILE")
        .env_remove("GAMENIGHT_UPDATE_SPLASH_FILE")
        .stdin(Stdio::piped())
        .env("RUST_LOG", "info")
        .stdout(fs::File::create(local.join("daemon.log"))?)
        .stderr(fs::File::create(local.join("daemon-errors.log"))?);
    for key in [
        "GAMENIGHT",
        "GAMENIGHT_GAME_ID",
        "GAMENIGHT_TOKEN",
        "GAMENIGHT_NO_LOBBY_WATCH",
    ] {
        command.env_remove(key);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000); // CREATE_NO_WINDOW
        let files = updates.files();
        command
            .env("GAMENIGHT_UPDATE_READY_FILE", &files.ready)
            .env("GAMENIGHT_RESUME_FILE", &files.resume)
            .env("GAMENIGHT_UPDATE_SPLASH_FILE", &files.splash);
    }
    let mut child = command.spawn()?;
    #[cfg(windows)]
    let job = match windows::ProcessTree::attach(&child) {
        Ok(job) => job,
        Err(error) => {
            stop_tree(&mut child)?;
            return Err(error.into());
        }
    };
    child
        .stdin
        .take()
        .ok_or("Missing startup pipe")?
        .write_all(&[1])?;
    let browser = browser::Worker::start(browser_request);
    if choose_lobby {
        std::thread::spawn(|| {
            for _ in 0..100 {
                if std::net::TcpStream::connect(("127.0.0.1", gamenight_protocol::DEFAULT_WEB_PORT))
                    .is_ok()
                {
                    let _ = browser::open_lobby_settings();
                    return;
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        });
    }
    let status = child.wait();
    drop(browser);
    #[cfg(windows)]
    job.close()?; // No hidden game or descendant may survive into an update.
    if !status?.success() {
        return Err(format!(
            "The GameNight host stopped unexpectedly. See {}",
            local.join("daemon-errors.log").display()
        )
        .into());
    }
    #[cfg(windows)]
    if updates.files().resume.exists() {
        // The party asked for the new version or another lobby, and is
        // waiting for it.
        let splash = updates.files().splash.clone();
        let lobby = fs::read(&updates.files().resume)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
            .and_then(|resume| resume["lobby"].as_str().map(str::to_owned));
        let restarted = match &lobby {
            Some(title) => {
                updates.restart_for_lobby(title);
                false
            }
            None => updates.restart_into_update(),
        };
        if !restarted {
            // A plain restart: cover the desktop until the lobby is back,
            // and start the host again from this process. A second launcher
            // would race this one for the lock and port, and fail unseen.
            let text = match lobby {
                Some(title) => format!("Opening {title}\u{2026}"),
                None => "Restarting GameNight\u{2026}".into(),
            };
            let _ = windows::spawn_splash(&splash, &text);
            return Ok(Next::Restart);
        }
        return Ok(Next::Quit);
    }
    #[cfg(windows)]
    updates.apply_on_exit();
    Ok(Next::Quit)
}

/// The host's port must be free. Right after a restart the previous host
/// may still be letting go of it, so give it a moment then.
fn port_free(port: u16, restart: bool) -> std::io::Result<()> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    loop {
        match TcpListener::bind(("127.0.0.1", port)) {
            Ok(_) => return Ok(()),
            Err(error) if !restart || std::time::Instant::now() >= deadline => return Err(error),
            Err(_) => std::thread::sleep(std::time::Duration::from_millis(250)),
        }
    }
}

#[cfg(windows)]
fn stop_tree(child: &mut std::process::Child) -> io::Result<()> {
    // Before the startup pipe is released, this child cannot have descendants.
    if child.try_wait()?.is_none() {
        child.kill()?;
        child.wait()?;
    }
    Ok(())
}

fn main() {
    // A copy of this executable covering the screen during an update.
    #[cfg(windows)]
    if std::env::args().nth(1).as_deref() == Some("--update-cover") {
        if let Some(flag) = std::env::args_os().nth(2) {
            let text = std::env::args()
                .nth(3)
                .unwrap_or_else(|| "Updating GameNight\u{2026}".into());
            windows::show_update_cover(flag.into(), text);
        }
        return;
    }
    #[cfg(windows)]
    velopack::VelopackApp::build()
        .set_auto_apply_on_startup(false)
        .on_after_install_fast_callback(|_| {
            let _ = links::register();
        })
        .on_after_update_fast_callback(|_| {
            let _ = links::register();
        })
        .on_before_uninstall_fast_callback(|_| {
            let _ = links::unregister();
        })
        .run();
    let mut restart = false;
    let result = loop {
        match run(restart) {
            Ok(Next::Quit) => break Ok(()),
            Ok(Next::Restart) => restart = true,
            Err(error) => break Err(error),
        }
    };
    if let Err(error) = result {
        // Never leave a restart cover hiding the error.
        #[cfg(windows)]
        if let Ok(local) = data::user_dir() {
            let _ = fs::remove_file(windows::UpdateFiles::new(&local).splash);
        }
        #[cfg(windows)]
        windows::show_error(&error.to_string());
        #[cfg(not(windows))]
        eprintln!("GameNight could not start or close: {error}");
        std::process::exit(1);
    }
}
