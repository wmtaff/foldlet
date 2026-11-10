"""macOS regression tests; all paths and process termination are isolated.

Run with: python3 -m unittest discover -s tests -v
"""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "requires macOS PlistBuddy")
class UninstallTests(unittest.TestCase):
    bid = "io.github.wmtaff.foldlet.group.1234abcd"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="foldlet-uninstall-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.groups = self.root / "Applications/Foldlet"
        self.data = self.root / "Application Support/Foldlet"
        self.trash = self.root / "Trash"
        self.bin = self.root / "bin"
        for path in (self.groups, self.data, self.trash, self.bin):
            path.mkdir(parents=True)
        killall = self.bin / "killall"
        killall.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "' + str(self.root / "killall.log") + '"\n')
        killall.chmod(0o755)
        script = (Path(__file__).resolve().parents[1] / "uninstall.sh").read_text()
        for old, new in (
            ('$HOME/Applications/Foldlet', self.groups),
            ('$HOME/Library/Application Support/Foldlet', self.data),
            ('$HOME/.Trash', self.trash),
        ):
            self.assertIn(old, script)
            script = script.replace(old, str(new))
        self.script = self.root / "uninstall.sh"
        self.script.write_text(script)

    def bundle(self, name="Work", **overrides):
        app = self.groups / (name + ".app")
        macos = app / "Contents/MacOS"
        macos.mkdir(parents=True)
        info = dict(FoldletGroup=True, CFBundleIdentifier=self.bid, CFBundleExecutable="Foldlet")
        info.update(overrides)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        exe = macos / "Foldlet"
        exe.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "' + str(self.root / "dock.log") + '"\n')
        exe.chmod(0o755)
        return app

    def run_uninstall(self, expected=0):
        env = os.environ.copy()
        env["PATH"] = str(self.bin) + ":" + env["PATH"]
        result = subprocess.run(["/bin/bash", str(self.script)], env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_preserves_unrelated_files_apps_and_orphaned_data(self):
        app = self.bundle()
        unrelated = self.bundle("Other", FoldletGroup=False)
        note = self.groups / "notes.txt"
        note.write_text("keep this")
        member = self.data / (self.bid + ".json")
        member.write_text("[]")
        orphan = self.data / "io.github.wmtaff.foldlet.group.deadbeef.json"
        orphan.write_text("orphan")
        self.run_uninstall()
        self.assertFalse(app.exists())
        self.assertFalse(member.exists())
        self.assertTrue(unrelated.exists())
        self.assertEqual(note.read_text(), "keep this")
        self.assertEqual(orphan.read_text(), "orphan")
        destination, = self.trash.iterdir()
        self.assertTrue((destination / "Groups/Work.app").is_dir())
        self.assertEqual((destination / "Data" / member.name).read_text(), "[]")
        self.assertEqual((self.root / "dock.log").read_text(), "--remove-all-from-dock\n")

    def test_rejects_invalid_metadata_without_executing_apps(self):
        apps = [self.bundle("WrongID", CFBundleIdentifier="example.other"),
                self.bundle("StringMarker", FoldletGroup="true"),
                self.bundle("WrongExecutable", CFBundleExecutable="Other")]
        self.run_uninstall()
        self.assertTrue(all(app.exists() for app in apps))
        self.assertFalse((self.root / "dock.log").exists())
        self.assertFalse((self.root / "killall.log").exists())
        self.assertEqual(list(self.trash.iterdir()), [])

    def test_preserves_symlinked_app_and_data(self):
        external = self.root / "external"
        external.mkdir()
        (external / "keep.txt").write_text("keep")
        link = self.groups / "External.app"
        link.symlink_to(external, target_is_directory=True)
        app = self.bundle()
        data_link = self.data / (self.bid + ".json")
        data_link.symlink_to(external / "keep.txt")
        self.run_uninstall()
        self.assertFalse(app.exists())
        self.assertTrue(link.is_symlink())
        self.assertTrue(data_link.is_symlink())
        self.assertEqual((external / "keep.txt").read_text(), "keep")

    def test_refuses_symlinked_root_directories(self):
        for directory in (self.groups, self.data, self.trash):
            with self.subTest(directory=directory):
                external = self.root / (directory.parent.name + "-external-" + directory.name)
                external.mkdir()
                directory.rmdir()
                directory.symlink_to(external, target_is_directory=True)
                self.run_uninstall(expected=1)
                self.assertTrue(directory.is_symlink())
                self.assertEqual(list(external.iterdir()), [])
                directory.unlink()
                directory.mkdir()

    def test_removes_empty_containers_and_is_repeatable(self):
        for _ in range(2):
            self.groups.mkdir(parents=True, exist_ok=True)
            self.data.mkdir(parents=True, exist_ok=True)
            self.bundle()
            (self.data / (self.bid + ".json")).write_text("[]")
            self.run_uninstall()
            self.assertFalse(self.groups.exists())
            self.assertFalse(self.data.exists())
        self.assertEqual(len(list(self.trash.iterdir())), 2)
        self.run_uninstall()
        self.assertEqual(len(list(self.trash.iterdir())), 2)

    def test_broken_group_is_trashed_without_running_symlinked_executable(self):
        app = self.bundle()
        executable = app / "Contents/MacOS/Foldlet"
        external = self.root / "external-executable"
        executable.rename(external)
        executable.symlink_to(external)
        result = self.run_uninstall()
        self.assertIn("remove any remaining Foldlet icons manually", result.stderr)
        self.assertFalse((self.root / "dock.log").exists())
        self.assertTrue(external.exists())
        self.assertFalse(app.exists())


if __name__ == "__main__":
    unittest.main()
