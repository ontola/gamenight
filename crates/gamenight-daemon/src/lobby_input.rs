//! Runtime-owned controller input for replacement lobbies. The legacy Bevy
//! lobby keeps its existing input path until it adopts Role::Lobby.
use super::*;
use gamenight_protocol::ControllerState;
use gilrs::{Axis, Button};
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

pub(super) fn spawn(shared: Arc<Mutex<Shared>>) {
    // Protocol/scene tests inject their own seats and input. Connected physical
    // pads must not alter those fixtures. Normal launches never set this flag.
    if std::env::var_os("GAMENIGHT_TEST_NO_CONTROLLERS").is_some() {
        return;
    }
    // Bounded: a busy runtime drops samples rather than queueing stale input.
    let (tx, mut rx) = mpsc::channel(2);
    // Frame delivery must not wait for catalog snapshot serialization under
    // Shared's mutex. The sampler owns this fast path; the router owns party
    // commands. Sender refreshes are tiny and never hold the party lock here.
    let targets = Arc::new(std::sync::RwLock::new(Vec::<Tx>::new()));
    let sample_targets = targets.clone();
    let result = std::thread::Builder::new()
        .name("lobby-input".into())
        .spawn(move || {
            let mut pads = match gilrs::Gilrs::new() {
                Ok(pads) => pads,
                Err(error) => {
                    warn!(%error, "runtime controller input unavailable");
                    return;
                }
            };
            let mut known = Vec::new();
            let mut filter = FrameFilter::default();
            loop {
                while pads.next_event().is_some() {}
                let controllers: Vec<_> = pads
                    .gamepads()
                    .map(|(id, pad)| {
                        let mut axes = [0i16; 6];
                        for (i, axis) in [
                            Axis::LeftStickX,
                            Axis::LeftStickY,
                            Axis::RightStickX,
                            Axis::RightStickY,
                        ]
                        .iter()
                        .enumerate()
                        {
                            axes[i] = (pad.value(*axis).clamp(-1.0, 1.0) * 32767.0) as i16;
                        }
                        axes[1] = -axes[1];
                        axes[3] = -axes[3];
                        for (i, button) in [Button::LeftTrigger2, Button::RightTrigger2]
                            .iter()
                            .enumerate()
                        {
                            axes[i + 4] =
                                (pad.button_data(*button).map(|b| b.value()).unwrap_or(0.0)
                                    * 32767.0) as i16;
                        }
                        let buttons = [
                            Button::South,
                            Button::East,
                            Button::West,
                            Button::North,
                            Button::LeftTrigger,
                            Button::RightTrigger,
                            Button::Select,
                            Button::Start,
                            Button::LeftThumb,
                            Button::RightThumb,
                            Button::DPadUp,
                            Button::DPadDown,
                            Button::DPadLeft,
                            Button::DPadRight,
                        ]
                        .iter()
                        .enumerate()
                        .fold(0, |bits, (i, b)| {
                            bits | if pad.is_pressed(*b) { 1 << i } else { 0 }
                        });
                        ControllerState {
                            controller: format!("ordinal:{}", usize::from(id)),
                            axes,
                            buttons,
                        }
                    })
                    .collect();
                let ids: Vec<_> = controllers.iter().map(|c| c.controller.clone()).collect();
                if ids != known {
                    info!(controllers = ?ids, "runtime controller devices changed");
                    known = ids;
                }
                pads.inc();
                if tx.is_closed() {
                    break;
                }
                let outgoing = filter.apply(controllers.clone());
                let recipients = sample_targets.read().unwrap().clone();
                publish(&recipients, outgoing);
                let _ = tx.try_send(controllers);
                std::thread::sleep(Duration::from_millis(16));
            }
        });
    if let Err(error) = result {
        warn!(%error, "could not spawn runtime input");
        return;
    }
    tokio::spawn(async move {
        let mut router = InputRouter::default();
        while let Some(controllers) = rx.recv().await {
            let mut s = shared.lock().await;
            router.route(&mut s, controllers);
            *targets.write().unwrap() = s.games.values().cloned().collect();
        }
    });
}

fn publish(targets: &[Tx], controllers: Vec<ControllerState>) {
    let frame = ServerMessage::ControllerFrame { controllers }.to_json();
    for tx in targets {
        let _ = tx.send(frame.clone());
    }
}

#[derive(Default)]
struct FrameFilter {
    seen: HashSet<String>,
    held_on_connect: HashSet<String>,
}

