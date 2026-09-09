//! The GameNight catalogue: one JSON file per game under `catalog/games/`,
//! answering what a party wants to know before picking a game — player
//! counts, disk/CPU/GPU/RAM needs, where to get it, and how integrated it
//! honestly is.
//!
//! This crate is the schema's enforcement arm: serde types with
//! `deny_unknown_fields`, a directory loader, and cross-field validation.
//! The test suite validates every committed entry, so CI reviews catalogue
//! PRs automatically.

use std::collections::BTreeMap;
use std::path::Path;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CatalogEntry {
    /// Editor hint only; not validated. Points at `../schema.json`.
    #[serde(default, rename = "$schema", skip_serializing_if = "Option::is_none")]
    pub schema: Option<String>,
    /// Lowercase kebab-case; equals the filename and the wire game id.
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tagline: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub developer: Option<String>,
    pub players: Players,
    /// Rough length of one match, for playlist pacing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub match_minutes: Option<u32>,
    pub price: Price,
    pub integration: Integration,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requirements: Option<Requirements>,
    /// Real cover art URL. `emoji` + `color` are the generated-poster fallback.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub emoji: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    /// Store / homepage / source links. Paid games are obtained here.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub links: BTreeMap<String, String>,
    /// Direct downloads keyed by platform (`linux` / `windows` / `mac`).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub downloads: BTreeMap<String, Download>,
    /// Repo-relative path for games bundled with GameNight itself.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundled: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Players {
    pub min: u8,
    /// Couch seats, not online lobby size.
    pub max: u8,
    /// The count the game shines at.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub best: Option<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Price {
    Free,
    PayWhatYouWant,
    Paid,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Integration {
    pub level: IntegrationLevel,
    /// Protocol version spoken (required for integrated/certified).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protocol: Option<u32>,
    /// e.g. "gamenight-certify 0.1.0" (required for certified).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub certified_with: Option<String>,
}

/// The integration ladder, honest by construction.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum IntegrationLevel {
    /// Speaks the protocol and passes gamenight-certify.
    Certified,
    /// Speaks the protocol; not (yet) certified.
    Integrated,
    /// Launchable but silent: no protocol, transitions are kill-and-relaunch.
    Adapter,
    /// Wishlist: metadata only.
    Planned,
}

impl IntegrationLevel {
    pub fn label(&self) -> &'static str {
        match self {
            IntegrationLevel::Certified => "certified",
            IntegrationLevel::Integrated => "integrated",
            IntegrationLevel::Adapter => "adapter",
            IntegrationLevel::Planned => "planned",
        }
    }
}

/// Approximate, honest hardware needs. Target: a living-room PC.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Requirements {
    /// Installed size.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disk_mb: Option<u32>,
    /// Beyond the OS.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ram_mb: Option<u32>,
    /// Plain words: "any dual-core".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cpu: Option<String>,
    /// Plain words: "integrated is fine".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpu: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Download {
    pub url: String,
    /// Required — the daemon refuses unverifiable installs.
    pub sha256: String,
    /// The download itself, not installed size.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size_mb: Option<u32>,
    /// Path to the runnable executable, relative to the extracted archive's
    /// root. Required when [`Self::is_archive`] — there's no way to guess
    /// what's inside a tarball. Omitted for a bare-binary download, where
    /// the download itself (its URL's filename) is the executable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entrypoint: Option<String>,
}

impl Download {
    /// True if `url` is an archive that needs unpacking (`.tar.gz`/`.tgz`/
    /// `.zip`) rather than already being the runnable artifact.
    pub fn is_archive(&self) -> bool {
        let lower = self.url.to_ascii_lowercase();
        lower.ends_with(".tar.gz") || lower.ends_with(".tgz") || lower.ends_with(".zip")
    }
}

pub const PLATFORMS: &[&str] = &["linux", "windows", "mac"];

/// The `downloads` key for the platform this process is running on.
pub fn current_platform() -> &'static str {
    if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "mac"
    } else {
        "linux"
    }
}

