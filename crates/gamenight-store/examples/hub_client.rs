//! Try the player store against a real hub by hand:
//!
//! ```text
//! hub_client agent DIR
//! hub_client save DIR OWNER GAME JSON REVISION
//! hub_client sync DIR wss://host/atomic/ws OWNER DRIVE
//! hub_client show DIR
//! ```
use gamenight_store::{sync, Store};

#[tokio::main]
async fn main() -> gamenight_store::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let dir = std::path::PathBuf::from(&args[1]);
    let mut store = Store::open(&dir).await?;
    match args[0].as_str() {
        "agent" => println!("{}", store.agent().unwrap_or_default()),
        "save" => {
            let saved = gamenight_core::SavedPlayerData {
                data: serde_json::from_str(&args[4])?,
                revision: args[5].parse()?,
            };
            store.put_data(&args[2], &args[3], &saved).await?;
        }
        "sync" => {
            let (url, owner, drive) = (&args[2], &args[3], &args[4]);
            let origin = sync::origin_of(url);
            let mut hub = sync::WsTransport::connect(url).await?;
            let (report, _) = store.sync(&mut hub, &origin, drive).await?;
            store.link(owner, drive).await?;
            let mut hub = sync::WsTransport::connect(url).await?;
            let (again, changed) = store.sync(&mut hub, &origin, drive).await?;
            println!("{report:?} {again:?} {changed:?}");
        }
        "show" => println!("{:?}", store.load().await?.data),
        other => return Err(format!("unknown command {other}").into()),
    }
    Ok(())
}
