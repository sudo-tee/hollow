import pathlib
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from agent_connectors import ConnectorError, WSL


class WSLConnectorTests(unittest.TestCase):
    def test_connect_uses_exact_native_launcher_argv_without_user(self):
        process = object()
        with patch("agent_connectors.subprocess.Popen", return_value=process) as popen:
            connection = WSL("/opt/hollow/hollow-agent", "Ubuntu").connect()
        self.assertIs(connection.process, process)
        popen.assert_called_once_with(
            ["wsl.exe", "--distribution", "Ubuntu", "--cd", "/", "--exec",
             "/opt/hollow/hollow-agent", "stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            start_new_session=True,
        )

    def test_connect_preserves_nonroot_user_and_override_strings(self):
        process = object()
        with patch("agent_connectors.subprocess.Popen", return_value=process) as popen:
            WSL("/home/test/agent", "Ubuntu-26.04", user="francis",
                executable="C:\\Windows\\System32\\wsl.exe").connect()
        args = popen.call_args.args[0]
        self.assertEqual(args, ["C:\\Windows\\System32\\wsl.exe", "--distribution",
                                "Ubuntu-26.04", "--user", "francis", "--cd", "/",
                                "--exec", "/home/test/agent", "stdio"])
        self.assertTrue(all(type(arg) is str for arg in args))

    def test_invalid_arguments_are_effect_free(self):
        invalid = (
            ("relative/agent", "Ubuntu", None, "wsl.exe"),
            ("/agent\x00bad", "Ubuntu", None, "wsl.exe"),
            ("/agent", "", None, "wsl.exe"),
            ("/agent", "-Ubuntu", None, "wsl.exe"),
            ("/agent", "Ubuntu\x00bad", None, "wsl.exe"),
            ("/agent", "Ubuntu", "", "wsl.exe"),
            ("/agent", "Ubuntu", "-root", "wsl.exe"),
            ("/agent", "Ubuntu", "user\x00bad", "wsl.exe"),
        )
        with patch("agent_connectors.subprocess.Popen") as popen:
            for values in invalid:
                with self.subTest(values=values), self.assertRaises(ConnectorError):
                    WSL(*values)
            popen.assert_not_called()

    def test_close_is_noop(self):
        connector = WSL("/agent", "Ubuntu")
        with patch("agent_connectors.subprocess.Popen") as popen:
            connector.close()
            popen.assert_not_called()

    def test_launch_oserror_becomes_connector_error(self):
        with patch("agent_connectors.subprocess.Popen", side_effect=FileNotFoundError("wsl.exe")):
            with self.assertRaisesRegex(ConnectorError, "cannot launch WSL agent.*wsl.exe"):
                WSL("/agent", "Ubuntu").connect()


if __name__ == "__main__":
    unittest.main()
