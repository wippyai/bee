"""Live proof diagnostics and cleanup use the placement ownership boundary."""
import hashlib
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import docker_placement_live


class DockerProofOwnership(unittest.TestCase):
    def test_exact_labels_and_recorded_attempt_scope_inventory(self):
        root = Path(__file__).resolve().parents[1] / '.wippy'
        with tempfile.TemporaryDirectory(dir=root) as directory:
            state = Path(directory)
            placement = state / 'placement'
            placement.mkdir()
            ownership = {'node_id': 'fixture-node', 'state_id': hashlib.sha256(str(placement.resolve()).encode()).hexdigest()}
            (state / 'ownership.json').write_text(json.dumps(ownership))
            with sqlite3.connect(state / 'placement.db') as database:
                database.execute('CREATE TABLE bee_placement_attempts (attempt_id TEXT, placement_kind TEXT)')
                database.execute("INSERT INTO bee_placement_attempts VALUES ('attempt-1', 'docker')")
            labels = {'bee.owner': 'bee.placement.docker.binding:binding', 'bee.node_id': ownership['node_id'],
                      'bee.state_id': ownership['state_id'], 'bee.attempt_id': 'attempt-1'}
            foreign = [dict(labels, **{key: 'foreign'}) for key in labels]
            observations = [labels, *foreign, {}]
            ids = [str(index).rjust(64, '0') for index in range(len(observations))]
            def response(command, **kwargs):
                if command[1] == 'ps':
                    for key, value in labels.items():
                        if key != 'bee.attempt_id':
                            self.assertIn('label=' + key + '=' + value, command)
                    self.assertFalse(any('network=' in arg for arg in command))
                    return '\n'.join(ids)
                self.assertEqual(command[:2], ['docker', 'inspect'])
                return json.dumps(observations[ids.index(command[-1])])
            with patch('docker_placement_live.subprocess.check_output', side_effect=response):
                self.assertEqual(docker_placement_live.owned_containers(state, state), [ids[0]])

    def test_no_ownership_evidence_cannot_select_containers(self):
        with patch('docker_placement_live.subprocess.check_output') as docker:
            self.assertEqual(docker_placement_live.owned_containers(Path('missing-evidence'), Path('missing-state')), [])
            docker.assert_not_called()
