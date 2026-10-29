//! Syncing a drive of the player store with a hub, over Atomic's own v2 sync
//! protocol (`atomic_lib::sync`).
//!
//! A device dials the hub, proves its agent with `AUTH`, offers the version
//! vectors of the drive (`SYNC`), sends what the hub asks for and takes what
//! the hub sends back. Both sides merge with Loro, so edits made offline on
//! two devices both survive. The hub decides who may read and write a drive;
//! this side trusts what its hub sends.

use std::collections::{BTreeSet, HashMap};
use std::time::Duration;

use atomic_lib::agents::{Agent, ForAgent};
use atomic_lib::sync::{engine, protocol, transport::AtomicTransport, ws_apply};
use atomic_lib::{Db, Subject};

use crate::{atomic, Result};

/// How long the hub may stay silent before we give up on this round.
const IDLE: Duration = Duration::from_secs(20);

/// What one sync round moved.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct SyncReport {
    /// Resources the hub asked for and got.
    pub sent: usize,
    /// Resources the hub sent and we merged in.
    pub received: usize,
}

/// Sync `drive` with the hub at the other end of `transport`. `origin` is the
/// hub's `https://host` origin, which the `AUTH` proof is bound to.
pub async fn sync_drive<T: AtomicTransport>(
    db: &Db,
    agent: &Agent,
    transport: &mut T,
    origin: &str,
    drive: &str,
) -> Result<SyncReport> {
    transport
        .send(protocol::encode_hello_with_caps(
            "GameNight",
            protocol::CLIENT_CAPABILITIES,
        ))
        .await
        .map_err(atomic)?;

    // The hub opens with a CHALLENGE; the proof names it so it is only good
    // on this connection.
    let mut requested = origin.to_string();
    let first = recv(transport).await?;
    let mut pending = Some(first);
    if let Some(frame) = &pending {
        if frame.first() == Some(&protocol::tag::CHALLENGE) {
            if let Some(nonce) = protocol::decode_challenge(&frame[1..]) {
                requested = format!("{origin}#{nonce}");
            }
            pending = None;
        }
    }
    transport
        .send(protocol::encode_auth(agent, &requested).map_err(atomic)?)
        .await
        .map_err(atomic)?;
    loop {
        let frame = match pending.take() {
            Some(frame) => frame,
            None => recv(transport).await?,
        };
        match frame.first() {
            Some(&protocol::tag::AUTH_OK) => break,
            Some(&protocol::tag::ERROR) => return Err(refusal(&frame).into()),
            _ => {}
        }
    }

    transport
        .send(sync_frame(db, drive).await)
        .await
        .map_err(atomic)?;

    let mut report = SyncReport::default();
    // Acks we still wait for on chunks we sent, and whether the hub still
    // owes us its own SYNC_PUSH run.
    let mut unacked = 0usize;
    let mut incoming = false;
    let mut diffed = false;
    loop {
        let frame = recv(transport).await?;
        match frame.first().copied() {
            Some(protocol::tag::SYNC_OK) => {
                if !diffed {
                    // Already the same on both sides.
                    break;
                }
                unacked = unacked.saturating_sub(1);
            }
            Some(protocol::tag::SYNC_DIFF) => {
                let diff = protocol::decode_sync_diff(&frame[1..]).ok_or("bad SYNC_DIFF")?;
                diffed = true;
                incoming = !diff.push.is_empty();
                if !diff.pull.is_empty() {
                    let entries =
                        engine::collect_readable_snapshots(db, &ForAgent::Sudo, &diff.pull, None)
                            .await;
                    let refs: Vec<(&str, &[u8])> = entries
                        .iter()
                        .map(|(s, b)| (s.as_str(), b.as_slice()))
                        .collect();
                    for chunk in protocol::encode_sync_push_chunks(drive, &refs) {
                        unacked += 1;
                        transport.send(chunk).await.map_err(atomic)?;
                    }
                    report.sent += entries.len();
                }
            }
            Some(protocol::tag::SYNC_PUSH) => {
                let push = protocol::decode_sync_push(&frame[1..]).ok_or("bad SYNC_PUSH")?;
                let items: Vec<(String, Vec<u8>)> = push
                    .entries
                    .into_iter()
                    .map(|e| (e.subject, e.loro_bytes))
                    .collect();
                report.received += ws_apply::apply_state_updates(db, &items, false)
                    .await
                    .map_err(atomic)?;
                if push.last {
                    incoming = false;
                }
            }
            Some(protocol::tag::ERROR) => return Err(refusal(&frame).into()),
            _ => {}
        }
        if diffed && unacked == 0 && !incoming {
            break;
        }
    }
    db.flush().map_err(atomic)?;
    Ok(report)
}

