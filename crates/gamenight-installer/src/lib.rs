//! Background installer for the catalogue's free, directly-downloadable
//! games — the daemon's answer to "I want to play SuperTuxKart" without a
//! store client, an account, or a click. [`prewarm_all`] walks the
//! catalogue, finds everything [`gamenight_catalog::CatalogEntry::auto_download_here`]
//! says is eligible, and fetches it: streamed download, sha256 verified
//! against the catalogue entry, extracted, done — or skipped instantly if
//! it's already there.
//!
//! Each install resolves to a real [`LaunchSpec`](gamenight_protocol::LaunchSpec)
//! via [`InstalledGame::launch_spec`] and [`game_meta`], using the catalogue
//! entry's `entrypoint` — the file inside the download that's actually
//! runnable. The daemon decides what to do with that; this crate's job ends
//! at "verified, extracted, launchable."
//!
//! The queue is live-reorderable: [`prewarm_channel`] hands out a
//! [`PrewarmHandle`] the daemon can call `.prioritize(game)` on when the
//! party wants to warm something that isn't installed yet, jumping it ahead
//! of whatever else `prewarm_all` was going to fetch next.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};

use futures_util::StreamExt;
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use tokio::sync::mpsc;
use tracing::{info, warn};

use gamenight_catalog::CatalogEntry;
use gamenight_protocol::{GameId, GameMeta, InstallState, InstallStatus, LaunchSpec};

/// Where install progress goes. The daemon feeds these straight into the
/// party state machine, so the lobby can show a game arriving before it is
/// playable; the standalone CLI passes `None` and prints its own summary.
pub type InstallReporter = mpsc::UnboundedSender<InstallStatus>;

/// An [`InstallReporter`]/receiver pair. Unbounded because dropping a
/// progress report to apply backpressure to a download would be the wrong
/// trade — the reports are small, and the state machine dedupes them anyway.
pub fn progress_channel() -> (InstallReporter, mpsc::UnboundedReceiver<InstallStatus>) {
    mpsc::unbounded_channel()
}

/// One game's progress sink, bound to its identity so call sites pass a
/// state and not five fields. A `None` reporter makes every `report` a no-op,
/// which is what keeps the reporting optional without `if let` at each step.
struct Progress<'a> {
    reporter: Option<&'a InstallReporter>,
    game: GameId,
    title: String,
}

impl Progress<'_> {
    fn report(&self, state: InstallState, percent: Option<u8>, label: Option<String>) {
        let Some(tx) = self.reporter else { return };
        // A closed receiver means the daemon is gone; the install itself is
        // still worth finishing, so this is deliberately not an error.
        let _ = tx.send(InstallStatus {
            game: self.game.clone(),
            title: self.title.clone(),
            state,
            percent,
            label,
        });
    }
}

