"""Unit compositions exclude ambient provider homes, binaries and state."""
from pathlib import Path
import os
import tempfile
import unittest
from unittest.mock import patch

from fixture_lint import environment
from workspace import ROOT


class FixtureEnvironmentTest(unittest.TestCase):
    def test_ambient_provider_state_is_not_inherited(self):
        parent = ROOT / ".wippy/test-environment"
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as directory:
            with patch.dict(os.environ, {"HOME": "/host-home", "PATH": "/host-bin",
                                        "CODEX_HOME": "/host-codex", "CLAUDE_CONFIG_DIR": "/host-claude",
                                        "XDG_CONFIG_HOME": "/host-config", "ANTHROPIC_API_KEY": "host-value"}, clear=True):
                child = environment(Path(directory))
            self.assertEqual(child["PATH"], str(Path(directory) / "fixtures/harness/bin") + ":/usr/bin:/bin")
            self.assertEqual(child["HOME"], str(Path(directory) / "host-home"))
            self.assertEqual(child["XDG_CONFIG_HOME"], str(Path(directory) / "host-home/.config"))
            self.assertNotIn("CODEX_HOME", child)
            self.assertNotIn("CLAUDE_CONFIG_DIR", child)
            self.assertNotIn("ANTHROPIC_API_KEY", child)


if __name__ == "__main__":
    unittest.main()
