import pathlib
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from agent_connectors import ConnectorError, Docker
from agent_docker_tests import DockerFixture


class DockerTests(unittest.TestCase):
    def test_pins_running_id_and_preserves_context_on_reconnect(self):
        identifier = "a" * 64
        probe = Mock(returncode=0, stdout=(identifier.upper() + " true\n").encode())
        with patch("agent_connectors.subprocess.run", return_value=probe) as run, patch("agent_connectors.subprocess.Popen") as popen:
            connector = Docker("/opt/a 'agent\n", "worker", "/opt/docker cli", "remote context")
            connector.connect()
            connector.connect()
            self.assertEqual(run.call_args.args[0][-1], identifier)
            self.assertEqual(popen.call_args.args[0], ["/opt/docker cli", "--context", "remote context", "exec", "-i", identifier, "/opt/a 'agent\n", "stdio"])
            connector.close()
            self.assertEqual(run.call_count, 2)  # No lifecycle commands on close.

    def test_inspect_failures_never_launch_agent(self):
        for output in (b"short true", b"a" * 64 + b" false", b"a" * 64 + b" true extra"):
            with self.subTest(output=output), patch("agent_connectors.subprocess.run", return_value=Mock(returncode=0, stdout=output)), patch("agent_connectors.subprocess.Popen") as popen:
                with self.assertRaises(ConnectorError):
                    Docker("/agent", "worker").connect()
                popen.assert_not_called()

    def test_bad_arguments_have_no_effects_and_missing_tool_is_diagnosed(self):
        with patch("agent_connectors.subprocess.run") as run:
            for values in (("relative", "worker"), ("/a\0", "worker"), ("/agent", "--help"), ("/agent", "bad/name"), ("/agent", "worker", "docker", "-context")):
                with self.subTest(values=values), self.assertRaises(ConnectorError):
                    Docker(*values)
            run.assert_not_called()
        with patch("agent_connectors.subprocess.run", side_effect=FileNotFoundError("docker")):
            with self.assertRaisesRegex(ConnectorError, "cannot launch Docker"):
                Docker("/agent", "worker").connect()

    def test_fixture_validates_and_only_removes_owned_id(self):
        for image in ("alpine", "alpine:latest"):
            with self.assertRaises(ConnectorError):
                DockerFixture(image=image)
        with self.assertRaises(ConnectorError):
            DockerFixture(user="root")
        fixture = DockerFixture(context="test")
        with patch.object(fixture, "run") as run:
            fixture.close()
            run.assert_not_called()
            fixture.container = "b" * 64
            fixture.close()
            run.assert_called_once_with(["rm", "--force", "b" * 64], check=False)

    def test_fixture_creation_failure_checks_label_before_cleanup(self):
        for owned in (False, True):
            fixture = DockerFixture()
            identifier = "c" * 64
            label = fixture.token if owned else "somebody-else"
            with patch.object(fixture, "run", side_effect=[ConnectorError("lost creation result"), Mock(returncode=0, stdout=f"{identifier} {label}\n".encode()), Mock(returncode=0)]) as run:
                with self.assertRaises(ConnectorError):
                    fixture.start()
                fixture.close()
                self.assertEqual(run.call_count, 3 if owned else 2)
                if owned:
                    self.assertEqual(run.call_args.args[0], ["rm", "--force", identifier])

    def test_fixture_start_preserves_selected_user_context_and_id(self):
        fixture = DockerFixture(context="build", user="1000:1000")
        identifier = "d" * 64
        with patch("agent_docker_tests.subprocess.run", return_value=Mock(returncode=0, stdout=(identifier + "\n").encode())) as run:
            fixture.start()
        create = run.call_args_list[0].args[0]
        self.assertEqual(create[:4], ["docker", "--context", "build", "create"])
        self.assertEqual(create[create.index("--user") + 1], "1000:1000")
        self.assertEqual(create[create.index("--env") + 1], "HOME=/tmp")
        self.assertEqual(run.call_args.args[0], ["docker", "--context", "build", "start", identifier])


if __name__ == "__main__":
    unittest.main()