#[derive(Debug, thiserror::Error)]
pub enum InstallError {
    #[error("not eligible for background install (paid, or no direct download for this platform)")]
    NotEligible,
    #[error("download failed: {0}")]
    Http(String),
    #[error("sha256 mismatch: catalogue says {expected}, downloaded file is {got}")]
    HashMismatch { expected: String, got: String },
    #[error("could not extract archive: {0}")]
    Extract(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(serde::Serialize, serde::Deserialize)]
struct Marker {
    sha256: String,
    url: String,
}

/// A verified, extracted install: where it lives, and what to run.
#[derive(Debug)]
pub struct InstalledGame {
    pub dir: PathBuf,
    pub executable: PathBuf,
}

impl InstalledGame {
    /// A [`LaunchSpec`] the daemon can hand straight to
    /// [`tokio::process::Command`]: absolute executable path, working
    /// directory set to the install dir (so a game's relative asset paths
    /// resolve).
    pub fn launch_spec(&self) -> LaunchSpec {
        LaunchSpec {
            command: self.executable.display().to_string(),
            args: Vec::new(),
            cwd: Some(self.dir.display().to_string()),
            env: Default::default(),
        }
    }
}

/// The full shelf entry for a freshly (or previously) installed game —
/// everything the daemon's library needs to make it playable.
pub fn game_meta(entry: &CatalogEntry, installed: &InstalledGame) -> GameMeta {
    GameMeta {
        id: GameId::new(&entry.id),
        title: entry.title.clone(),
        tagline: entry.tagline.clone(),
        cover: entry.cover.clone(),
        color: entry.color.clone(),
        emoji: entry.emoji.clone(),
        players: Some(match entry.players.best {
            Some(best) => format!("{}–{} ({best})", entry.players.min, entry.players.max),
            None => format!("{}–{}", entry.players.min, entry.players.max),
        }),
        // The catalogue already validates these (min >= 1, max >= min, best
        // within range), so carry them through structured rather than making
        // the daemon parse the display string back apart.
        min_players: Some(entry.players.min),
        max_players: Some(entry.players.max),
        best_players: entry.players.best,
        launch: Some(installed.launch_spec()),
    }
}

/// One game's prewarm result, for reporting.
pub struct PrewarmResult {
    pub game: String,
    pub outcome: Result<InstalledGame, InstallError>,
}

/// Root data directory for installed games: `<OS data dir>/gamenight/games`.
/// Hand-rolled rather than pulling in a directories crate for three `cfg`
/// branches.
///
/// - Linux: `$XDG_DATA_HOME` or `~/.local/share`
/// - macOS: `~/Library/Application Support`
/// - Windows: `%APPDATA%`
pub fn install_dir() -> PathBuf {
    let base = if cfg!(target_os = "windows") {
        std::env::var_os("APPDATA").map(PathBuf::from)
    } else if cfg!(target_os = "macos") {
        std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Application Support"))
    } else {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
    };
    base.unwrap_or_else(|| PathBuf::from("."))
        .join("gamenight")
        .join("games")
}

/// The path an [`InstalledGame`] resolves to: the declared `entrypoint` for
/// an archive, or (for a bare-binary download) the file the URL names.
fn resolve_executable(dl: &gamenight_catalog::Download, game_dir: &Path) -> PathBuf {
    match &dl.entrypoint {
        Some(entrypoint) => game_dir.join(entrypoint),
        None => game_dir.join(binary_name(&dl.url)),
    }
}

fn binary_name(url: &str) -> &str {
    url.rsplit('/')
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or("game")
}

/// If `entry` is already installed and verified under `root` (a prior
/// [`ensure_installed`] with the same sha256), return it — synchronous,
/// local-disk-only, no network. Used at daemon startup to make already-warm
/// games playable immediately, before the (possibly slow) background
/// prewarm pass even starts.
pub async fn already_installed(entry: &CatalogEntry, root: &Path) -> Option<InstalledGame> {
    let dl = entry.auto_download_here()?;
    let game_dir = root.join(&entry.id);
    let marker_path = game_dir.join(".gamenight-install.json");
    let text = tokio::fs::read_to_string(&marker_path).await.ok()?;
    let marker: Marker = serde_json::from_str(&text).ok()?;
    if !marker.sha256.eq_ignore_ascii_case(&dl.sha256) {
        return None;
    }
    Some(InstalledGame {
        executable: resolve_executable(dl, &game_dir),
        dir: game_dir,
    })
}

/// Ensure `entry`'s direct download for this platform is present and
/// verified under `root`. Idempotent — a second call for the same entry and
/// sha256 does no network I/O.
pub async fn ensure_installed(
    entry: &CatalogEntry,
    root: &Path,
) -> Result<InstalledGame, InstallError> {
    ensure_installed_reporting(entry, root, None).await
}

/// [`ensure_installed`], reporting each step to `reporter` as it goes. The
/// daemon uses this one; the plain version is the same call with no sink.
pub async fn ensure_installed_reporting(
    entry: &CatalogEntry,
    root: &Path,
    reporter: Option<&InstallReporter>,
) -> Result<InstalledGame, InstallError> {
    let progress = Progress {
        reporter,
        game: GameId::new(&entry.id),
        title: entry.title.clone(),
    };
    let result = install_inner(entry, root, &progress).await;
    match &result {
        Ok(_) => progress.report(InstallState::Installed, None, None),
        // The party needs to know whether to wait or pick something else, so
        // the reason travels with the state rather than only reaching the log.
        Err(e) => progress.report(InstallState::Failed, None, Some(e.to_string())),
    }
    result
}

async fn install_inner(
    entry: &CatalogEntry,
    root: &Path,
    progress: &Progress<'_>,
) -> Result<InstalledGame, InstallError> {
    let dl = entry
        .auto_download_here()
        .ok_or(InstallError::NotEligible)?;
    let game_dir = root.join(&entry.id);

    if let Some(installed) = already_installed(entry, root).await {
        return Ok(installed);
    }

    tokio::fs::create_dir_all(root).await?;
    let download_path = root.join(format!(".{}.download", entry.id));
    info!(game = %entry.id, url = %dl.url, "downloading");
    let result = download_and_verify(&dl.url, &dl.sha256, &download_path, progress).await;
    let downloaded = match result {
        Ok(()) => &download_path,
        Err(e) => {
            let _ = tokio::fs::remove_file(&download_path).await;
            return Err(e);
        }
    };

    progress.report(InstallState::Extracting, None, None);
    // Stale contents from a previous version get replaced wholesale.
    let _ = tokio::fs::remove_dir_all(&game_dir).await;
    tokio::fs::create_dir_all(&game_dir).await?;
    let dl_owned = dl.clone();
    let extract_dest = game_dir.clone();
    let extract_src = downloaded.clone();
    tokio::task::spawn_blocking(move || extract(&dl_owned, &extract_src, &extract_dest))
        .await
        .map_err(|e| InstallError::Extract(e.to_string()))??;
    let _ = tokio::fs::remove_file(&download_path).await;

    let marker_path = game_dir.join(".gamenight-install.json");
    let marker = serde_json::to_string(&Marker {
        sha256: dl.sha256.clone(),
        url: dl.url.clone(),
    })
    .expect("Marker is always serializable");
    tokio::fs::write(&marker_path, marker).await?;
    info!(game = %entry.id, dir = %game_dir.display(), "installed");
    Ok(InstalledGame {
        executable: resolve_executable(dl, &game_dir),
        dir: game_dir,
    })
}

/// Something the party learned that should change what downloads next.
/// Constructed via [`PrewarmHandle`] rather than directly.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrewarmSignal {
    /// Somebody wants this specific game now.
    Prioritize(String),
    /// This many people are on the couch.
    Players(u8),
}