async fn recv<T: AtomicTransport>(transport: &mut T) -> Result<Vec<u8>> {
    match tokio::time::timeout(IDLE, transport.recv()).await {
        Err(_) => Err("the hub stopped answering".into()),
        Ok(Err(error)) => Err(atomic(error)),
        Ok(Ok(None)) => Err("the hub closed the connection".into()),
        Ok(Ok(Some(frame))) => Ok(frame),
    }
}

fn refusal(frame: &[u8]) -> String {
    protocol::decode_error(&frame[1..])
        .map(|e| format!("the hub refused: {}", e.message))
        .unwrap_or_else(|| "the hub refused".into())
}

/// Our version vectors for the whole drive, as `SYNC` carries them.
async fn sync_frame(db: &Db, drive: &str) -> Vec<u8> {
    let subject = Subject::from_raw(drive, None);
    let subjects = engine::collect_drive_subjects(db, &subject).await;
    let vvs = engine::build_drive_vvs(db, &subjects);
    let hash = engine::compute_drive_hash(&vvs);
    let peers: Vec<String> = vvs
        .values()
        .flat_map(|vv| vv.keys().cloned())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let index: HashMap<&str, usize> = peers
        .iter()
        .enumerate()
        .map(|(i, p)| (p.as_str(), i))
        .collect();
    let mut resources = HashMap::new();
    for (subject, vv) in &vvs {
        let mut counters = vec![0i32; peers.len()];
        for (peer, &counter) in vv {
            if let Some(&i) = index.get(peer.as_str()) {
                counters[i] = counter;
            }
        }
        resources.insert(subject.clone(), counters);
    }
    protocol::encode_sync(drive, &hash, &peers, &resources)
}

/// A hub reached over a WebSocket (`wss://host/atomic/ws`).
pub struct WsTransport {
    socket: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
}

impl WsTransport {
    pub async fn connect(url: &str) -> Result<Self> {
        let (socket, _) = tokio::time::timeout(IDLE, tokio_tungstenite::connect_async(url))
            .await
            .map_err(|_| "the hub did not answer")??;
        Ok(Self { socket })
    }
}

/// `https://host[:port]` for a `wss://host[:port]/path` hub URL: what the
/// `AUTH` proof names.
pub fn origin_of(url: &str) -> String {
    let (scheme, rest) = match url.split_once("://") {
        Some(("wss", rest)) => ("https", rest),
        Some(("ws", rest)) => ("http", rest),
        Some((scheme, rest)) => (scheme, rest),
        None => ("https", url),
    };
    let host = rest.split('/').next().unwrap_or(rest);
    format!("{scheme}://{host}")
}

impl AtomicTransport for WsTransport {
    async fn send(&mut self, frame: Vec<u8>) -> atomic_lib::errors::AtomicResult<()> {
        use futures_util::SinkExt;
        self.socket
            .send(tokio_tungstenite::tungstenite::Message::Binary(frame))
            .await
            .map_err(|e| e.to_string().into())
    }