impl FrameFilter {
    fn apply(&mut self, mut controllers: Vec<ControllerState>) -> Vec<ControllerState> {
        for controller in &mut controllers {
            if self.seen.insert(controller.controller.clone()) && controller.buttons & 1 != 0 {
                self.held_on_connect.insert(controller.controller.clone());
            }
            if controller.buttons & 1 == 0 {
                self.held_on_connect.remove(&controller.controller);
            }
            controller.buttons &= !(1 << 6); // Back belongs to the runtime.
            if self.held_on_connect.contains(&controller.controller) {
                controller.buttons &= !1;
            }
        }
        self.seen
            .retain(|id| controllers.iter().any(|c| &c.controller == id));
        self.held_on_connect.retain(|id| self.seen.contains(id));
        controllers
    }
}

#[derive(Default)]
struct InputRouter {
    previous: HashMap<String, u32>,
    consumed_join: HashSet<String>,
    activity: HashMap<String, Instant>,
    joined_connection: HashSet<String>,
}

impl InputRouter {
    fn route(&mut self, s: &mut Shared, mut controllers: Vec<ControllerState>) {
        let Self {
            previous,
            consumed_join,
            activity,
            joined_connection,
        } = self;
        // Several people may press Back together. It is one party action.
        if controllers
            .iter()
            .any(|c| c.buttons & !previous.get(&c.controller).copied().unwrap_or(0) & (1 << 6) != 0)
        {
            s.dispatch(
                if s.night.snapshot().overlay_open {
                    Command::OverlayClosed
                } else {
                    Command::OverlayOpened
                },
                None,
            );
        }
        for controller in &mut controllers {
            let held = controller.buttons;
            previous.insert(controller.controller.clone(), held);
            let snapshot = s.night.snapshot();
            let lobby_active = snapshot.overlay_open || snapshot.active_session.is_none();
            // The runtime consumes Back; SDKs must not echo the same
            // press and bounce a just-resumed game into the lobby again.
            controller.buttons &= !(1 << 6);
            if lobby_active
                && !joined_connection.contains(&controller.controller)
                && snapshot
                    .seats
                    .iter()
                    .any(|seat| seat.occupant.is_empty() || seat.controller.is_none())
                && !snapshot.seats.iter().any(|seat| {
                    seat.controller.as_deref() == Some(&controller.controller)
                        && seat.occupant.player_id().is_some()
                })
            {
                // A connected controller is the join action. Claim
                // their first unbound seat before creating another player.
                let unbound = snapshot
                    .seats
                    .iter()
                    .find(|seat| seat.controller.is_none() && seat.occupant.player_id().is_some())
                    .and_then(|seat| seat.occupant.player_id());
                let player = unbound.or_else(|| {
                    let before: HashSet<_> = snapshot.players.iter().map(|p| p.id).collect();
                    s.dispatch(
                        Command::JoinParty {
                            name: format!("Player {}", before.len() + 1),
                            seat: None,
                            color: None,
                            avatar: None,
                            library: Vec::new(),
                        },
                        None,
                    );
                    s.night
                        .snapshot()
                        .players
                        .iter()
                        .find(|p| !before.contains(&p.id))
                        .map(|p| p.id)
                });
                if let Some(player) = player {
                    s.dispatch(
                        Command::BindController {
                            player_id: player,
                            controller: controller.controller.clone(),
                        },
                        None,
                    );
                }
                consumed_join.insert(controller.controller.clone());
                joined_connection.insert(controller.controller.clone());
            }
            if held & 1 == 0 {
                consumed_join.remove(&controller.controller);
            }
            if consumed_join.contains(&controller.controller) {
                controller.buttons &= !1;
            }
            if (held != 0 || controller.axes.iter().any(|a| a.unsigned_abs() > 8000))
                && activity
                    .get(&controller.controller)
                    .is_none_or(|at| at.elapsed() >= Duration::from_secs(1))
            {
                activity.insert(controller.controller.clone(), Instant::now());
                s.dispatch(
                    Command::ControllerInput {
                        game: None,
                        session: None,
                        controller: controller.controller.clone(),
                    },
                    None,
                );
            }
        }
        previous.retain(|id, _| controllers.iter().any(|c| &c.controller == id));
        joined_connection.retain(|id| controllers.iter().any(|c| &c.controller == id));
        // Tests exercise the filtered router result. In production frames
        // are published directly by the sampler, independently of this lock.
        #[cfg(test)]
        publish(&s.games.values().cloned().collect::<Vec<_>>(), controllers);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fast_frames_preserve_axes_and_gate_only_reserved_buttons() {
        let mut filter = FrameFilter::default();
        let mut input = frame(1 | (1 << 6) | 4);
        input[0].axes = [-32767, 16384, -10000, 0, 127, 32767];
        let output = filter.apply(input.clone());
        assert_eq!(output[0].axes, input[0].axes);
        assert_eq!(output[0].buttons, 4);
        filter.apply(frame(0));
        assert_eq!(filter.apply(frame(1))[0].buttons, 1);
        filter.apply(vec![]);
        assert_eq!(filter.apply(frame(1))[0].buttons, 0);
    }

    #[tokio::test]
    async fn game_frames_keep_flowing_while_party_lock_is_busy() {
        let shared = Arc::new(Mutex::new(Shared::new(
            Vec::new(),
            "127.0.0.1:0".into(),
            None,
        )));
        let (tx, mut rx) = mpsc::unbounded_channel();
        let _busy = shared.lock().await;
        let worker = std::thread::spawn(move || {
            for i in 0..20 {
                let mut state = frame(0);
                state[0].axes[0] = i * 100;
                publish(std::slice::from_ref(&tx), state);
                std::thread::sleep(Duration::from_millis(5));
            }
        });
        for i in 0..20 {
            let json = tokio::time::timeout(Duration::from_millis(100), rx.recv())
                .await
                .unwrap()
                .unwrap();
            let msg: ServerMessage = serde_json::from_str(&json).unwrap();
            assert!(
                matches!(msg, ServerMessage::ControllerFrame {controllers} if controllers[0].axes[0] == i*100)
            );
        }
        worker.join().unwrap();
    }

    #[tokio::test]
    async fn connection_joins_without_buttons_and_explicit_leave_stays_left() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        let mut router = InputRouter::default();
        router.route(&mut s, frame(0));
        let party = s.night.snapshot();
        assert_eq!(party.players.len(), 1);
        assert_eq!(party.seats[0].controller.as_deref(), Some("ordinal:7"));
        assert!(party.players[0].avatar.is_some());
        s.dispatch(
            Command::LeaveParty {
                player_id: party.players[0].id,
            },
            None,
        );
        router.route(&mut s, frame(1));
        assert!(s.night.snapshot().players.is_empty());
        router.route(&mut s, vec![]);
        router.route(&mut s, frame(0));
        assert_eq!(s.night.snapshot().players.len(), 1);
    }

