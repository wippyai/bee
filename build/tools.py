"""Build a pinned toolchain once and link it into any Bee worktree."""
import argparse
import fcntl
import hashlib
import json
import os
import platform as host_platform
import shutil
from pathlib import Path
import subprocess
import tempfile

if __package__:
    from . import binary_identity
else:
    import binary_identity


def inputs(manifest, builder, platform):
    # Application packs and release versions do not enter a toolchain build.
    return {"runtime": manifest["runtime"], "native": manifest.get("native", []),
            "builder": builder, "platform": platform}


def content_key(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

def platform_inputs():
    systems = {"Linux": "linux", "Darwin": "darwin"}
    architectures = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}
    arch = architectures[host_platform.machine()]
    return {"GOOS": systems[host_platform.system()], "GOARCH": arch,
            "GOAMD64": os.environ.get("GOAMD64", "v1") if arch == "amd64" else "",
            "GOARM": "", "CGO_ENABLED": "1", "CC": os.environ.get("CC", "gcc"),
            "CXX": os.environ.get("CXX", "g++")}


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def import_prebuilt(source, target, value, key):
    marker = source / "bee-tools.json"
    if not marker.exists():
        return False
    record = json.loads(marker.read_text())
    if record.get("key") != key or record.get("inputs") != value:
        return False
    required = {"wippy", "wippy-builder", "wippy.go.mod", "wippy.go.sum", "wippy.provenance.json"}
    if not required.issubset(record.get("artifacts", {})):
        raise ValueError("prebuilt toolchain export is incomplete")
    for name, expected in record["artifacts"].items():
        if Path(name).name != name or digest(source / name) != expected:
            raise ValueError("prebuilt toolchain artifact mismatch: " + name)
    provenance = json.loads((source / "wippy.provenance.json").read_text())
    if (provenance.get("mode") != "toolchain" or provenance.get("schema") != 1
            or provenance["manifest"]["runtime"] != value["runtime"]
            or provenance["manifest"]["native"] != value["native"]
            or digest(source / "wippy.go.mod") != provenance["artifacts"]["go.mod"]):
        raise ValueError("prebuilt toolchain provenance does not match pins")
    binary_identity.generate(value, provenance, (source / "wippy.go.mod").read_bytes(), "0.0.0", "prebuilt")
    for name in record["artifacts"]:
        shutil.copy2(source / name, target / name)
    (target / "inputs.json").write_text(json.dumps(value, indent=2) + "\n")
    return True


def write_marker(binaries, value, key):
    marker = binaries / "bee-tools.json"
    existing = json.loads(marker.read_text()) if marker.exists() else {}
    # Cache links are immutable. Hash only when exporting a different toolchain.
    if existing.get("key") == key and existing.get("inputs") == value:
        artifacts = existing["artifacts"]
    else:
        artifacts = {p.name: digest(p) for p in binaries.iterdir()
                     if p.name != "bee-tools.json" and p.is_file()}
    record = {"key": key, "inputs": value, "artifacts": artifacts}
    marker.write_text(json.dumps(record, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--builder", required=True)
    parser.add_argument("--bin", type=Path, default=Path(".wippy/bin"))
    parser.add_argument("--key", action="store_true")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    environment = dict(os.environ, GOWORK="off", GOTOOLCHAIN="go" + manifest["runtime"]["go"], CGO_ENABLED="1")
    platform = platform_inputs()
    environment.update(platform)
    value = inputs(manifest, args.builder, platform)
    key = content_key(value)
    if args.key:
        print(key)
        return
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "bee-tools"
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / key
    with (cache / (key + ".lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not target.exists():
            print(f"tools: building {key}", flush=True)
            with tempfile.TemporaryDirectory(prefix=key + ".", dir=cache) as directory:
                stage = Path(directory)
                binaries = stage / "bin"
                binaries.mkdir()
                scratch = stage / "scratch"
                scratch.mkdir()
                environment.update(GOBIN=str(binaries), TMPDIR=str(scratch), GOFLAGS="-p=2", GOMAXPROCS="2")
                if import_prebuilt(args.bin, binaries, value, key):
                    print(f"tools: imported verified prebuilt {key}", flush=True)
                else:
                    if not shutil.which("go"):
                        raise RuntimeError("toolchain cache miss: transfer verified .wippy/bin or install pinned Go")
                    subprocess.run(["go", "install", "github.com/wippyai/builder/cmd/wippy-builder@" + args.builder],
                                   env=environment, check=True)
                    subprocess.run([str(binaries / "wippy-builder"), "toolchain", str(args.manifest.resolve()),
                                    "-o", str(binaries / "wippy")], env=environment, check=True)
                (binaries / "inputs.json").write_text(json.dumps(value, indent=2) + "\n")
                binaries.rename(target)
        args.bin.mkdir(parents=True, exist_ok=True)
        for artifact in target.iterdir():
            if artifact.name == "inputs.json":
                continue
            link = args.bin / artifact.name
            if link.is_symlink() and link.resolve() == artifact:
                continue
            pending = args.bin / (artifact.name + ".link")
            pending.unlink(missing_ok=True)
            pending.symlink_to(artifact)
            pending.replace(link)
    write_marker(args.bin, value, key)
    print(f"tools: {key} ({target})")


if __name__ == "__main__":
    main()