impl CatalogEntry {
    /// The download that can be fetched with zero user interaction for
    /// `platform`: free (no login/store wall to click through) and a
    /// direct, hash-verified binary. `None` for paid/store-only games or
    /// platforms with no direct download — regardless of integration level,
    /// since a `planned` game is just as installable as a `certified` one.
    pub fn auto_download_for(&self, platform: &str) -> Option<&Download> {
        (self.price == Price::Free)
            .then(|| self.downloads.get(platform))
            .flatten()
    }

    /// [`Self::auto_download_for`] for the platform this process is running on
    /// — what the daemon checks before silently pre-warming a game.
    pub fn auto_download_here(&self) -> Option<&Download> {
        self.auto_download_for(current_platform())
    }
}

/// Validate one entry; returns human-readable problems (empty = valid).
pub fn validate(entry: &CatalogEntry, filename: &str) -> Vec<String> {
    let mut problems = Vec::new();
    let mut check = |ok: bool, msg: &str| {
        if !ok {
            problems.push(msg.to_string());
        }
    };

    check(
        entry
            .id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
            && !entry.id.is_empty(),
        "id must be lowercase kebab-case",
    );
    check(
        filename == format!("{}.json", entry.id),
        &format!("filename must be {}.json", entry.id),
    );
    check(!entry.title.trim().is_empty(), "title must not be empty");

    check(entry.players.min >= 1, "players.min must be >= 1");
    check(
        entry.players.max >= entry.players.min,
        "players.max must be >= players.min",
    );
    if let Some(best) = entry.players.best {
        check(
            (entry.players.min..=entry.players.max).contains(&best),
            "players.best must be within min..=max",
        );
    }

    match entry.integration.level {
        IntegrationLevel::Certified => {
            check(
                entry.integration.protocol.is_some(),
                "certified entries must state integration.protocol",
            );
            check(
                entry.integration.certified_with.is_some(),
                "certified entries must state integration.certified_with",
            );
        }
        IntegrationLevel::Integrated => check(
            entry.integration.protocol.is_some(),
            "integrated entries must state integration.protocol",
        ),
        _ => check(
            entry.integration.certified_with.is_none(),
            "only certified entries may claim certified_with",
        ),
    }

    for (platform, dl) in &entry.downloads {
        check(
            PLATFORMS.contains(&platform.as_str()),
            &format!("unknown download platform '{platform}' (use linux/windows/mac)"),
        );
        check(
            dl.url.starts_with("https://"),
            &format!("{platform} download url must be https"),
        );
        check(
            dl.sha256.len() == 64 && dl.sha256.chars().all(|c| c.is_ascii_hexdigit()),
            &format!("{platform} sha256 must be 64 hex chars"),
        );
        check(
            !dl.is_archive() || dl.entrypoint.as_deref().is_some_and(|e| !e.is_empty()),
            &format!(
                "{platform} download is an archive — entrypoint required \
                 (which file inside it to run)"
            ),
        );
        if let Some(entrypoint) = &dl.entrypoint {
            check(
                !entrypoint.starts_with('/') && !entrypoint.contains(".."),
                &format!("{platform} entrypoint must be a relative path within the archive"),
            );
        }
    }
    if entry.price == Price::Paid {
        check(
            entry.downloads.is_empty(),
            "paid games use links (stores), never direct downloads",
        );
        check(
            !entry.links.is_empty(),
            "paid games must link to where they're sold",
        );
    }
    for url in entry.links.values() {
        check(
            url.starts_with("https://"),
            &format!("link '{url}' must be https"),
        );
    }
    if let Some(cover) = &entry.cover {
        check(
            cover.starts_with("https://"),
            "cover must be an https URL (emoji/color are the local fallback)",
        );
    }
    problems
}

