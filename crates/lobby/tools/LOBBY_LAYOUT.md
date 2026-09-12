# Lobby layout

`python tools/layout_lobby.py` regenerates the fixed room map and the Rust
door anchors together. It requires PyYAML. `--check` verifies the checked-in
outputs without writing; CI runs this check.

The ground floor is a clear corridor: Leave at the left and eight reserved
profile door bays. Decorative furniture must not occupy those bays. The
TV and playlist controls stand on the spawn floor, so entering the next game needs no jump. The right-hand steps lead to the music shelves.
All shelf tiles are jump-through: players rise through them and land from above.
Only the floor and outside walls are solid. The QR is a
non-solid wall display above sign-in. Music buttons have their own higher
landing. Player spawns are on the ground floor, close to the TV and playlist controls.

The validator checks door clearance, spacing, control landing clearance and
a sampled staircase jump path using the character's jump speed, air speed,
gravity and 32×48 collision body. These geometric checks prevent layout
regressions; they do not replace controller testing of the physics engine
or visual inspection with all eight pending profiles.

Keep placement deterministic. If themes eventually generate different rooms,
generate furniture around reserved circulation and interaction areas, then
validate those rooms before shipping them.
