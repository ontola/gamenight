// tiny-game: a complete GameNight integration in dependency-free JavaScript.
// Proof that the protocol is the product — no SDK required. The one import is
// the protocol's tags and constants, generated from its schema; copying the
// string values instead works just as well.
//
//   node examples/tiny-game.mjs            # standalone (title id "tiny-game")
//   ...or launch it from a library entry:
//   { "id": "tiny-game", "title": "Tiny Game",
//     "launch": { "command": "node", "args": ["examples/tiny-game.mjs"] } }
//
// Requires Node 22+ (global WebSocket).

import { DEFAULT_ADDR, ENV_ADDR, ENV_GAME_ID, ENV_TOKEN, MSG, Role, SeatOccupant } from "../sdk/js/protocol.mjs";

// Step 0 — the daemon passes the handshake via environment when it launches us.
const ADDR = process.env[ENV_ADDR] ?? DEFAULT_ADDR;
const GAME_ID = process.env[ENV_GAME_ID] ?? "tiny-game";
const TOKEN = process.env[ENV_TOKEN]; // undefined when started by hand
const MATCH_MS = 5000;

const ws = new WebSocket(`ws://${ADDR}`);
const send = (msg) => ws.send(JSON.stringify(msg));
const log = (s) => console.log(`[${GAME_ID}] ${s}`);

let match = null; // the running match's timer, so skip can cancel it

// Step 1 — hello first, token included when we were launched.
ws.onopen = () => send({ type: MSG.HELLO, role: Role.GAME, game: GAME_ID, token: TOKEN });
ws.onclose = () => { log("daemon went away, good night"); process.exit(0); };

ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  switch (msg.type) {
    case MSG.WELCOME:
      log(`in the party (protocol v${msg.protocol_version}), waiting for our turn`);
      break;

    case MSG.PREPARE: {
      // Step 2 — load everything for these seats, show nothing, then: ready.
      const seated = msg.seats
        .filter((s) => s.occupant.kind !== SeatOccupant.EMPTY)
        .map((s) => msg.players.find((p) => p.id === s.occupant.player_id)?.name ?? "bot");
      log(`warming up for [${seated.join(", ") || "an empty couch"}]`);
      send({ type: MSG.READY, session: msg.session });
      break;
    }

    case MSG.START:
      // Step 3 — GO. Gameplay within a second (ours takes zero).
      log("GO! playing a very tiny match");
      match = setTimeout(() => {
        // Step 4 — the match is over; the party votes while our
        // imaginary scoreboard keeps rendering.
        log("match over! reporting finished");
        send({ type: MSG.FINISHED, session: msg.session });
      }, MATCH_MS);
      break;

    case MSG.PAUSE:  log("paused (the party is open)"); break;   // freeze sim + mute
    case MSG.RESUME: log("resumed"); break;

    case MSG.DISPOSE:
      // Step 5 — eject the record; stay resident for the next prepare.
      clearTimeout(match); // skip mid-match: exit silently, no prompts
      log("session disposed, back to the bench");
      break;

    // Forward compatibility: ignore anything we don't know.
  }
};
