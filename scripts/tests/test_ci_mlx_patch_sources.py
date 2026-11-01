import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import ci_mlx_patch_sources as patch_sources


class VerifyDiffTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        original = root / "original.swift"
        patched = root / "patched.swift"
        original.write_bytes(b"old one\nold two\nold three\nold four\n")
        patched.write_bytes(b"new one\nnew two\n")
        result = subprocess.run(
            ["git", "diff", "--no-index", "--numstat", "-z", str(original), str(patched)],
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        added, removed, _ = result.stdout.split(b"\t", 2)
        self.assertEqual((added, removed), (b"2", b"4"))
        self.relative = "Module.swift"
        self.numstat = b"\t".join((added, removed, self.relative.encode())) + b"\0"

    def verify(self, removed, added):
        relative = self.relative.encode()
        plan = {"relative": self.relative, "removed": removed, "added": added}

        def git(checkout, *args):
            if args == ("diff", "--name-only", "-z", "HEAD", "--"):
                return relative + b"\0"
            if args == ("status", "--porcelain=v1", "-z", "--untracked-files=all"):
                return b" M " + relative + b"\0"
            if args == ("diff", "--summary", "-z", "HEAD", "--"):
                return b""
            if args == ("diff", "--numstat", "-z", "HEAD", "--"):
                return self.numstat
            raise AssertionError((checkout, args))

        def need(condition, message):
            if not condition:
                raise AssertionError(message)

        patch_sources._verify_diff(Path(self.temporary.name), [plan], git, need)

    def test_git_added_then_removed_counts_are_accepted(self):
        self.verify(removed=4, added=2)

    def test_swapped_added_and_removed_counts_are_rejected(self):
        with self.assertRaisesRegex(AssertionError, "approved source change"):
            self.verify(removed=2, added=4)


if __name__ == "__main__":
    unittest.main()
