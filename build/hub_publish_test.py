import hashlib
import subprocess
import importlib.util
from pathlib import Path
import tempfile
import unittest
import yaml
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("hub_publish", ROOT / "build/hub_publish.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class HubPublishTest(unittest.TestCase):
    def test_publishes_the_verified_release_pack_without_repacking(self):
        version = "0.2.0-alpha.1"
        pack = b"exact embedded pack"
        checksum = f"{hashlib.sha256(pack).hexdigest()}  bee-{version}.wapp\n".encode()
        scratch = ROOT / ".wippy/publish-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            with patch.object(publisher, "download", side_effect=[pack, checksum]) as download, patch.object(publisher.subprocess, "run") as run:
                publisher.publish(version, "fixture-wippy", Path(directory))
                run.assert_called_once()
                command = run.call_args.args[0]
                self.assertEqual(command[:2], ["fixture-wippy", "publish"])
                self.assertEqual(command[-2:], ["--version", version])
                self.assertEqual(command[command.index("--config") + 1], str(ROOT))
                self.assertEqual(Path(command[command.index("--wapp") + 1]).read_bytes(), pack)
                self.assertEqual(download.call_args_list[0].args[0], f"https://github.com/wippyai/bee/releases/download/v{version}/bee-{version}.wapp")

    def test_never_publishes_a_bad_checksum_or_another_filename(self):
        scratch = ROOT / ".wippy/publish-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256(b"pack").hexdigest().encode()
        for checksum in [b"0" * 64 + b"  bee-0.2.0-alpha.1.wapp\n", digest + b"  different.wapp\n", b"bad checksum"]:
            with tempfile.TemporaryDirectory(dir=scratch) as directory:
                with patch.object(publisher, "download", side_effect=[b"pack", checksum]), patch.object(publisher.subprocess, "run") as run:
                    with self.assertRaises(ValueError):
                        publisher.publish("0.2.0-alpha.1", "fixture-wippy", Path(directory))
                    run.assert_not_called()

    def test_workflow_packages_exact_bytes_and_refuses_platform_pack_drift(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())
        package = next(step["run"] for step in workflow["jobs"]["build"]["steps"] if step.get("name") == "Package with checksum")
        verify = next(step["run"] for step in workflow["jobs"]["release"]["steps"] if step.get("name") == "Verify every binary embeds the release pack")
        scratch = ROOT / ".wippy/workflow-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            folder = Path(directory)
            (folder / "dist").mkdir()
            (folder / "dist/bee").write_bytes(b"fixture binary")
            (folder / "dist/bee.wapp").write_bytes(b"fixture embedded pack")
            builder = folder / ".wippy/bin/wippy-builder"
            builder.parent.mkdir(parents=True)
            builder.write_text('#!/bin/sh\ncp "$2" "$4"\n')
            builder.chmod(0o755)
            for target in ["linux-amd64", "darwin-arm64"]:
                subprocess.run(["bash", "-e", "-o", "pipefail", "-c", package], cwd=folder, check=True,
                               env={"PATH": "/usr/bin:/bin", "TARGET": target, "GITHUB_REF_NAME": "v0.2.0-alpha.1"})
            self.assertEqual((folder / "dist/bee-0.2.0-alpha.1.wapp").read_bytes(), b"fixture embedded pack")
            subprocess.run(["bash", "-e", "-o", "pipefail", "-c", verify], cwd=folder, check=True, capture_output=True)
            (folder / "dist/bee-darwin-arm64.wapp.sha256").write_text("0" * 64 + "  bee-0.2.0-alpha.1.wapp\n")
            result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", verify], cwd=folder, capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_release_uploads_and_publishes_the_embedded_pack(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())
        steps = workflow["jobs"]["build"]["steps"]
        uploads = [step["with"]["path"] for step in steps if "actions/upload-artifact@" in step.get("uses", "")]
        self.assertTrue(any(".wapp" in paths for paths in uploads))
        release = workflow["jobs"]["release"]["steps"]
        create = next(step["run"] for step in release if step.get("name") == "Create the release")
        self.assertIn("dist/*.wapp", create)
        self.assertIn(".wapp.sha256", create)
        self.assertTrue(any("sha256sum --check" in step.get("run", "") for step in release))
        self.assertIn("hub-publish:", (ROOT / "Makefile").read_text())

    def test_rejects_a_version_that_can_escape_the_release_directory(self):
        with patch.object(publisher, "download") as download:
            with self.assertRaises(ValueError):
                publisher.publish("../../bad", "fixture-wippy", ROOT / ".wippy/publish-tests")
            download.assert_not_called()


if __name__ == "__main__":
    unittest.main()