/// A live handle into a running [`prewarm_all`]: lets the daemon reorder the
/// remaining download queue as the evening develops — the party asked for a
/// game that isn't installed, or a fourth person picked up a controller.
#[derive(Clone)]
pub struct PrewarmHandle {
    tx: mpsc::UnboundedSender<PrewarmSignal>,
}

impl PrewarmHandle {
    /// Ask the background prewarm to fetch `game` next, ahead of whatever
    /// else is still queued. A no-op once the queue has already passed it —
    /// installed, failed, or never eligible — reordering only affects work
    /// that hasn't started yet. An in-flight download always finishes
    /// rather than being thrown away half-fetched (no HTTP range support to
    /// resume it later).
    pub fn prioritize(&self, game: impl Into<String>) {
        let _ = self.tx.send(PrewarmSignal::Prioritize(game.into()));
    }

    /// Tell the prewarm how many people are actually playing, so the rest of
    /// the queue reorders toward games that seat them (see
    /// [`suitability`]). Safe to call on every seat change: an unchanged
    /// count reorders nothing, and a changed one only affects what hasn't
    /// started downloading yet.
    pub fn set_players(&self, players: u8) {
        let _ = self.tx.send(PrewarmSignal::Players(players));
    }
}

/// A [`PrewarmHandle`]/receiver pair for [`prewarm_all`]. Split out so the
/// handle can be handed to the daemon before the (possibly long-running)
/// prewarm future is even spawned.
pub fn prewarm_channel() -> (PrewarmHandle, mpsc::UnboundedReceiver<PrewarmSignal>) {
    let (tx, rx) = mpsc::unbounded_channel();
    (PrewarmHandle { tx }, rx)
}

