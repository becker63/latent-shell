"""Exercise the single policy with real temporary Git indexes, offline."""

import contextlib
import io
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.check_source_surface import main, rejected_paths


class SourceSurfaceTests(unittest.TestCase):
    def test_allowlist(self):
        self.assertEqual(
            rejected_paths(
                [
                    b"server/page.py",
                    b"shell/core.mojo",
                    b"flake.nix",
                    b"SPEC.md",
                    b"pyproject.toml",
                    b"flake.lock",
                    b"uv.lock",
                    b".gitignore",
                    b"LICENSE",
                ]
            ),
            [],
        )

    def test_rejects_every_path_sorted(self):
        bad = [
            b"foo.ts",
            b"package.json",
            b"a.sh",
            b"nested/LICENSE",
            b"x.css",
            b"x.html",
            b"x.mjs",
            b"x.yaml",
            b"x.sed",
            b"x.tsx",
            b"x.js",
            b"x.yml",
            b"unknown",
            b"bad\xff.py",
        ]
        self.assertEqual(rejected_paths(bad + [b"foo.ts"]), sorted(bad))

    def test_git_index_is_authority(self):
        previous = os.getcwd()
        with tempfile.TemporaryDirectory() as directory:
            try:
                os.chdir(directory)
                subprocess.run(["git", "init", "-q"], check=True)
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(main(), 1)
                Path("ok.py").touch()
                Path("foo.ts").touch()
                Path(".gitignore").write_text("ignored.js\n")
                subprocess.run(["git", "add", "ok.py", ".gitignore"], check=True)
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(main(), 0)
                subprocess.run(["git", "add", "foo.ts"], check=True)
                Path("child").mkdir()
                os.chdir("child")
                errors = io.StringIO()
                with contextlib.redirect_stderr(errors):
                    self.assertEqual(main(), 1)
                self.assertIn('"foo.ts"', errors.getvalue())
                self.assertIn("Allowed surface:", errors.getvalue())
                os.chdir(directory)
                Path("ignored.js").touch()
                subprocess.run(["git", "add", "--force", "ignored.js"], check=True)
                errors = io.StringIO()
                with contextlib.redirect_stderr(errors):
                    self.assertEqual(main(), 1)
                self.assertIn('"ignored.js"', errors.getvalue())
            finally:
                os.chdir(previous)


if __name__ == "__main__":
    unittest.main()
