//! Run the background prewarm once, standalone — useful to watch it work or
//! to warm the cache before a party without waiting on the daemon.
//!
//!     cargo run -p gamenight-installer

use gamenight_installer::{install_dir, prewarm_all};

#[tokio::main]
async fn main() {
    tracing_subscriber_init();
    let root = install_dir();
    println!("installing into {}", root.display());
    let results = prewarm_all(&gamenight_catalog::catalog_dir(), &root, None).await;
    if results.is_empty() {
        println!("nothing eligible in the catalogue right now");
        return;
    }
    let mut failed = 0;
    for r in &results {
        match &r.outcome {
            Ok(installed) => println!(" ✔ {} -> {}", r.game, installed.executable.display()),
            Err(e) => {
                failed += 1;
                println!(" ✘ {} -> {e}", r.game);
            }
        }
    }
    println!("{}/{} installed", results.len() - failed, results.len());
    std::process::exit(if failed > 0 { 1 } else { 0 });
}

fn tracing_subscriber_init() {
    let _ = tracing_subscriber::fmt::try_init();
}
