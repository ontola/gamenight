# Phone screens

A game can give every seated player a screen of their own on their phone: a
hand of cards, a private vote, a god's view of the map. This is how GameNight
does asymmetric play. The TV stays the shared screen; the phone shows what only
that player may see. The wire format is in the
[protocol reference](/docs/protocol#phone-screens); this page is how to build one.

## How it fits together

1. The game declares a folder with a web page in it.
2. GameNight serves that page to each signed-in phone at the table, on the
   LAN or through a hosted room.
3. The page and the game exchange small JSON messages. GameNight tags every
   message from a phone with the player who sent it; a phone cannot pretend
   to be someone else.

The page loads `/assets/companion.js`, which the host provides:

```js
const game = GameNight.connect((data) => render(data), (status) => showStatus(status));
game.send({ action: "roll" });
```

## Phones count as players

If your game is played on phones, say so in `gamenight.json`, so GameNight
counts phones and not just controllers:

```json
"players": { "min": 2, "max": 6, "best": 4, "play_with": "phone" }
```

Use `"controller_and_phone"` when every player needs both, and
`"controller_or_phone"` with `"min_phones": 1` when only some players are on a
phone, like one god among controller players. Two controllers and four phones
then fit a four-player phone game: people without a controller tap **Play on
this phone** in the GameNight app and get a seat of their own. Such a player
leaves the party about 10 seconds after their phone leaves the room. See
[controllers and phones](/docs/protocol#controllers-and-phones).

Phones join late all the time: someone's battery died, someone walked in.
Nobody is too late. Seat everyone you were given in `prepare`, play the ones
without a phone with a bot, and hand the seat back the moment
`companion_presence` says their phone connected. With `instant_join: true`, a
new phone-only player also arrives mid-round in `party_updated`; otherwise on
the next round.

## In Godot

Keep the page in a folder of your project, such as `res://phone`, and declare
it once from `_ready()`:

```gdscript
func _ready():
    GameNight.companion_presence.connect(_on_phone)
    GameNight.companion_message.connect(_on_phone_message)
    GameNight.declare_companion_folder("res://phone", "index.html")
```

The host serves pages from a real directory, and an exported game has none:
`declare_companion_folder` copies the folder to `user://` and declares that
copy. It re-declares after every reconnect. Two export settings decide whether
the files are there at all:

- Add the folder to the export preset's include filter
  (`include_filter="phone/*"`), or HTML, JavaScript and CSS files are left out.
- Set images and fonts in that folder to the **Keep File** importer
  (`importer="keep"` in their `.import` files). Otherwise Godot exports only
  its own imported copy and the page loses them. The helper warns about files
  that were imported instead of kept.

Test the exported game, not only the editor project: these settings only show
up there.

`GameNight.send_companion_message(data, player_id)` reaches one phone, or every
phone when `player_id` is empty. Other engines send the same
`declare_companion` and `companion_message` messages; see the
[protocol reference](/docs/protocol#phone-screens).

## In LÖVE

The shared runner declares the page and routes messages when a mode sets
`phone`. A `.love` file is a zip, so the runner copies the folder to the save
directory first and warns when it would not fit a hosted room:

```lua
M.phone = {
    folder = "games/cards_phone",
    message = function(state, player, data, send)
        -- a tap from `player`; answer with send(view, player)
    end,
    presence = function(state, player, connected, send)
        if connected then send(view_for(state, player), player) end
    end,
}
```

## Keep the game in charge

The pattern that worked in Hexstead:

- **The game decides, the phone draws.** After every change, send each player
  their whole view: their hand, what they may do now, whose turn it is. The
  page renders that and sends taps back. Never keep game rules in the page.
- **Send the view again on connect.** Phones reload, sleep and reconnect. On
  `companion_presence` with `connected = true`, send that player their current
  view. Count presence per player: one person can open the page twice.
- **Answer bad moves.** Phone messages are untrusted input. Check every action
  against the rules and send an error back for the page to show.
- **Don't stall the table.** A player without their phone open should not
  block the others. Give them a grace period, then let a bot take the turn.
- **Show the phone player's choices on the TV.** Highlight the places or cards
  the current phone player can pick, so the rest of the table can follow along.
  Private information stays on the phone; the TV shows shared state.

## Fit a hosted room

Hosted rooms forward the page to phones that are not on the PC's network. The
bundle must fit:

| Limit | Value |
| --- | --- |
| Files | at most 128 |
| Each file | at most 512 KiB once base64-encoded (about 384 KB raw) |
| Whole bundle | at most 2 MiB base64-encoded (about 1.5 MB raw) |
| File types | HTML, JavaScript, CSS, JSON, SVG, PNG, JPEG, WebP and WOFF2 |

Use WOFF2 for fonts, not TTF or OTF, and subset them to the characters you use.
Use relative paths only. The page runs in a browser sandbox: no cookies, local
storage, external scripts, forms or navigation of the parent app.
`declare_companion_folder` warns when a file or the folder would not fit.

Keep messages under 16 KB. Send the view, not the history.

## Native phone apps

When the phone side is a whole game of its own, such as a 3D view, declare a
native Android app instead of, or next to, a page:

```gdscript
GameNight.declare_companion(apk_folder, "", {
    "name": "The Voice and the Will",
    "android": "io.ontola.godgame",
    "download": "voice-and-will.apk",
})
```

The GameNight app installs the APK from the PC and opens it. The app then
connects to the game by its own means, for example LAN discovery. Hosted rooms
do not relay that connection, so a native app needs the phone on the same
network as the PC. Ship the APK inside the game's package next to the
executable, and give both the same version, because the game and the app must
speak the same protocol. iOS apps are only possible through the App Store.

Two things that bit us: on macOS, binding a socket to `*` listens on IPv6
only, so bind `0.0.0.0`; and a game with mouse capture needs a way to the
"join as phone" option from a controller.
