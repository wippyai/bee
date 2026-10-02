"""The toolchain guard rebuilds on a stale provenance and stays put on a match."""
import copy
import importlib.util
import json
import unittest
from pathlib import Path


def load_verifier():
    location = Path(__file__).resolve().parent.parent / "build" / "verify_cached_toolchain.py"
    spec = importlib.util.spec_from_file_location("verify_cached_toolchain", location)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verifier = load_verifier()

CURRENT_COMMIT = "c0d6585b5fd1afae7f7cf0b378dc156bcd0e683d"
STALE_COMMIT = "fd1741b10000000000000000000000000000000000"
LOCK_COMMIT = "114eb0252a121dd89eca084af5db01833ffff50b"


def manifest(commit=CURRENT_COMMIT):
    return {
        "schema": 1,
        "name": "bee",
        "runtime": {
            "repository": "https://github.com/wippyai/runtime.git",
            "commit": commit,
            "go": "1.27.0",
            "tags": ["fts5"],
        },
        "native": [],
    }


def write(root, manifest_data, provenance_manifest):
    (root / "wippy.build.json").write_text(json.dumps(manifest_data))
    lock_dir = root / "build"
    lock_dir.mkdir(parents=True, exist_ok=True)
    (lock_dir / "builder.lock.json").write_text(
        json.dumps({"repository": "https://github.com/wippyai/builder.git", "commit": LOCK_COMMIT})
    )
    if provenance_manifest is not None:
        bin_dir = root / ".wippy" / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)
        (bin_dir / "bee-wippy.provenance.json").write_text(
            json.dumps({"schema": 1, "mode": "toolchain", "manifest": provenance_manifest})
        )


class ToolchainCurrentTest(unittest.TestCase):
    def test_local_build_rejects_the_pinned_binary_and_accepts_its_own_manifest(self):
        import tempfile

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pinned = manifest()
            local = copy.deepcopy(pinned)
            local["native"] = [{"module": "example/native", "version": "local-version"}]
            write(root, pinned, pinned)
            folder = root / ".wippy/local-native"
            folder.mkdir(parents=True)
            (folder / "bee.build.json").write_text(json.dumps(local))
            with self.assertRaises(ValueError):
                verifier.check_current(root, local=True)
            write(root, pinned, local)
            verifier.check_current(root, local=True)
            with self.assertRaises(ValueError):
                verifier.check_current(root)

    def test_matching_provenance_needs_no_rebuild(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, manifest(), manifest())
            verifier.check_current(root)

    def test_stale_runtime_commit_triggers_rebuild(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, manifest(CURRENT_COMMIT), manifest(STALE_COMMIT))
            with self.assertRaises(ValueError):
                verifier.check_current(root)

    def test_missing_provenance_triggers_rebuild(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, manifest(), None)
            with self.assertRaises(ValueError):
                verifier.check_current(root)

    def test_application_packs_do_not_trigger_rebuild(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            current = manifest()
            cached = copy.deepcopy(current)
            cached["application"] = {"module": "bee/bee", "packs": [{"module": "bee/bee"}]}
            write(root, current, cached)
            verifier.check_current(root)


if __name__ == "__main__":
    unittest.main()
