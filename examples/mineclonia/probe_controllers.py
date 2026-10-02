"""Read-only controller enumeration using the selected engine's SDL2 library."""
import argparse
import ctypes
import json
from pathlib import Path


def devices(root):
    patched=root / "controller-engine" / "bin" / "SDL2.dll"
    path=patched if patched.exists() else root / "engine/luanti-5.17.0-win64/bin/SDL2.dll"
    sdl=ctypes.CDLL(str(path))
    sdl.SDL_Init.argtypes=[ctypes.c_uint32]
    sdl.SDL_Init.restype=ctypes.c_int
    for fn in ("SDL_IsGameController","SDL_JoystickGetDeviceInstanceID"):
        getattr(sdl,fn).argtypes=[ctypes.c_int]
    for fn in ("SDL_GameControllerNameForIndex","SDL_JoystickPathForIndex"):
        getattr(sdl,fn).argtypes=[ctypes.c_int]
        getattr(sdl,fn).restype=ctypes.c_char_p
    if sdl.SDL_Init(0x00002000 | 0x00000200) != 0:
        raise RuntimeError("SDL controller subsystem did not initialize")
    try:
        result=[]
        for index in range(sdl.SDL_NumJoysticks()):
            name=sdl.SDL_GameControllerNameForIndex(index)
            path=sdl.SDL_JoystickPathForIndex(index)
            result.append({"index":index,"instance_id":sdl.SDL_JoystickGetDeviceInstanceID(index),
                "game_controller":bool(sdl.SDL_IsGameController(index)),
                "name":name.decode("utf-8",errors="replace") if name else None,
                "path":path.decode("utf-8",errors="strict") if path else None})
        return result
    finally:sdl.SDL_Quit()


if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root",type=Path,default=Path("E:/gamenight-host/prototypes/mineclonia"))
    a=p.parse_args();found=devices(a.root)
    print(json.dumps({"devices":found,"count":len(found)},indent=2))