/// Load and validate every entry in a `catalog/games` directory.
/// Returns entries sorted by id, or all problems found.
pub fn load_dir(dir: &Path) -> Result<Vec<CatalogEntry>, Vec<String>> {
    let mut entries = Vec::new();
    let mut problems = Vec::new();
    let mut paths: Vec<_> = std::fs::read_dir(dir)
        .map_err(|e| vec![format!("cannot read {}: {e}", dir.display())])?
        .filter_map(|r| r.ok().map(|d| d.path()))
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .collect();
    paths.sort();

    for path in paths {
        let filename = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or_default()
            .to_string();
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) => {
                problems.push(format!("{filename}: unreadable: {e}"));
                continue;
            }
        };
        match serde_json::from_str::<CatalogEntry>(&text) {
            Ok(entry) => {
                for p in validate(&entry, &filename) {
                    problems.push(format!("{filename}: {p}"));
                }
                entries.push(entry);
            }
            Err(e) => problems.push(format!("{filename}: {e}")),
        }
    }

    let mut ids = std::collections::HashSet::new();
    for e in &entries {
        if !ids.insert(&e.id) {
            problems.push(format!("duplicate id '{}'", e.id));
        }
    }

    if problems.is_empty() {
        entries.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(entries)
    } else {
        Err(problems)
    }
}

/// The committed catalogue, relative to the workspace root.
///
/// Compile-time path: correct in a checkout, meaningless anywhere else. Use
/// [`catalog_dir`] for anything that runs on a user's machine.
pub fn workspace_catalog_dir() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../catalog/games")
}

/// The catalogue to actually read at runtime, wherever this is installed.
///
/// [`workspace_catalog_dir`] bakes in `CARGO_MANIFEST_DIR`, which is an
/// absolute path on the machine that *built* the binary. That works in
/// development and silently does nothing once shipped: the directory doesn't
/// exist, `load_dir` fails, and the party gets an empty shelf with no error
/// anyone would connect to a packaging mistake. So look beside the executable
/// first, and treat the build-time path as the last resort rather than the
/// first guess.
///
/// Order: `GAMENIGHT_CATALOG`, then the layouts we ship (a macOS `.app`, or a
/// plain directory of files), then the workspace.
pub fn catalog_dir() -> std::path::PathBuf {
    if let Some(dir) = std::env::var_os("GAMENIGHT_CATALOG") {
        return std::path::PathBuf::from(dir);
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(bin_dir) = exe.parent() {
            let candidates = [
                // GameNight.app/Contents/MacOS/x -> Contents/Resources/catalog/games
                "../Resources/catalog/games",
                // a plain unpacked layout: bin/x -> catalog/games
                "../catalog/games",
                "catalog/games",
            ];
            for rel in candidates {
                let candidate = bin_dir.join(rel);
                if candidate.is_dir() {
                    return candidate;
                }
            }
        }
    }
    workspace_catalog_dir()
}

/// JSON Schema for `CatalogEntry`, for editor autocomplete/inline validation.
/// `validate()` remains the source of truth for cross-field rules a JSON
/// Schema can't express (e.g. `players.max >= players.min`).
pub fn json_schema_pretty() -> String {
    let schema = schemars::schema_for!(CatalogEntry);
    serde_json::to_string_pretty(&schema).unwrap() + "\n"
}