/// How well `entry` seats `players`, lower being better — the sort key that
/// decides what a party of three downloads first.
///
/// Deliberately coarse: three tiers, not a continuous score. A finer ranking
/// would keep reshuffling the queue on every seat change for differences
/// nobody on the couch can perceive, and the only distinction that actually
/// matters is "can we all play this at all".
fn suitability(entry: &CatalogEntry, players: u8) -> u8 {
    let (min, max) = (entry.players.min, entry.players.max);
    match () {
        // The game's own idea of its best count — a 4-player party gets
        // 4-player games before 2-player ones it merely tolerates.
        _ if entry.players.best == Some(players) => 0,
        _ if (min..=max).contains(&players) => 1,
        // Still fetched, just last: player counts change all evening, and a
        // game nobody can play right now may be exactly right in ten minutes.
        _ => 2,
    }
}

/// Every catalogue entry that's [`auto_download_here`](CatalogEntry::auto_download_here)-eligible,
/// installed one at a time — deliberately sequential, so a background
/// prewarm never saturates the household's bandwidth or disk I/O the way a
/// fan-out would. Bad entries fail loudly (returned per-game, logged) but
/// never abort the rest of the run.
///
/// `priority` (from [`prewarm_channel`]) lets a caller reorder what's left
/// in the queue while this runs; pass `None` for a plain, catalogue-order
/// run (e.g. the standalone CLI).
pub async fn prewarm_all(
    catalog_dir: &Path,
    root: &Path,
    signals: Option<mpsc::UnboundedReceiver<PrewarmSignal>>,
) -> Vec<PrewarmResult> {
    prewarm_all_reporting(catalog_dir, root, signals, None).await
}

/// [`prewarm_all`], reporting every step of every install to `reporter` —
/// what the daemon runs, so the lobby can show games arriving.
pub async fn prewarm_all_reporting(
    catalog_dir: &Path,
    root: &Path,
    mut signals: Option<mpsc::UnboundedReceiver<PrewarmSignal>>,
    reporter: Option<InstallReporter>,
) -> Vec<PrewarmResult> {
    let entries = match gamenight_catalog::load_dir(catalog_dir) {
        Ok(e) => e,
        Err(problems) => {
            warn!(?problems, "catalogue invalid, skipping prewarm");
            return Vec::new();
        }
    };
    let mut queue: VecDeque<CatalogEntry> = entries
        .into_iter()
        .filter(|e| e.auto_download_here().is_some())
        .collect();
    if queue.is_empty() {
        return Vec::new();
    }
    info!(count = queue.len(), "prewarming eligible games");

    // Announce the whole queue up front. A party that can see three games
    // waiting behind the one downloading knows the evening is filling itself
    // in, which an empty screen until the first install lands does not say.
    if let Some(tx) = &reporter {
        for entry in &queue {
            let _ = tx.send(InstallStatus {
                game: GameId::new(&entry.id),
                title: entry.title.clone(),
                state: InstallState::Queued,
                percent: None,
                label: None,
            });
        }
    }

    let mut results = Vec::with_capacity(queue.len());
    while !queue.is_empty() {
        if let Some(rx) = &mut signals {
            apply_signals(&mut queue, rx);
        }
        let entry = queue.pop_front().expect("checked not empty");
        let outcome = ensure_installed_reporting(&entry, root, reporter.as_ref()).await;
        if let Err(e) = &outcome {
            warn!(game = %entry.id, error = %e, "prewarm failed");
        }
        results.push(PrewarmResult {
            game: entry.id.clone(),
            outcome,
        });
    }
    results
}

