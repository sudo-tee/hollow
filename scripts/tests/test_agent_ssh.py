import pathlib
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from agent_connectors import ConnectorError, SSH


class SSHConnectorTests(unittest.TestCase):
    def test_connect_uses_strict_non_tty_argv_and_quotes_remote_command(self):
        process = object()
        with patch("agent_connectors.subprocess.Popen", return_value=process) as popen:
            connection = SSH("/opt/agent path/agent\nname", "host.example").connect()
        self.assertIs(connection.process, process)
        popen.assert_called_once_with(
            ["ssh", "-T", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes",
             "-oControlMaster=no", "-oControlPath=none", "-oControlPersist=no",
             "-oRemoteCommand=none", "-oRequestTTY=no", "-oPermitLocalCommand=no",
             "-oClearAllForwardings=yes", "-oForwardAgent=no", "-oForwardX11=no", "-oEscapeChar=none",
             "host.example", "exec '/opt/agent path/agent\nname' stdio"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            bufsize=0, start_new_session=True)

    def test_optional_arguments_and_openssh_config_path_escaping(self):
        process = object()
        with patch("agent_connectors.subprocess.Popen", return_value=process) as popen:
            SSH("/agent", "[2001:db8::1]", 2222, "alice", r"C:\Users\me\id",
                '/tmp/known hosts"%user%', "/tmp/ssh config", "ssh.exe").connect()
        args = popen.call_args.args[0]
        self.assertEqual(args[:10], ["ssh.exe", "-T", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes",
                                     "-oControlMaster=no", "-oControlPath=none", "-oControlPersist=no",
                                     "-oRemoteCommand=none", "-oRequestTTY=no", "-oPermitLocalCommand=no"])
        self.assertEqual(args[10:14], ["-oClearAllForwardings=yes", "-oForwardAgent=no", "-oForwardX11=no", "-oEscapeChar=none"])
        self.assertEqual(args[14:20], ["-F", "/tmp/ssh config", "-i", r"C:\Users\me\id",
                                      "-oIdentitiesOnly=yes", '-oUserKnownHostsFile="/tmp/known hosts\\"%%user%%"'])
        self.assertEqual(args[20:], ["-p", "2222", "-l", "alice", "[2001:db8::1]", "exec /agent stdio"])

    def test_invalid_connector_arguments_are_effect_free(self):
        invalid = (("relative", "host", None, None, None, None, None),
                   ("/agent\0x", "host", None, None, None, None, None),
                   ("/agent", "-host", None, None, None, None, None),
                   ("/agent", "bad host", None, None, None, None, None),
                   ("/agent", "host", True, None, None, None, None),
                   ("/agent", "host", 0, None, None, None, None),
                   ("/agent", "host", None, "-root", None, None, None),
                   ("/agent", "host", None, None, "relative/id", None, None),
                   ("/agent", "host", None, None, None, "/tmp/bad\nfile", None))
        with patch("agent_connectors.subprocess.Popen") as popen:
            for values in invalid:
                with self.subTest(values=values), self.assertRaises(ConnectorError):
                    SSH(*values)
            popen.assert_not_called()

    def test_launch_oserror_is_connector_error_and_close_is_noop(self):
        connector = SSH("/agent", "host")
        with patch("agent_connectors.subprocess.Popen", side_effect=FileNotFoundError("ssh")) as popen:
            with self.assertRaisesRegex(ConnectorError, "cannot launch SSH agent"):
                connector.connect()
            connector.close()
            self.assertEqual(popen.call_count, 1)


if __name__ == "__main__":
    unittest.main()
