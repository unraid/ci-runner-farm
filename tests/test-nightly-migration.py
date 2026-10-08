import json
import os

# Executes only repository fixtures without a shell.
import subprocess  # nosec B404
import tempfile
import unittest
from pathlib import Path


class NativeNightlyMigrationTests(unittest.TestCase):
    def test_legacy_inventory_is_validated_before_install_and_archived_before_removal(
        self,
    ):
        source = (
            Path("install-nightly.sh")
            .read_text()
            .split("<<'REMOTE'\n", 1)[1]
            .split("\nREMOTE", 1)[0]
        )
        for mode in [
            "old",
            "matching",
            "unknown-runtime",
            "unknown-duplicate",
            "runtime-only",
            "install-failure",
        ]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                boot = root / "boot"
                runtime = root / "runtime"
                boot.mkdir()
                runtime.mkdir()
                canonical = boot / "ci-runner-farm.plg"
                duplicate = boot / "ci-runner-farm-nightly.plg"
                legacy_runtime = runtime / "ci-runner-farm-nightly.plg"
                canonical.write_text("old")
                if mode != "runtime-only":
                    duplicate.write_text(
                        "foreign"
                        if mode == "unknown-duplicate"
                        else "new" if mode == "matching" else "old"
                    )
                legacy_runtime.write_text(
                    "foreign" if mode == "unknown-runtime" else "old"
                )
                incoming = root / "incoming.plg"
                incoming.write_text("new")
                executable = root / "bin"
                executable.mkdir()
                marker = root / "installed"
                (executable / "id").write_text("#!/bin/sh\necho 0\n")
                (executable / "plugin").write_text(
                    '#!/bin/sh\ntouch "$INSTALL_MARKER"\n'
                    'test "$INSTALL_FAILURE" != yes || exit 1\n'
                    'cp "$2" "$CANONICAL"\n'
                )
                for file in executable.iterdir():
                    file.chmod(0o700)
                script = source.replace("/boot/config/plugins", str(boot)).replace(
                    "/var/log/plugins", str(runtime)
                )
                env = {
                    **os.environ,
                    "PATH": str(executable) + ":" + os.environ["PATH"],
                    "INSTALL_MARKER": str(marker),
                    "CANONICAL": str(canonical),
                    "INSTALL_FAILURE": "yes" if mode == "install-failure" else "no",
                }
                result = subprocess.run(  # nosec
                    ["bash", "-s", "--", str(incoming)],
                    input=script,
                    text=True,
                    capture_output=True,
                    env=env,
                    timeout=10,
                )
                if mode.startswith("unknown"):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(marker.exists(), result.stderr)
                    self.assertTrue(duplicate.exists())
                    self.assertTrue(legacy_runtime.exists())
                elif mode == "install-failure":
                    self.assertNotEqual(result.returncode, 0)
                    self.assertTrue(duplicate.exists())
                    self.assertTrue(legacy_runtime.exists())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(canonical.read_text(), "new")
                    self.assertFalse(duplicate.exists())
                    self.assertFalse(legacy_runtime.exists())
                    saved = list(
                        (boot / "ci-runner-farm/descriptor-backups").glob("*.plg")
                    )
                    self.assertTrue(any(file.read_text() == "old" for file in saved))

    def test_actual_provider_root_validation_rejects_trailing_newline(self):
        source = Path(
            "src/usr/local/emhttp/plugins/ci-runner-farm/include/shared-capacity.sh"
        ).read_text()
        script = source.split("shared_capacity_call() {", 1)[1]
        script = script.split("php -r '\n", 1)[1].split("\n  '", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = script.replace(
                "/boot/config/plugins/qa-vm-service/", str(root) + "/"
            )
            script = script.replace(
                "fileowner($file)!==0", f"fileowner($file)!=={os.geteuid()}"
            )
            for value, valid in [
                ("/mnt/cache/appdata/qa-vm-service", True),
                ("/mnt/cache/appdata/qa-vm-service\n", False),
            ]:
                for name, document in [
                    ("host-policy.json", {"providerConfig": {"stateRoot": value}}),
                    (
                        "host-plan.json",
                        {"manifest": {"providerConfig": {"stateRoot": value}}},
                    ),
                ]:
                    file = root / name
                    file.write_text(json.dumps(document))
                    file.chmod(0o600)
                result = subprocess.run(  # nosec
                    ["php", "-r", script],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                self.assertEqual(result.returncode == 0, valid, result.stderr)


if __name__ == "__main__":
    unittest.main()
