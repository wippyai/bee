"""Build a CI adapter for the pinned builder, without editing its module cache.

The overlay adds persistent, fingerprint-checked Lua cache preparation and an
export/import boundary for the generated module. Native builds retain pack
checksum checks, readonly Go compilation, all three fresh-state seed checks,
licenses, provenance, and the upstream package verifier. The upstream source
hash makes a builder pin change fail closed until this adapter is reviewed.
"""
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_HASH = "819c26b64d336c0e62ea9bfee8b4173316648b43a75545d5d3f407e0651445ea"


def adapt(source):
    if hashlib.sha256(source.encode()).hexdigest() != UPSTREAM_HASH:
        raise ValueError("pinned builder build.go changed; review the release adapter")
    start = source.index('\tsource, err := prepareModule(')
    end = source.index('\tbinary :=', start)
    source = source[:start] + '''
	source := os.Getenv("BEE_RELEASE_SOURCE")
	if source == "" {
		source, err = prepareModule(stage, manifest, inputs, toolchain, env)
		if err != nil { return err }
		if err = prepareDependencies(source, env, manifest); err != nil { return err }
	}
''' + source[end:]
    source = source.replace('\tbinary :=', '''
	if destination := os.Getenv("BEE_RELEASE_EXPORT"); destination != "" {
		cache := os.Getenv("BEE_RELEASE_LUA_CACHE")
		seedDigest, _, seedErr := writeLuaCacheSeed(cache, filepath.Join(source, "lua-cache.seed"))
		if seedErr != nil { return seedErr }
		if seedDigest == "" { return fmt.Errorf("CI application preparation produced no Lua seed") }
		generated, generateErr := GenerateWithLuaCacheSeed(manifest, seedDigest)
		if generateErr != nil { return generateErr }
		if err = atomicWrite(filepath.Join(source, "main.go"), generated, 0644); err != nil { return err }
		return os.CopyFS(destination, os.DirFS(source))
	}
	binary :=''')
    start = source.index('\tif !toolchain {\n\t\tvalidationState :=')
    end = source.index('\treturn exportBuild(', start)
    source = source[:start] + '''
	if !toolchain {
		if os.Getenv("BEE_RELEASE_SOURCE") == "" { return fmt.Errorf("compile requires the CI prepared module") }
		if err = verifyLuaCacheSeed(stage, binary, env); err != nil { return err }
	}
''' + source[end:]
    return source


def main():
    pin = subprocess.check_output(['make', '--no-print-directory', 'builder-version'], cwd=ROOT, text=True).strip()
    fingerprint = hashlib.sha256(Path(__file__).read_bytes() + pin.encode() + platform.system().encode() + platform.machine().encode()).hexdigest()
    binary = ROOT / '.wippy/bin/bee-release-builder'
    marker = binary.with_suffix('.fingerprint')
    if binary.is_file() and marker.exists() and marker.read_text() == fingerprint:
        return
    module = json.loads(subprocess.check_output(['go', 'mod', 'download', '-json',
                                                'github.com/wippyai/builder@' + pin], text=True))
    directory = ROOT / '.wippy/release-builder-source'
    if directory.exists():
        # Go module directories are read-only; the copied workspace keeps modes.
        for path in [directory, *directory.rglob('*')]:
            if path.is_dir():
                path.chmod(path.stat().st_mode | stat.S_IWUSR)
        shutil.rmtree(directory)
    shutil.copytree(Path(module['Dir']), directory)
    original = directory / 'internal/assemble/build.go'
    overlay_dir = ROOT / '.wippy/release-overlay'
    overlay_dir.mkdir(parents=True, exist_ok=True)
    replacement = overlay_dir / 'build.go'
    replacement.write_text(adapt(original.read_text()))
    overlay = overlay_dir / 'overlay.json'
    overlay.write_text(json.dumps({'Replace': {str(original): str(replacement)}}))
    # The adapter runs on the host even when its child go build targets Intel.
    host = json.loads(subprocess.check_output(['go', 'env', '-json', 'GOHOSTOS', 'GOHOSTARCH'], text=True))
    environment = dict(os.environ, GOOS=host['GOHOSTOS'], GOARCH=host['GOHOSTARCH'], CGO_ENABLED='0')
    subprocess.run(['go', 'build', '-mod=readonly', '-trimpath', '-buildvcs=false',
                    '-overlay', str(overlay), '-ldflags',
                    '-X github.com/wippyai/builder/internal/assemble.buildRevision=' + pin + '+bee-ci-adapter',
                    '-o', str(binary), './cmd/wippy-builder'], cwd=directory, env=environment, check=True)
    marker.write_text(fingerprint)


if __name__ == '__main__':
    main()
