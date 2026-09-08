// tiny-game: a complete GameNight integration in dependency-free JavaScript.
// Proof that the protocol is the product — no SDK required.
//
//   node examples/tiny-game.mjs            # standalone (title id "tiny-game")
//   ...or launch it from a library entry:
//   { "id": "tiny-game", "title": "Tiny Game",
//     "launch": { "command": "node", "args": ["examples/tiny-game.mjs"] } }
//
// Requires Node 22+ (global WebSocket).

// Step 0 — the daemon passes the handshake via environment when it launches us.
const ADDR = process.env.GAMENIGHT_ADDR ?? "127.0.0.1:7912";
const GAME_ID = process.env.GAMENIGHT_GAME_ID ?? "tiny-game";
const TOKEN = process.env.GAMENIGHT_TOKEN; // undefined when started by hand
const MATCH_MS = 5000;

const ws = new WebSocket(`ws://${ADDR}`);
const send = (msg) => ws.send(JSON.stringify(msg));
const log = (s) => console.log(`[${GAME_ID}] ${s}`);

let match = null; // the running match's timer, so skip can cancel it

// Step 1 — hello first, token included when we were launched.
ws.onopen = () => send({ type: "hello", role: "game", game: GAME_ID, token: TOKEN });
ws.onclose = () => { log("daemon went away, good night"); process.exit(0); };

ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  switch (msg.type) {
    case "welcome":
      log(`in the party (protocol v${msg.protocol_version}), waiting for our turn`);
      break;

    case "prepare": {
      // Step 2 — load everything for these seats, show nothing, then: ready.
      const seated = msg.seats
        .filter((s) => s.occupant.kind !== "empty")
        .map((s) => msg.players.find((p) => p.id === s.occupant.player_id)?.name ?? "bot");
      log(`warming up for [${seated.join(", ") || "an empty couch"}]`);
      send({ type: "ready", session: msg.session });
      break;
    }

    case "start":
      // Step 3 — GO. Gameplay within a second (ours takes zero).
      log("GO! playing a very tiny match");
      match = setTimeout(() => {
        // Step 4 — the match is over; the party votes while our
        // imaginary scoreboard keeps rendering.
        log("match over! reporting finished");
        send({ type: "finished", session: msg.session });
      }, MATCH_MS);
      break;

    case "pause":  log("paused (the party is open)"); break;   // freeze sim + mute
    case "resume": log("resumed"); break;

    case "dispose":
      // Step 5 — eject the record; stay resident for the next prepare.
      clearTimeout(match); // skip mid-match: exit silently, no prompts
      log("session disposed, back to the bench");
      break;

    // Forward compatibility: ignore anything we don't know.
  }
};
