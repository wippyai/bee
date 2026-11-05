"""Cold Docker fixtures are installed before timed placement entries run."""
import subprocess
import unittest
from unittest import mock

from tests.runner import docker_fixture as docker

IMAGE = 'node@sha256:' + 'a' * 64


def document():
    return {'namespace': 'fixture', 'entries': [
        {'name': 'readiness', 'meta': {'type': 'test', 'resources': ['docker_daemon']}},
        {'name': 'plain', 'meta': {'type': 'test'}},
        {'name': 'executor', 'kind': 'exec.docker', 'meta': {'type': 'test_support'}, 'image': IMAGE},
        {'name': 'refused_executor', 'kind': 'exec.docker', 'meta': {'type': 'test_support'}, 'image': IMAGE},
        {'name': 'product_executor', 'kind': 'exec.docker', 'image': 'product:latest'},
    ]}


class DockerFixtureTests(unittest.TestCase):
    def test_readiness_alone_installs_the_pinned_fixture_once_and_warm_runs_use_it(self):
        with mock.patch.object(docker, 'present', side_effect=[False, True]) as present, \
                mock.patch.object(docker.subprocess, 'run') as run:
            for _ in range(2):
                docker.prepare([document()], {'fixture:readiness'})
        self.assertEqual(present.call_args_list, [mock.call(IMAGE), mock.call(IMAGE)])
        run.assert_called_once_with(['docker', '--host', 'unix:///var/run/docker.sock', 'pull', IMAGE], check=True)

    def test_other_shards_do_not_contact_docker(self):
        with mock.patch.object(docker, 'present') as present, mock.patch.object(docker.subprocess, 'run') as run:
            docker.prepare([document()], {'fixture:plain'})
        present.assert_not_called()
        run.assert_not_called()

    def test_floating_fixture_tags_fail_before_contacting_docker(self):
        value = document()
        value['entries'][2]['image'] = 'node:latest'
        with mock.patch.object(docker, 'present') as present, self.assertRaisesRegex(ValueError, 'digest-pinned'):
            docker.prepare([value], {'fixture:readiness'})
        present.assert_not_called()

    def test_a_pull_failure_stops_setup_without_another_attempt(self):
        failure = subprocess.CalledProcessError(1, ['docker', 'pull', IMAGE])
        with mock.patch.object(docker, 'present', return_value=False), \
                mock.patch.object(docker.subprocess, 'run', side_effect=failure) as run, \
                self.assertRaises(subprocess.CalledProcessError):
            docker.prepare([document()], {'fixture:readiness'})
        self.assertEqual(run.call_count, 1)

    def test_inspection_distinguishes_absence_from_a_daemon_failure(self):
        for status, expected in ((200, True), (404, False), (500, None)):
            with self.subTest(status=status), mock.patch.object(docker, 'Connection') as connection:
                client = connection.return_value
                response = client.getresponse.return_value
                response.status = status
                response.read.return_value = b'{"message":"fixture daemon failure"}'
                if expected is None:
                    with self.assertRaisesRegex(RuntimeError, '500.*fixture daemon failure'):
                        docker.present(IMAGE)
                else:
                    self.assertEqual(docker.present(IMAGE), expected)
                client.close.assert_called_once()


    def test_teardown_removes_only_the_containers_that_mount_the_shard(self):
        shard = '/work/tests/.wippy/runs/run/shard-01'
        listed = [
            {'Id': 'a' * 64, 'Mounts': [{'Type': 'bind', 'Source': shard + '/.wippy/placement-project'}]},
            {'Id': 'b' * 64, 'Mounts': [{'Type': 'bind', 'Source': shard + '-other/.wippy/placement-project'}]},
            {'Id': 'c' * 64, 'Mounts': [{'Type': 'volume', 'Source': '/var/lib/docker/volumes/pg/_data'}]},
            {'Id': 'd' * 64, 'Mounts': []},
        ]
        calls = []

        def request(method, path):
            calls.append((method, path))
            return listed if method == 'GET' else None
        with mock.patch.object(docker, 'request', side_effect=request):
            removed = docker.teardown(shard)
        self.assertEqual(removed, ['a' * 64])
        self.assertEqual(calls, [('GET', '/containers/json?all=true'), ('DELETE', '/containers/' + 'a' * 64 + '?force=true')])

    def test_teardown_reports_a_refused_removal(self):
        shard = '/work/shard-01'
        listed = [{'Id': 'a' * 64, 'Mounts': [{'Type': 'bind', 'Source': shard + '/x'}]}]

        def request(method, path):
            if method == 'GET':
                return listed
            raise RuntimeError('Docker HTTP 409: removal refused')
        with mock.patch.object(docker, 'request', side_effect=request), \
                self.assertRaisesRegex(RuntimeError, '409: removal refused'):
            docker.teardown(shard)

    def test_requests_report_daemon_failures_with_their_body(self):
        with mock.patch.object(docker, 'Connection') as connection:
            response = connection.return_value.getresponse.return_value
            response.status = 409
            response.read.return_value = b'{"message":"container is in use"}'
            with self.assertRaisesRegex(RuntimeError, '409.*container is in use'):
                docker.request('DELETE', '/containers/x?force=true')
            response.status = 204
            response.read.return_value = b''
            self.assertIsNone(docker.request('DELETE', '/containers/x?force=true'))


if __name__ == '__main__':
    unittest.main()