    fn frame(buttons: u32) -> Vec<ControllerState> {
        vec![ControllerState {
            controller: "ordinal:7".into(),
            axes: [0; 6],
            buttons,
        }]
    }

    #[tokio::test]
    async fn join_claims_existing_profile_and_consumes_only_the_join_press() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        s.dispatch(
            Command::JoinParty {
                name: "Nora".into(),
                seat: None,
                color: None,
                avatar: None,
                library: Vec::new(),
            },
            None,
        );
        let id = s.night.snapshot().players[0].id;
        let (tx, mut rx) = mpsc::unbounded_channel();
        s.games.insert(GameId::new("test-game"), tx);
        let mut router = InputRouter::default();
        router.route(&mut s, frame(1));
        let party = s.night.snapshot();
        assert_eq!(party.players.len(), 1);
        assert_eq!(party.players[0].id, id);
        assert_eq!(party.seats[0].controller.as_deref(), Some("ordinal:7"));
        // Only a controller frame is delivered to this unprepared test game.
        let message: ServerMessage = serde_json::from_str(&rx.recv().await.unwrap()).unwrap();
        assert!(
            matches!(message, ServerMessage::ControllerFrame { controllers } if controllers[0].buttons == 0)
        );
        router.route(&mut s, frame(0));
        rx.recv().await.unwrap();
        router.route(&mut s, frame(1));
        let message: ServerMessage = serde_json::from_str(&rx.recv().await.unwrap()).unwrap();
        assert!(
            matches!(message, ServerMessage::ControllerFrame { controllers } if controllers[0].buttons == 1)
        );
        assert_eq!(s.night.snapshot().players.len(), 1);
    }

    #[tokio::test]
    async fn held_back_toggles_once_and_is_not_forwarded() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        let (tx, mut rx) = mpsc::unbounded_channel();
        s.games.insert(GameId::new("test-game"), tx);
        let mut router = InputRouter::default();
        for _ in 0..3 {
            router.route(&mut s, frame(1 << 6));
            assert!(s.night.snapshot().overlay_open);
            let message: ServerMessage = serde_json::from_str(&rx.recv().await.unwrap()).unwrap();
            assert!(
                matches!(message, ServerMessage::ControllerFrame { controllers } if controllers[0].buttons == 0)
            );
        }
        router.route(&mut s, frame(0));
        router.route(&mut s, frame(1 << 6));
        assert!(!s.night.snapshot().overlay_open);
    }

    #[tokio::test]
    async fn simultaneous_back_presses_are_one_party_action() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:0".into(), None);
        let mut router = InputRouter::default();
        let mut controllers = frame(1 << 6);
        controllers.push(ControllerState {
            controller: "ordinal:3".into(),
            axes: [0; 6],
            buttons: 1 << 6,
        });
        router.route(&mut s, controllers);
        assert!(s.night.snapshot().overlay_open);
    }
}
