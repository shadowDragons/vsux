"""Exercise source export boundaries with synthetic repositories and data."""
import ast
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]


class SourceExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vsux-export-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith("GIT_")}
        self.environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        # Use the real export allowlist without copying personal working files.
        script = (PROJECT / "Scripts/prepare-open-source.py").read_text()
        tree = ast.parse(script)
        files = next(ast.literal_eval(node.value) for node in tree.body
                     if isinstance(node, ast.Assign)
                     and any(isinstance(target, ast.Name) and target.id == "files"
                             for target in node.targets))
        for name in files:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("Synthetic public fixture.\n")
        shutil.copy2(PROJECT / "Scripts/prepare-open-source.py",
                     self.root / "Scripts/prepare-open-source.py")
        self.write("web/src/main.js", "export const publicValue = 1;\n")
        self.git("init", "--quiet")
        self.git("add", "--all")
        self.git("-c", "user.name=Export Test", "-c",
                 "user.email=export-test@example.invalid", "commit", "--quiet", "-m", "Fixture")
        self.destination = self.root / "dist/open-source/vsux"

    def write(self, name, text):
        target = self.root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def git(self, *arguments):
        return subprocess.run(["git", *arguments], cwd=self.root, check=True,
                              env=self.environment, capture_output=True, text=True)

    def export(self):
        return subprocess.run([sys.executable, "Scripts/prepare-open-source.py"],
                              cwd=self.root, env=self.environment, capture_output=True, text=True)

    def test_untracked_credentials_and_notes_are_not_exported(self):
        private_files = ["web/.npmrc", "web/private-notes.md", "Sources/local-notes.txt"]
        for name in private_files:
            self.write(name, "SYNTHETIC_PRIVATE_SENTINEL\n")
        result = self.export()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.destination / "web/src/main.js").is_file())
        for name in private_files:
            self.assertFalse((self.destination / name).exists(), name)
        for target in self.destination.rglob("*"):
            if target.is_file():
                self.assertNotIn(b"SYNTHETIC_PRIVATE_SENTINEL", target.read_bytes())

    def test_tracked_credentials_are_rejected_before_any_export(self):
        for name in ["web/.npmrc", "web/.NPMRC", "web/.pypirc", "web/.netrc",
                     "Resources/.aws/config", "Resources/.ssh/config",
                     "web/credentials.json", "Resources/private.PEM"]:
            with self.subTest(name=name):
                self.write(name, "SYNTHETIC_CREDENTIAL\n")
                self.git("add", "--force", "--", name)
                result = self.export()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Unexpected credential path", result.stderr)
                self.assertFalse(self.destination.exists())
                self.git("rm", "--force", "--", name)

    def test_tracked_source_uses_current_working_version(self):
        self.write("web/src/main.js", "export const publicValue = 2;\n")
        result = self.export()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "web/src/main.js").read_text(),
                         "export const publicValue = 2;\n")

    def test_tracked_symlink_cannot_export_private_target(self):
        self.write("private.txt", "SYNTHETIC_PRIVATE_SENTINEL\n")
        (self.root / "web/linked.txt").symlink_to(self.root / "private.txt")
        self.git("add", "web/linked.txt")
        result = self.export()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Not a regular source file", result.stderr)
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