/// Drain every pending signal and reorder what's left.
///
/// Player count is applied first and an explicit request second, so a game
/// somebody actually asked for always ends up at the front — a direct request
/// is evidence about what this party wants that beats any inference from how
/// many of them are sitting down.
fn apply_signals(
    queue: &mut VecDeque<CatalogEntry>,
    rx: &mut mpsc::UnboundedReceiver<PrewarmSignal>,
) {
    let mut bumps = Vec::new();
    let mut players = None;
    while let Ok(signal) = rx.try_recv() {
        match signal {
            PrewarmSignal::Prioritize(game) => bumps.push(game),
            PrewarmSignal::Players(n) => players = Some(n),
        }
    }

    if let Some(players) = players.filter(|n| *n > 0) {
        // Stable, so games that seat the party equally well keep catalogue
        // order rather than shuffling on every seat change.
        queue
            .make_contiguous()
            .sort_by_key(|e| suitability(e, players));
        info!(players, "prewarm: reordered for the party's size");
    }

    // Last request wins the front slot, so apply them in order.
    for game in bumps {
        if let Some(pos) = queue.iter().position(|e| e.id == game) {
            let bumped = queue.remove(pos).expect("position just found");
            queue.push_front(bumped);
            info!(game, "prewarm: bumped to the front of the queue");
        }
    }
}

async fn download_and_verify(
    url: &str,
    expected_sha256: &str,
    dest: &Path,
    progress: &Progress<'_>,
) -> Result<(), InstallError> {
    let resp = reqwest::get(url)
        .await
        .map_err(|e| InstallError::Http(e.to_string()))?;
    if !resp.status().is_success() {
        return Err(InstallError::Http(format!(
            "HTTP {} fetching {url}",
            resp.status()
        )));
    }
    // Without a Content-Length there is no honest percentage to show, so the
    // state carries the download with no bar rather than inventing one.
    let total = resp.content_length();
    progress.report(InstallState::Downloading, total.map(|_| 0), None);

    let mut file = tokio::fs::File::create(dest).await?;
    let mut hasher = Sha256::new();
    let mut stream = resp.bytes_stream();
    let mut received: u64 = 0;
    let mut last_percent = 0u8;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| InstallError::Http(e.to_string()))?;
        hasher.update(&chunk);
        file.write_all(&chunk).await?;

        received += chunk.len() as u64;
        // Report on whole-percent changes only: chunks arrive far faster than
        // any screen redraws, and every report costs a full state broadcast.
        if let Some(total) = total.filter(|t| *t > 0) {
            let percent = ((received.min(total) * 100) / total) as u8;
            if percent > last_percent {
                last_percent = percent;
                progress.report(InstallState::Downloading, Some(percent), None);
            }
        }
    }
    file.flush().await?;
    drop(file);

    progress.report(InstallState::Verifying, None, None);
    let got = hex(&hasher.finalize());
    if !got.eq_ignore_ascii_case(expected_sha256) {
        return Err(InstallError::HashMismatch {
            expected: expected_sha256.to_ascii_lowercase(),
            got,
        });
    }
    Ok(())
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    bytes
        .iter()
        .fold(String::with_capacity(bytes.len() * 2), |mut s, b| {
            let _ = write!(s, "{b:02x}");
            s
        })
}

