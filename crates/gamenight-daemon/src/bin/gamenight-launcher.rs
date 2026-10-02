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

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let executable = std::env::current_exe()?;
    let executable_dir = executable.parent().ok_or("No package directory")?;
    #[cfg(target_os = "macos")]
    let root = executable_dir.join("../Resources").canonicalize()?;
    #[cfg(not(target_os = "macos"))]
    let root = executable_dir.to_path_buf();
    let args: Vec<String> = std::env::args().skip(1).collect();
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
        .filter(|_| requested.is_none())
        .map(|v| v.parse())
        .transpose()?
        .unwrap_or(7912);
    if port == 0 {
        return Err("Port must not be zero".into());
    }
    #[cfg(target_os = "macos")]
    let daemon = root.join("bin/gamenight-daemon");
    #[cfg(target_os = "macos")]
    let lobby = root
        .join("../Helpers/GameNight.app/Contents/MacOS/GameNight")
        .canonicalize()?;
    #[cfg(not(target_os = "macos"))]
    let daemon = root.join("bin/gamenight-daemon.exe");
    #[cfg(not(target_os = "macos"))]
    let lobby = root.join("bin/lobby.exe");
    let lobby_dir = root.join("lobby");
    for path in [&daemon, &lobby, &root.join("catalog/games/pinpals.json")] {
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
        if let Some(game) = requested {
            links::request(&local, game)?;
            return Ok(());
        }
        return Err("GameNight is already running".into());
    }
    drop(TcpListener::bind(("127.0.0.1", port))?);
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
    let mut shelf = serde_json::json!([
        {"id":"lobby", "title":"GameNight", "players":"1-4", "min_players":1, "max_players":4,
         "emoji":"", "color":"#7c5cff", "launch":{"command":lobby, "cwd":lobby_dir,
         "env":{"BEVY_ASSET_ROOT":lobby_dir}}}
    ]);
    data::merge_local_games(&mut shelf, &local)?;
    let shelf_path = local.join("shelf.json");
    fs::write(&shelf_path, serde_json::to_vec_pretty(&shelf)?)?;
    let mut command = Command::new(daemon);
    command
        .current_dir(&root)
        .env("GAMENIGHT_ADDR", format!("127.0.0.1:{port}"))
        .env("GAMENIGHT_LIBRARY", shelf_path)
        .env("GAMENIGHT_CATALOG", root.join("catalog/games"))
        .env("GAMENIGHT_INSTALL_DIR", local.join("games"))
        .env_remove("GAMENIGHT_NO_PREWARM")
        .env("GAMENIGHT_EXIT_WITH_LOBBY", "1")
        .env("GAMENIGHT_STARTUP_GATE", "1")
        .env("GAMENIGHT_WEB", "1")
        .env("GAMENIGHT_ONBOARDING_FILE", onboarding)
        .env("GAMENIGHT_BROWSER_REQUEST", &browser_request)
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
    updates.apply_on_exit();
    Ok(())
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
    if let Err(error) = run() {
        #[cfg(windows)]
        windows::show_error(&error.to_string());
        #[cfg(not(windows))]
        eprintln!("GameNight could not start or close: {error}");
        std::process::exit(1);
    }
}
