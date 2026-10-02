"""Install the patched CPack ZIP into an unused controller-engine directory."""
import argparse, hashlib, json, shutil, tempfile, zipfile
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument("archive",type=Path)
p.add_argument("--root",type=Path,default=Path("E:/gamenight-host/prototypes/mineclonia"))
p.add_argument("--name", choices=["controller-engine", "controller-engine-managed"], default="controller-engine")
a=p.parse_args();a.root.mkdir(parents=True,exist_ok=True)
target=a.root / a.name
if target.exists():raise SystemExit("controller-engine already exists; preserve or move it before replacing the build.")
with tempfile.TemporaryDirectory(dir=a.root) as temp:
    stage=Path(temp).resolve()
    with zipfile.ZipFile(a.archive) as z:
        for member in z.infolist():
            if not (stage / member.filename).resolve().is_relative_to(stage):
                raise SystemExit("Unsafe archive path")
        z.extractall(stage)
    engines=list(stage.glob("*/bin/luanti.exe"))
    if len(engines)!=1:raise SystemExit("Expected one Luanti runtime in CPack ZIP")
    runtime=engines[0].parent.parent
    if not (runtime/"bin/SDL2.dll").is_file():raise SystemExit("SDL2 runtime missing")
    patch=Path(__file__).with_name("controller.patch")
    manifest={"source_commit":"c0e6812b1a4260bb25a1f606f70f55f4962bb97d",
        "sha256":hashlib.sha256(engines[0].read_bytes()).hexdigest(),
        "archive_sha256":hashlib.sha256(a.archive.read_bytes()).hexdigest(),
        "patch_sha256":hashlib.sha256(patch.read_bytes()).hexdigest(),
        "physical_controllers_verified":False}
    (runtime/"gamenight-controller-build.json").write_text(json.dumps(manifest,indent=2))
    shutil.move(str(runtime),target)
print(target)
