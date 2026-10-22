"""Permission controls are backed by captured installed CLI help."""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests/fixtures/driver-options"


class AllAllowedOptions(unittest.TestCase):
    def test_full_permission_mappings_have_help_evidence_and_person_consent(self):
        cases = [
            ("claude", "permission_mode", "bypassPermissions", "claude-2.1.296-help.txt", "--permission-mode"),
            ("claude", "permission_bypass", True, "claude-2.1.296-help.txt", "--dangerously-skip-permissions"),
            ("codex", "dangerously_bypass_approvals_and_sandbox", True, "codex-0.160.1-help.txt", "--dangerously-bypass-approvals-and-sandbox"),
            ("agy", "dangerously_skip_permissions", True, "agy-1.3.5-help.txt", "--dangerously-skip-permissions"),
            ("grok", "permission_mode", "bypassPermissions", "grok-1.0.30-help.txt", "--permission-mode"),
            ("opencode", "auto", True, "opencode-1.18.32-help.txt", "--auto"),
            ("opencode", "auto", True, "opencode-1.18.32-run-help.txt", "--auto"),
            ("muse", "yolo", True, "muse-1.4.8-help.txt", "--yolo"),
            ("muse", "yolo", True, "muse-1.4.8-exec-help.txt", "--yolo"),
        ]
        for driver, name, value, capture, flag in cases:
            with self.subTest(driver=driver, option=name, capture=capture):
                entries = yaml.safe_load((ROOT / f"drivers/src/{driver}/descriptor/_index.yaml").read_text())["entries"]
                descriptor = next(entry["data"] for entry in entries if entry["name"] == "cli")
                field = descriptor["options"]["fields"][name]
                self.assertIn(flag, (FIXTURES / capture).read_text())
                self.assertEqual(field["security_class"], "host-ceiling")
                self.assertIn(value, field.get("person_values", []))
                self.assertEqual(field["support"]["help_probe"]["flag"], flag)

    def test_every_cli_driver_has_a_full_permission_case(self):
        drivers = {p.parent.parent.name for p in (ROOT / "src/driver").glob("*/descriptor/_index.yaml")}
        self.assertEqual(drivers, {"claude", "codex", "agy", "grok", "opencode", "muse"})
