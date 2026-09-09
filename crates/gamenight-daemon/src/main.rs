use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> std::io::Result<()> {
    // The desktop launcher attaches us to its Windows job before allowing any
    // descendants to spawn. EOF means the launcher failed before ownership was set.
    if std::env::var_os("GAMENIGHT_STARTUP_GATE").is_some() {
        use std::io::Read;
        let mut signal = [0];
        std::io::stdin().read_exact(&mut signal)?;
        if signal != [1] {
            return Err(std::io::Error::other("Invalid startup signal"));
        }
    }
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let addr = std::env::args()
        .nth(1)
        .or_else(|| std::env::var("GAMENIGHT_ADDR").ok())
        .unwrap_or_else(|| gamenight_protocol::DEFAULT_ADDR.to_string());

    // A shipped application has its lobby inside it, so that's the shelf it
    // starts from — the demo shelf is a development convenience and its
    // entries (TowerFall, Duck Game) aren't games we can actually launch.
    let mut library = match std::env::var("GAMENIGHT_LIBRARY") {
        Ok(path) => gamenight_daemon::load_library(&path)?,
        Err(_) => match gamenight_daemon::bundled_lobby_meta() {
            Some(lobby) => vec![lobby],
            None => gamenight_daemon::demo_library(),
        },
    };

    let mut prewarm_handle = None;
    let mut install_progress = None;
    if std::env::var_os("GAMENIGHT_NO_PREWARM").is_none() {
        let root = gamenight_installer::install_dir();
        let catalog_dir = gamenight_catalog::catalog_dir();
        if catalog_dir.is_dir() {
            // Fast, local-only: anything already installed from a previous
            // run joins the shelf immediately, playable tonight. An explicit
            // GAMENIGHT_LIBRARY entry for the same id always wins — the
            // catalogue only fills gaps.
            let known: std::collections::HashSet<_> =
                library.iter().map(|m| m.id.clone()).collect();
            if let Ok(entries) = gamenight_catalog::load_dir(&catalog_dir) {
                for entry in &entries {
                    if known.contains(&gamenight_protocol::GameId::new(&entry.id)) {
                        continue;
                    }
                    if let Some(installed) =
                        gamenight_installer::already_installed(entry, &root).await
                    {
                        tracing::info!(
                            game = %entry.id,
                            executable = %installed.executable.display(),
                            "catalogue install joined the shelf"
                        );
                        library.push(gamenight_installer::game_meta(entry, &installed));
                    }
                }
            }
            // Anything not yet installed downloads in the background and joins
            // the shelf immediately through the install progress pump.
            // The handle lets the running party bump a game to the front of
            // that queue the moment it's wanted, instead of waiting for
            // catalogue order to get there.
            let (handle, signals) = gamenight_installer::prewarm_channel();
            let (reporter, progress) = gamenight_installer::progress_channel();
            tokio::spawn(async move {
                gamenight_installer::prewarm_all_reporting(
                    &catalog_dir,
                    &root,
                    Some(signals),
                    Some(reporter),
                )
                .await;
            });
            prewarm_handle = Some(handle);
            install_progress = Some(progress);
        }
    }

    // Which game IS the couch: pressing Back/Select with nothing else
    // running launches this one. `GAMENIGHT_NO_LOBBY_WATCH` opts out
    // entirely (e.g. running headless/in CI, or with no controller to watch).
    let lobby_game = std::env::var_os("GAMENIGHT_NO_LOBBY_WATCH")
        .is_none()
        .then(|| {
            gamenight_protocol::GameId::new(
                std::env::var("GAMENIGHT_LOBBY_GAME").unwrap_or_else(|_| "lobby".to_string()),
            )
        });

    // Optional LAN character studio. Local games do not require an HTTP server.
    if std::env::var_os("GAMENIGHT_WEB").is_some() {
        let web_daemon_addr = addr.clone();
        tokio::spawn(async move {
            let state = std::sync::Arc::new(std::sync::Mutex::new(
                gamenight_local_web::ServerState::new(web_daemon_addr),
            ));
            // All interfaces, not loopback: phones on the same network have to
            // be able to reach the join pages.
            let server_addr =
                std::net::SocketAddr::from(([0, 0, 0, 0], gamenight_protocol::DEFAULT_WEB_PORT));
            let _ = gamenight_local_web::run_server(server_addr, state).await;
        });
    }

    let listener = TcpListener::bind(&addr).await?;
    if std::env::var_os("GAMENIGHT_EXIT_WITH_LOBBY").is_some() {
        let lobby =
            lobby_game.ok_or_else(|| std::io::Error::other("Desktop mode requires a lobby"))?;
        return gamenight_daemon::run_desktop(
            listener,
            library,
            lobby,
            prewarm_handle,
            install_progress,
        )
        .await;
    }
    gamenight_daemon::run_with_prewarm_progress(
        listener,
        library,
        lobby_game,
        prewarm_handle,
        install_progress,
    )
    .await
}
