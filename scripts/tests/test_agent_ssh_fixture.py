import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from agent_ssh_tests import DEFAULT_IMAGE, FixtureError, SSHFixture


class SSHFixtureTests(unittest.TestCase):
    def test_default_image_is_pinned(self):
        self.assertEqual(DEFAULT_IMAGE, "docker.io/library/alpine:3.21")
        with tempfile.NamedTemporaryFile() as agent:
            with self.assertRaisesRegex(FixtureError, "pinned tag"):
                SSHFixture(agent.name, image="alpine:latest")
            with self.assertRaisesRegex(FixtureError, "pinned tag"):
                SSHFixture(agent.name, image="alpine")

    def test_cleanup_removes_only_owned_random_container_and_tempdir(self):
        directory = tempfile.TemporaryDirectory(prefix="hollow-ssh-test-")
        fixture = SSHFixture.__new__(SSHFixture)
        fixture.podman = "podman"
        fixture.name = "hollow-ssh-test-owned"
        fixture.created = True
        fixture.directory = directory
        with patch.object(fixture, "_run") as run:
            fixture.close()
        run.assert_called_once_with(["rm", "--force", "hollow-ssh-test-owned"],
                                    timeout=30, check=False)
        self.assertFalse(pathlib.Path(directory.name).exists())
        self.assertFalse(fixture.created)

    def test_cleanup_skips_container_not_created_by_fixture(self):
        fixture = SSHFixture.__new__(SSHFixture)
        fixture.created = False
        fixture.directory = None
        with patch.object(fixture, "_run") as run:
            fixture.close()
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