    async fn recv(&mut self) -> atomic_lib::errors::AtomicResult<Option<Vec<u8>>> {
        use futures_util::StreamExt;
        use tokio_tungstenite::tungstenite::Message;
        loop {
            match self.socket.next().await {
                None | Some(Ok(Message::Close(_))) => return Ok(None),
                Some(Ok(Message::Binary(frame))) => return Ok(Some(frame)),
                Some(Ok(_)) => continue,
                Some(Err(e)) => return Err(e.to_string().into()),
            }
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use atomic_lib::sync::transport::ChannelTransport;
    use atomic_lib::{urls, Storelike, Value};

    /// A hub as small as it gets: one connection, the engine answering.
    pub(crate) fn serve(hub: Db) -> ChannelTransport {
        let (client, mut server) = ChannelTransport::pair();
        tokio::spawn(async move {
            let nonce = protocol::new_challenge_nonce();
            let mut agent = ForAgent::Public;
            if server
                .send(protocol::encode_challenge(&nonce))
                .await
                .is_err()
            {
                return;
            }
            while let Ok(Some(frame)) = server.recv().await {
                let replies = if frame.first() == Some(&protocol::tag::AUTH) {
                    engine::handle_auth_frame(
                        &frame[1..],
                        &hub,
                        &mut agent,
                        engine::AuthBinding::Unbound,
                        engine::AuthChallenge::Issued(&nonce),
                    )
                    .await
                } else {
                    engine::handle_frame_full(&frame, &hub, &mut agent)
                        .await
                        .frames
                };
                for reply in replies {
                    if server.send(reply).await.is_err() {
                        return;
                    }
                }
            }
        });
        client
    }

    /// The same hub on a real WebSocket: `ws://127.0.0.1:port/atomic/ws`.
    pub(crate) async fn serve_ws(hub: Db) -> String {
        use futures_util::{SinkExt, StreamExt};
        use tokio_tungstenite::tungstenite::Message;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}/atomic/ws", listener.local_addr().unwrap());
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let hub = hub.clone();
                tokio::spawn(async move {
                    let Ok(mut socket) = tokio_tungstenite::accept_async(stream).await else {
                        return;
                    };
                    let mut engine_side = serve(hub);
                    loop {
                        tokio::select! {
                            frame = engine_side.recv() => match frame {
                                Ok(Some(frame)) => {
                                    if socket.send(Message::Binary(frame)).await.is_err() { return; }
                                }
                                _ => return,
                            },
                            message = socket.next() => match message {
                                Some(Ok(Message::Binary(frame))) => {
                                    if engine_side.send(frame).await.is_err() { return; }
                                }
                                Some(Ok(_)) => {}
                                _ => return,
                            },
                        }
                    }
                });
            }
        });
        url
    }

    /// The hub's drive for one account, writable by `agents`.
    pub(crate) async fn account_drive(hub: &Db, agents: &[&str]) -> String {
        let drive = hub.ensure_private_drive().await.unwrap();
        let mut resource = hub.get_resource(&drive.as_str().into()).await.unwrap();
        let mut list: Vec<atomic_lib::values::SubResource> = match resource.get(urls::WRITE) {
            Ok(Value::ResourceArray(v)) => v.clone(),
            _ => vec![],
        };
        for agent in agents {
            list.push(agent.to_string().into());
        }
        resource
            .set_unsafe(urls::WRITE.into(), Value::ResourceArray(list.clone()))
            .unwrap();
        resource
            .set_unsafe(urls::READ.into(), Value::ResourceArray(list))
            .unwrap();
        hub.add_resource_opts(&resource, false, true, true)
            .await
            .unwrap();
        drive
    }

    #[tokio::test]
    async fn two_devices_meet_through_the_hub() {
        let hub = Db::init_temp("hub").await.unwrap();
        hub.setup("Hub").await.unwrap();
        let phone = Db::init_temp("phone").await.unwrap();
        let (phone_agent, _) = phone.setup("Phone").await.unwrap();
        let host = Db::init_temp("host").await.unwrap();
        let (host_agent, _) = host.setup("Host").await.unwrap();
        let drive = account_drive(
            &hub,
            &[
                &phone_agent.subject.to_string(),
                &host_agent.subject.to_string(),
            ],
        )
        .await;

        let origin = "https://hub.test";
        let first = sync_drive(
            &phone,
            &phone_agent,
            &mut serve(hub.clone()),
            origin,
            &drive,
        )
        .await
        .unwrap();
        assert!(first.received >= 1, "the phone gets the drive: {first:?}");

        let record = phone
            .create_resource(
                "https://gamenight.ontola.io/ns/PlayerGame",
                &drive,
                "ada / spellstorm",
                Some(vec![(
                    "https://gamenight.ontola.io/ns/data",
                    Value::String("{\"spells\":3}".into()),
                )]),
            )
            .await
            .unwrap();
        let sent = sync_drive(
            &phone,
            &phone_agent,
            &mut serve(hub.clone()),
            origin,
            &drive,
        )
        .await
        .unwrap();
        assert!(sent.sent >= 1, "the phone sends its record: {sent:?}");

        sync_drive(&host, &host_agent, &mut serve(hub.clone()), origin, &drive)
            .await
            .unwrap();
        let on_host = host.get_resource(&record.as_str().into()).await.unwrap();
        assert_eq!(
            on_host
                .get("https://gamenight.ontola.io/ns/data")
                .unwrap()
                .to_string(),
            "{\"spells\":3}"
        );
    }
}
