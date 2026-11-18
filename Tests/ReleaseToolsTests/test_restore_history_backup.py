# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 RaNDoM6913

"""restore-history-backup.sh against disposable folders and a fake process probe (never the real store)."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "restore-history-backup.sh"


class RestoreHistoryBackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name) / "Tilvero"
        self.folder.mkdir()
        self.store = self.folder / "History.sqlite"
        for suffix, content in (("", b"upgraded"), ("-wal", b"log"), ("-shm", b"index")):
            Path(str(self.store) + suffix).write_bytes(content)
        self.backup = self.folder / "History.pre-v3.sqlite"
        self.backup.write_bytes(b"old schema")

    def run_script(self, running: bool, *arguments):
        probe = Path(self.temporary.name) / "pgrep"
        probe.write_text("#!/bin/bash\nexit %d\n" % (0 if running else 1))
        probe.chmod(0o755)
        environment = dict(os.environ, TILVERO_PGREP=str(probe))
        return subprocess.run(["bash", str(SCRIPT), *arguments], capture_output=True, text=True, env=environment)

    def test_restores_the_backup_and_moves_the_current_files_aside(self):
        result = self.run_script(False, str(self.store))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Quit Tilvero", result.stdout)
        self.assertEqual(self.store.read_bytes(), b"old schema")
        self.assertEqual(self.backup.read_bytes(), b"old schema", "The backup itself stays.")
        self.assertFalse(Path(str(self.store) + "-wal").exists())
        aside = sorted(p.name for p in self.folder.iterdir() if p.name.startswith("History.v3-"))
        self.assertEqual(len(aside), 3, aside)
        moved = {name.split(".sqlite")[1]: (self.folder / name).read_bytes() for name in aside}
        self.assertEqual(moved, {"": b"upgraded", "-wal": b"log", "-shm": b"index"})
        self.assertEqual(self.store.stat().st_mode & 0o777, 0o600)

    def test_refuses_while_tilvero_runs_and_changes_nothing(self):
        result = self.run_script(True, str(self.store))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Quit", result.stdout + result.stderr)
        self.assertEqual(self.store.read_bytes(), b"upgraded")
        self.assertFalse(any(p.name.startswith("History.v3-") for p in self.folder.iterdir()))

    def test_refuses_without_a_backup(self):
        self.backup.unlink()
        result = self.run_script(False, str(self.store))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.store.read_bytes(), b"upgraded")


if __name__ == "__main__":
    unittest.main()
