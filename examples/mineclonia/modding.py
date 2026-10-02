"""Generate and validate a bounded Lua mod. Model text is never executable code."""
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid


def generate(values):
    if not isinstance(values, dict) or set(values) != {"bounce"}:
        raise ValueError("Supported recipe: bounce pad with a bounce strength")
    strength = values["bounce"]
    if type(strength) not in (int, float) or not math.isfinite(strength) or not 0 <= strength <= 3:
        raise ValueError("Bounce strength must be between 0 and 3; zero disables the effect")
    # Only this validated number enters a fixed Lua program. No paths, URLs,
    # identifiers, Lua source or free-form strings cross the execution boundary.
    return '''local strength = %s
core.register_node("gamenight_custom:bounce_pad", {
    description = "GameNight bounce pad",
    tiles = {"default_steel_block.png^[colorize:#ad6cfa:180"},
    groups = {cracky=1, pickaxey=1}, _mcl_hardness=1, _mcl_blast_resistance=1,
})
local elapsed = 0
local cooldown = {}
core.register_globalstep(function(dt)
    elapsed = elapsed + dt
    if strength <= 0 then return end
    for _, p in ipairs(core.get_connected_players()) do
        local pos = p:get_pos()
        local below = core.get_node({x=pos.x,y=pos.y-0.2,z=pos.z})
        local name = p:get_player_name()
        if below.name == "gamenight_custom:bounce_pad" and elapsed >= (cooldown[name] or 0) then
            p:add_velocity({x=0,y=8*strength,z=0})
            cooldown[name] = elapsed + 0.8
        end
    end
end)
core.register_on_joinplayer(function(p)
    if strength <= 0 then return end
    local meta = p:get_meta()
    if meta:get_int("gamenight_bounce_pad_given") == 0 then
        local remaining = p:get_inventory():add_item("main", "gamenight_custom:bounce_pad 8")
        if remaining:is_empty() then meta:set_int("gamenight_bounce_pad_given",1) end
    end
end)
''' % format(strength, ".9g")


def stage(root, values):
    source = generate(values)
    digest = hashlib.sha256(source.encode()).hexdigest()
    folder = root / "mods-staged" / digest
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "init.lua").write_text(source, encoding="utf8")
    (folder / "mod.conf").write_text("name = gamenight_custom\ndepends = mcl_core\n", encoding="utf8")
    (folder / "recipe.json").write_text(json.dumps({"version": 1, "values": values, "sha256": digest}))
    return folder, digest


def validate(root, staged):
    """Real Mineclonia startup in a fresh test world. No live save is mounted."""
    world = root / "mod-tests" / uuid.uuid4().hex
    world.mkdir(parents=True)
    (world / "world.mt").write_text("gameid = mineclonia\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\nload_mod_gamenight_custom = true\nload_mod_gamenight_validation = true\n")
    shutil.copytree(staged, world / "worldmods/gamenight_custom")
    harness = world / "worldmods/gamenight_validation"
    harness.mkdir()
    (harness / "mod.conf").write_text("name = gamenight_validation\ndepends = gamenight_custom\n")
    (harness / "init.lua").write_text('''core.register_on_mods_loaded(function()
 assert(core.registered_nodes["gamenight_custom:bounce_pad"], "Missing generated node")
 core.safe_file_write(core.get_worldpath() .. "/validated", "ok")
 core.request_shutdown("Validation complete", false, 0)
end)
''')
    config = world / "test.conf"
    config.write_text("bind_address = 127.0.0.1\nport = 30124\nserver_announce = false\nmg_name = singlenode\n")
    env = {k:v for k,v in os.environ.items() if k not in ("GAMENIGHT_CONTROLLER_FRAME", "GAMENIGHT_CONTROLLER_PATH")}
    env["LUANTI_USER_PATH"] = str(world / "user")
    with (world / "test.log").open("w") as log:
        proc = subprocess.Popen([str(root / "controller-engine-managed/bin/luanti.exe"), "--server",
            "--world", str(world), "--config", str(config)], cwd=root, env=env,
            stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        try: code = proc.wait(timeout=35)
        except subprocess.TimeoutExpired:
            proc.terminate(); proc.wait(timeout=10)
            raise TimeoutError("Generated mod test exceeded 35 seconds")
    if code or not (world / "validated").exists():
        raise RuntimeError("Generated mod failed its isolated engine test; live world unchanged")
    return world


def request(root, values, expected, request_id, seat, expires, instance, undo=False):
    uuid.UUID(request_id)
    # The owned game adapter performs the stop/checkpoint/install/reconnect.
    if undo:
        if values: raise ValueError("Undo does not take new values")
        manifest = json.loads((root / "world/gamenight/mod-current.json").read_text())
        values = manifest.get("previous_values")
        if values is None: raise ValueError("No mod to undo")
    generate(values)
    folder = root / "managed"
    payload = {"id": request_id, "values": values, "expected_revision": expected, "seat": seat, "expires": expires, "instance": instance, "undo": undo}
    temp = folder / "mod-request.tmp"
    temp.write_text(json.dumps(payload))
    temp.replace(folder / "mod-request.json")
    deadline = time.monotonic()+110
    while time.monotonic() < deadline:
        try:
            result = json.loads((folder / "mod-result.json").read_text())
            if result.get("id") == request_id:
                return result
        except (FileNotFoundError, json.JSONDecodeError): pass
        time.sleep(.2)
    raise TimeoutError("Mod restart was not confirmed. Check the host before retrying.")
