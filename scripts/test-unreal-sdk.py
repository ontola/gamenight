#!/usr/bin/env python3
"""Build and test the engine-free core of the Unreal plugin (sdk/unreal).

Unreal itself is not installed in CI. What can be tested without it is the
whole protocol side, which is plain C++17: this builds the core with the flags
an Unreal module uses (no exceptions, no RTTI, warnings as errors), runs its
unit tests, and builds the headless game that drives the core over a real
socket. CI then runs the conformance harness against that binary:

    python3 scripts/test-unreal-sdk.py --headless /tmp/unreal-core
    cargo run -p gamenight-certify -- unreal-core -- /tmp/unreal-core

The Unreal side (UGameNightSubsystem, the demo in examples/unreal-demo) needs
a real Unreal build; see docs/site/unreal.md.
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "sdk/unreal/GameNight/Source/GameNight"
CORE = MODULE / "Private/GameNightCore.cpp"
TESTS = ROOT / "sdk/unreal/tests"
FLAGS = ["-std=c++17", "-Wall", "-Wextra", "-Wshadow", "-Wconversion", "-Wno-sign-conversion",
         "-Werror", "-fno-exceptions", "-fno-rtti", "-I", str(MODULE / "Public")]


def compilers() -> list[str]:
    found = [c for c in (os.environ.get("CXX"), "g++", "clang++") if c and shutil.which(c)]
    return list(dict.fromkeys(found))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--headless", help="also build the headless game to this path")
    args = parser.parse_args()
    cxx = compilers()
    if not cxx:
        print("no C++ compiler (g++ or clang++) found", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory() as temp:
        for compiler in cxx:
            binary = Path(temp) / f"core-test-{Path(compiler).name}"
            subprocess.run([compiler, *FLAGS, "-o", str(binary), str(TESTS / "core_test.cpp"), str(CORE)], check=True)
            subprocess.run([str(binary)], check=True)
            print(f"{compiler}: unreal core tests passed")
    if args.headless:
        subprocess.run([cxx[0], *FLAGS, "-o", args.headless, str(TESTS / "headless_game.cpp"), str(CORE)], check=True)
        print(f"built {args.headless}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
