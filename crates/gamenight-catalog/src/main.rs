//! Browse the committed catalogue as a table.
//!
//!     cargo run -p gamenight-catalog
//!     cargo run -p gamenight-catalog -- --level certified

use gamenight_catalog::{
    json_schema_pretty, load_dir, workspace_catalog_dir, workspace_schema_path, IntegrationLevel,
};

fn main() {
    let mut level_filter: Option<String> = None;
    let mut write_schema = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--level" => level_filter = args.next(),
            "--write-schema" => write_schema = true,
            _ => {
                eprintln!(
                    "usage: gamenight-catalog [--level certified|integrated|adapter|planned]\n       gamenight-catalog --write-schema"
                );
                std::process::exit(2);
            }
        }
    }

    if write_schema {
        std::fs::write(workspace_schema_path(), json_schema_pretty())
            .expect("failed to write catalog/schema.json");
        println!("wrote {}", workspace_schema_path().display());
        return;
    }

    let entries = match load_dir(&workspace_catalog_dir()) {
        Ok(e) => e,
        Err(problems) => {
            eprintln!("catalogue invalid:");
            for p in problems {
                eprintln!("  {p}");
            }
            std::process::exit(1);
        }
    };

    let mut shown: Vec<_> = entries
        .iter()
        .filter(|e| {
            level_filter
                .as_deref()
                .is_none_or(|l| e.integration.level.label() == l)
        })
        .collect();
    // Most integrated first, then by id.
    shown.sort_by_key(|e| (e.integration.level, e.id.clone()));

    println!(
        "{blank:<3}{game:<24} {integration:<12} {players:<8} {price:<16} {disk:>8}  get it",
        blank = "",
        game = "game",
        integration = "integration",
        players = "players",
        price = "price",
        disk = "disk",
    );
    for e in &shown {
        let badge = match e.integration.level {
            IntegrationLevel::Certified => "✅",
            IntegrationLevel::Integrated => "🔌",
            IntegrationLevel::Adapter => "🔧",
            IntegrationLevel::Planned => "💭",
        };
        let players = match e.players.best {
            Some(b) => format!("{}–{} ({b})", e.players.min, e.players.max),
            None => format!("{}–{}", e.players.min, e.players.max),
        };
        let price = match e.price {
            gamenight_catalog::Price::Free => "free",
            gamenight_catalog::Price::PayWhatYouWant => "pay-what-you-want",
            gamenight_catalog::Price::Paid => "paid",
        };
        let disk = e
            .requirements
            .as_ref()
            .and_then(|r| r.disk_mb)
            .map(|mb| format!("{mb} MB"))
            .unwrap_or_else(|| "—".into());
        let get = if let Some(bundled) = &e.bundled {
            format!("bundled: {bundled}")
        } else if e.auto_download_here().is_some() {
            format!("⚡ prewarms ({})", gamenight_catalog::current_platform())
        } else if !e.downloads.is_empty() {
            let platforms: Vec<_> = e.downloads.keys().cloned().collect();
            format!("download ({})", platforms.join("/"))
        } else if let Some(store) = ["itch", "steam", "homepage", "source"]
            .iter()
            .find(|k| e.links.contains_key(**k))
        {
            store.to_string()
        } else if let Some((store, _)) = e.links.iter().next() {
            store.clone()
        } else {
            "—".into()
        };
        println!(
            "{badge:<3}{:<24} {:<12} {players:<8} {price:<16} {disk:>8}  {get}",
            e.title,
            e.integration.level.label(),
        );
    }
    println!("\n{} games shown", shown.len());
}