/// Extract a verified download into `dest`. Uses [`Download::is_archive`] to
/// decide: `.tar.gz`/`.tgz` and `.zip` are unpacked (the entrypoint validated
/// by `gamenight-catalog` is what `resolve_executable` will point at
/// afterwards); anything else is assumed to already be the runnable artifact
/// (a bare binary or AppImage) and is placed as-is, executable bit set on
/// Unix.
fn extract(
    dl: &gamenight_catalog::Download,
    downloaded: &Path,
    dest: &Path,
) -> Result<(), InstallError> {
    if !dl.is_archive() {
        let target = dest.join(binary_name(&dl.url));
        std::fs::copy(downloaded, &target)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&target)?.permissions();
            perms.set_mode(perms.mode() | 0o111);
            std::fs::set_permissions(&target, perms)?;
        }
        return Ok(());
    }
    let lower = dl.url.to_ascii_lowercase();
    if lower.ends_with(".tar.gz") || lower.ends_with(".tgz") {
        let file = std::fs::File::open(downloaded)?;
        let gz = flate2::read::GzDecoder::new(file);
        tar::Archive::new(gz)
            .unpack(dest)
            .map_err(|e| InstallError::Extract(e.to_string()))?;
    } else if lower.ends_with(".zip") {
        let file = std::fs::File::open(downloaded)?;
        let mut zip =
            zip::ZipArchive::new(file).map_err(|e| InstallError::Extract(e.to_string()))?;
        zip.extract(dest)
            .map_err(|e| InstallError::Extract(e.to_string()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_matches_known_sha256() {
        // sha256("") — the canonical empty-input test vector.
        let digest = Sha256::digest(b"");
        assert_eq!(
            hex(&digest),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[tokio::test]
    async fn ensure_installed_rejects_ineligible_entries() {
        let entry: CatalogEntry = serde_json::from_value(serde_json::json!({
            "id": "paid-thing", "title": "T",
            "players": { "min": 1, "max": 4 },
            "price": "paid",
            "integration": { "level": "planned" },
            "links": { "steam": "https://store.steampowered.com/app/1" }
        }))
        .unwrap();
        let tmp = tmp_dir("ineligible");
        let err = ensure_installed(&entry, &tmp).await.unwrap_err();
        assert!(matches!(err, InstallError::NotEligible));
    }

    fn tmp_dir(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "gamenight-installer-test-{name}-{}",
            std::process::id()
        ))
    }

    fn bare_binary_entry(id: &str, sha256: &str) -> CatalogEntry {
        let mut downloads = serde_json::Map::new();
        downloads.insert(
            gamenight_catalog::current_platform().to_string(),
            serde_json::json!({ "url": "https://example.com/game-bin", "sha256": sha256 }),
        );
        serde_json::from_value(serde_json::json!({
            "id": id, "title": "T",
            "players": { "min": 1, "max": 4, "best": 2 },
            "price": "free",
            "integration": { "level": "planned" },
            "downloads": downloads
        }))
        .unwrap()
    }

    #[tokio::test]
    async fn already_installed_matches_a_verified_marker() {
        let entry = bare_binary_entry("marker-match", &"a".repeat(64));
        let root = tmp_dir("marker-match");
        let game_dir = root.join(&entry.id);
        tokio::fs::create_dir_all(&game_dir).await.unwrap();
        tokio::fs::write(
            game_dir.join(".gamenight-install.json"),
            serde_json::json!({ "sha256": "a".repeat(64), "url": "https://example.com/game-bin" })
                .to_string(),
        )
        .await
        .unwrap();

        let installed = already_installed(&entry, &root)
            .await
            .expect("marker matches");
        assert_eq!(installed.dir, game_dir);
        assert_eq!(installed.executable, game_dir.join("game-bin"));

        tokio::fs::remove_dir_all(&root).await.unwrap();
    }

    #[tokio::test]
    async fn already_installed_ignores_a_stale_marker() {
        let entry = bare_binary_entry("marker-stale", &"a".repeat(64));
        let root = tmp_dir("marker-stale");
        let game_dir = root.join(&entry.id);
        tokio::fs::create_dir_all(&game_dir).await.unwrap();
        tokio::fs::write(
            game_dir.join(".gamenight-install.json"),
            serde_json::json!({ "sha256": "b".repeat(64), "url": "https://example.com/game-bin" })
                .to_string(),
        )
        .await
        .unwrap();

        assert!(already_installed(&entry, &root).await.is_none());

        tokio::fs::remove_dir_all(&root).await.unwrap();
    }

    #[test]
    fn game_meta_carries_the_launch_spec() {
        let entry = bare_binary_entry("meta-check", &"a".repeat(64));
        let installed = InstalledGame {
            dir: PathBuf::from("/data/meta-check"),
            executable: PathBuf::from("/data/meta-check/game-bin"),
        };
        let meta = game_meta(&entry, &installed);
        assert_eq!(meta.id, GameId::new("meta-check"));
        assert_eq!(meta.players.as_deref(), Some("1–4 (2)"));
        let launch = meta
            .launch
            .expect("installed games always have a launch spec");
        assert_eq!(launch.command, "/data/meta-check/game-bin");
        assert_eq!(launch.cwd.as_deref(), Some("/data/meta-check"));
    }

    /// A catalogue entry that seats exactly `min..=max`, `best` players.
    fn seating(id: &str, min: u8, max: u8, best: Option<u8>) -> CatalogEntry {
        let mut downloads = serde_json::Map::new();
        downloads.insert(
            gamenight_catalog::current_platform().to_string(),
            serde_json::json!({ "url": "https://example.com/g", "sha256": "a".repeat(64) }),
        );
        serde_json::from_value(serde_json::json!({
            "id": id, "title": "T",
            "players": { "min": min, "max": max, "best": best },
            "price": "free",
            "integration": { "level": "planned" },
            "downloads": downloads
        }))
        .unwrap()
    }

    #[test]
    fn suitability_prefers_the_games_own_best_count() {
        let four_player = seating("four", 2, 4, Some(4));
        let duel = seating("duel", 2, 2, Some(2));
        let solo = seating("solo", 1, 1, Some(1));

        // Four on the couch: the game built for four wins, the one that
        // merely tolerates them comes next, the one that can't seat them last.
        assert!(suitability(&four_player, 4) < suitability(&duel, 4));
        assert!(suitability(&duel, 4) <= suitability(&solo, 4));
        assert_eq!(suitability(&solo, 4), 2);

        // Two on the couch and the ranking flips, which is the whole point.
        assert!(suitability(&duel, 2) < suitability(&four_player, 2));
    }

    #[test]
    fn player_count_reorders_the_queue_toward_games_that_seat_the_party() {
        let mut queue: VecDeque<CatalogEntry> = VecDeque::from(vec![
            seating("solo-only", 1, 1, Some(1)),
            seating("party", 2, 4, Some(4)),
            seating("duel", 2, 2, Some(2)),
        ]);
        let (tx, mut rx) = mpsc::unbounded_channel();
        tx.send(PrewarmSignal::Players(2)).unwrap();
        drop(tx);

        apply_signals(&mut queue, &mut rx);

        // All three tiers, in order: the game built for two, then the one that
        // seats two without being about it, then the one that can't.
        let order: Vec<_> = queue.iter().map(|e| e.id.clone()).collect();
        assert_eq!(order, vec!["duel", "party", "solo-only"]);
    }

    /// Games the party can't play at all tie with each other, and a tie keeps
    /// catalogue order. Worth pinning down: it's why a four-player couch
    /// doesn't churn the tail of the queue every time somebody sits down.
    #[test]
    fn games_that_cant_seat_the_party_keep_their_relative_order() {
        let mut queue: VecDeque<CatalogEntry> = VecDeque::from(vec![
            seating("solo-only", 1, 1, Some(1)),
            seating("duel", 2, 2, Some(2)),
            seating("party", 2, 4, Some(4)),
        ]);
        let (tx, mut rx) = mpsc::unbounded_channel();
        tx.send(PrewarmSignal::Players(4)).unwrap();
        drop(tx);

        apply_signals(&mut queue, &mut rx);

        let order: Vec<_> = queue.iter().map(|e| e.id.clone()).collect();
        assert_eq!(order, vec!["party", "solo-only", "duel"]);
    }

    #[test]
    fn an_explicit_request_outranks_the_player_count() {
        let mut queue: VecDeque<CatalogEntry> = VecDeque::from(vec![
            seating("solo-only", 1, 1, Some(1)),
            seating("party", 2, 4, Some(4)),
        ]);
        let (tx, mut rx) = mpsc::unbounded_channel();
        tx.send(PrewarmSignal::Players(4)).unwrap();
        // Somebody asked for the one-player game by name. What the party said
        // out loud beats what we inferred from how many of them sat down.
        tx.send(PrewarmSignal::Prioritize("solo-only".into()))
            .unwrap();
        drop(tx);

        apply_signals(&mut queue, &mut rx);

        let order: Vec<_> = queue.iter().map(|e| e.id.clone()).collect();
        assert_eq!(order, vec!["solo-only", "party"]);
    }

    #[test]
    fn a_party_of_nobody_leaves_the_queue_in_catalogue_order() {
        let mut queue: VecDeque<CatalogEntry> = VecDeque::from(vec![
            seating("solo-only", 1, 1, Some(1)),
            seating("party", 2, 4, Some(4)),
        ]);
        let (tx, mut rx) = mpsc::unbounded_channel();
        // Nobody has picked up a controller yet, so there is nothing to infer
        // from — reordering here would just be guessing.
        tx.send(PrewarmSignal::Players(0)).unwrap();
        drop(tx);

        apply_signals(&mut queue, &mut rx);

        let order: Vec<_> = queue.iter().map(|e| e.id.clone()).collect();
        assert_eq!(order, vec!["solo-only", "party"]);
    }

    #[test]
    fn apply_signals_bumps_a_requested_game_to_the_front() {
        let mut queue: VecDeque<CatalogEntry> = ["a", "b", "c"]
            .into_iter()
            .map(|id| bare_binary_entry(id, &"a".repeat(64)))
            .collect();
        let (tx, mut rx) = mpsc::unbounded_channel();
        tx.send(PrewarmSignal::Prioritize("c".into())).unwrap();
        drop(tx); // dropping the sender doesn't discard what's already buffered

        apply_signals(&mut queue, &mut rx);

        let order: Vec<_> = queue.iter().map(|e| e.id.clone()).collect();
        assert_eq!(order, vec!["c", "a", "b"]);
    }

    #[test]
    fn apply_signals_ignores_a_game_thats_not_queued() {
        let mut queue: VecDeque<CatalogEntry> = ["a", "b"]
            .into_iter()
            .map(|id| bare_binary_entry(id, &"a".repeat(64)))
            .collect();
        let (tx, mut rx) = mpsc::unbounded_channel();
        // Already downloading, already done, or never eligible — either way
        // it's not in the queue, so this is a no-op rather than an error.
        tx.send(PrewarmSignal::Prioritize("already-installed".into()))
            .unwrap();
        drop(tx);

        apply_signals(&mut queue, &mut rx);

        let order: Vec<_> = queue.iter().map(|e| e.id.clone()).collect();
        assert_eq!(order, vec!["a", "b"]);
    }

    #[test]
    fn apply_signals_last_request_wins_the_front_slot() {
        let mut queue: VecDeque<CatalogEntry> = ["a", "b", "c"]
            .into_iter()
            .map(|id| bare_binary_entry(id, &"a".repeat(64)))
            .collect();
        let (tx, mut rx) = mpsc::unbounded_channel();
        tx.send(PrewarmSignal::Prioritize("b".into())).unwrap();
        tx.send(PrewarmSignal::Prioritize("c".into())).unwrap();
        drop(tx);

        apply_signals(&mut queue, &mut rx);

        let order: Vec<_> = queue.iter().map(|e| e.id.clone()).collect();
        assert_eq!(order, vec!["c", "b", "a"]);
    }
}