/// The committed schema file, relative to the workspace root.
pub fn workspace_schema_path() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../catalog/schema.json")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn minimal(id: &str) -> CatalogEntry {
        serde_json::from_value(serde_json::json!({
            "id": id,
            "title": "T",
            "players": { "min": 1, "max": 4 },
            "price": "free",
            "integration": { "level": "planned" }
        }))
        .unwrap()
    }

    #[test]
    fn schema_json_is_up_to_date() {
        let committed = std::fs::read_to_string(workspace_schema_path()).expect(
            "catalog/schema.json is missing — run \
             `cargo run -p gamenight-catalog -- --write-schema`",
        );
        assert_eq!(
            committed.replace("\r\n", "\n"),
            json_schema_pretty(),
            "catalog/schema.json is stale — run \
             `cargo run -p gamenight-catalog -- --write-schema`"
        );
    }

    #[test]
    fn every_committed_entry_is_valid() {
        match load_dir(&workspace_catalog_dir()) {
            Ok(entries) => assert!(!entries.is_empty(), "catalogue should not be empty"),
            Err(problems) => panic!("catalogue invalid:\n  {}", problems.join("\n  ")),
        }
    }

    #[test]
    fn unknown_fields_are_rejected() {
        let bad = serde_json::json!({
            "id": "x", "title": "X",
            "players": { "min": 1, "max": 4 },
            "price": "free",
            "integration": { "level": "planned" },
            "totally_made_up": true
        });
        assert!(serde_json::from_value::<CatalogEntry>(bad).is_err());
    }

    #[test]
    fn auto_downloadable_requires_free_and_a_platform_binary() {
        let mut e = minimal("free-game");
        e.downloads.insert(
            current_platform().into(),
            Download {
                url: "https://example.com/x.tar.gz".into(),
                sha256: "a".repeat(64),
                size_mb: None,
                entrypoint: Some("x/game".into()),
            },
        );
        assert!(e.auto_download_here().is_some());
        assert!(e.auto_download_for("not-a-real-platform").is_none());

        let mut paid = e.clone();
        paid.price = Price::Paid;
        paid.downloads.clear(); // paid + downloads is itself invalid, keep it a valid fixture
        assert!(paid.auto_download_here().is_none());

        let mut pwyw = e.clone();
        pwyw.price = Price::PayWhatYouWant;
        assert!(
            pwyw.auto_download_here().is_none(),
            "background installs are opt-out of any payment step, even optional ones"
        );

        let no_download = minimal("no-download");
        assert!(no_download.auto_download_here().is_none());
    }

    #[test]
    fn validation_catches_the_classics() {
        let mut e = minimal("bad-id");
        assert!(validate(&e, "wrong-name.json")
            .iter()
            .any(|p| p.contains("filename")));

        e.players.max = 0;
        assert!(!validate(&e, "bad-id.json").is_empty());

        let mut e = minimal("cert");
        e.integration.level = IntegrationLevel::Certified;
        let problems = validate(&e, "cert.json");
        assert!(problems.iter().any(|p| p.contains("protocol")));
        assert!(problems.iter().any(|p| p.contains("certified_with")));

        let mut e = minimal("paid-direct");
        e.price = Price::Paid;
        e.downloads.insert(
            "linux".into(),
            Download {
                url: "https://example.com/x.tar.gz".into(),
                sha256: "a".repeat(64),
                size_mb: None,
                entrypoint: Some("x/game".into()),
            },
        );
        assert!(validate(&e, "paid-direct.json")
            .iter()
            .any(|p| p.contains("never direct downloads")));

        let mut e = minimal("bad-hash");
        e.downloads.insert(
            "linux".into(),
            Download {
                url: "https://example.com/x".into(),
                sha256: "nothex".into(),
                size_mb: None,
                entrypoint: None,
            },
        );
        assert!(validate(&e, "bad-hash.json")
            .iter()
            .any(|p| p.contains("64 hex")));
    }

    #[test]
    fn archives_require_an_entrypoint() {
        let mut e = minimal("no-entrypoint");
        e.downloads.insert(
            "linux".into(),
            Download {
                url: "https://example.com/game-linux.tar.gz".into(),
                sha256: "a".repeat(64),
                size_mb: None,
                entrypoint: None,
            },
        );
        assert!(validate(&e, "no-entrypoint.json")
            .iter()
            .any(|p| p.contains("entrypoint required")));

        let mut with_entrypoint = e.clone();
        with_entrypoint
            .downloads
            .get_mut("linux")
            .unwrap()
            .entrypoint = Some("game-linux/game".into());
        assert!(!validate(&with_entrypoint, "no-entrypoint.json")
            .iter()
            .any(|p| p.contains("entrypoint")));

        // A bare binary (no archive extension) needs no entrypoint.
        let mut bare = minimal("bare-binary");
        bare.downloads.insert(
            "linux".into(),
            Download {
                url: "https://example.com/game-linux".into(),
                sha256: "a".repeat(64),
                size_mb: None,
                entrypoint: None,
            },
        );
        assert!(!validate(&bare, "bare-binary.json")
            .iter()
            .any(|p| p.contains("entrypoint")));

        // A path trying to escape the archive root is rejected outright.
        let mut escaping = with_entrypoint.clone();
        escaping.downloads.get_mut("linux").unwrap().entrypoint = Some("../../etc/passwd".into());
        assert!(validate(&escaping, "no-entrypoint.json")
            .iter()
            .any(|p| p.contains("relative path")));
    }
}
