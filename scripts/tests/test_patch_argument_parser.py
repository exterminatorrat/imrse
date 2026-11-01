import ast
import hashlib
import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = ROOT / "scripts/patch-argument-parser.py"
SPEC = importlib.util.spec_from_file_location("patch_argument_parser", HELPER_PATH)
helper = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = helper
SPEC.loader.exec_module(helper)


class ApprovedContractTests(unittest.TestCase):
    def test_ast_receipt_is_a_literal_matching_the_reviewed_patch(self):
        tree = ast.parse(HELPER_PATH.read_text(encoding="utf-8"))
        assignment = next(
            node
            for node in tree.body
            if isinstance(node, ast.Assign)
            and any(isinstance(target, ast.Name) and target.id == "APPROVED_PATCH" for target in node.targets)
        )
        receipt = ast.literal_eval(assignment.value)
        self.assertEqual(receipt, helper.APPROVED_PATCH)
        expected_bytes = (
            json.dumps(receipt, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode("utf-8")
        self.assertEqual(helper._receipt_bytes(), expected_bytes)
        self.assertEqual(receipt["schemaVersion"], 1)
        self.assertEqual(receipt["identity"], "swift-argument-parser")
        self.assertEqual(receipt["version"], "1.8.2")
        self.assertEqual(receipt["url"], "https://github.com/apple/swift-argument-parser")
        self.assertEqual(receipt["revision"], "6a52f3251125d74daf04fcbd5e6f08a75d074382")
        self.assertEqual(
            receipt["license"],
            {
                "path": "LICENSE.txt",
                "sha256": "770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55",
            },
        )
        self.assertEqual(
            receipt["files"],
            [
                {
                    "path": "Sources/ArgumentParser/Parsable Types/ParsableArguments.swift",
                    "originalSHA256": "1ad16fa584662bfe539dbbce2e2b9d305af40856f433a60439ecad71e4c9087e",
                    "patchedSHA256": "fe0fe8c9f106514a8356f5b6a4e91b4d6a276f5c0fbd20cac17614b439830947",
                    "originalSize": 12518,
                    "patchedSize": 12452,
                    "removedAnnotation": '@available(*, deprecated, message: "Use _errorPrefix instead.")',
                },
                {
                    "path": "Sources/ArgumentParserToolInfo/ToolInfo.swift",
                    "originalSHA256": "fb87e458c14843a319ba76ad5a95aff76628215251318d0c1b9d68e083235dd0",
                    "patchedSHA256": "bcc212e4059ee0797ba0338bf40bb89d83d584ea39d99a33a44b28ccc614547b",
                    "originalSize": 9575,
                    "patchedSize": 9513,
                    "removedAnnotation": '@available(*, deprecated, message: "Use custom instead.")',
                },
            ],
        )
        for file_spec, (old_hunk, new_hunk) in zip(receipt["files"], helper.PATCH_HUNKS):
            annotation = file_spec["removedAnnotation"].encode("utf-8")
            self.assertEqual(old_hunk.rstrip(b"\n").lstrip(), annotation)
            self.assertTrue(old_hunk.endswith(b"\n"))
            self.assertEqual(new_hunk, b"")


class FixtureRepairTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "source"
        self.candidate = self.base / "candidate"
        self.checkout = self.root / ".build/checkouts/swift-argument-parser"
        self.root.mkdir()
        self.candidate.mkdir()
        self.checkout.mkdir(parents=True)
        self.receipt_path = self.candidate / "swift-argument-parser-COMPATIBILITY.json"

        self.first_path = "Sources/ArgumentParser/Parsable Types/ParsableArguments.swift"
        self.second_path = "Sources/ArgumentParserToolInfo/ToolInfo.swift"
        self.first_annotation = b'  @available(*, deprecated, message: "Use _errorPrefix instead.")\n'
        self.second_annotation = b'    @available(*, deprecated, message: "Use custom instead.")\n'
        self.first_original = b"header\n" + self.first_annotation + b"requirement\n"
        self.second_original = b"header\n" + self.second_annotation + b"case customDeprecated\n"
        self.first_patched = self.first_original.replace(self.first_annotation, b"", 1)
        self.second_patched = self.second_original.replace(self.second_annotation, b"", 1)
        self.license = b"fixture license text\n"

        self.approved_patch = {
            "schemaVersion": 1,
            "identity": "swift-argument-parser",
            "version": "1.8.2",
            "url": "https://github.com/apple/swift-argument-parser",
            "revision": "fixture-revision",
            "license": {"path": "LICENSE.txt", "sha256": hashlib.sha256(self.license).hexdigest()},
            "files": [
                {
                    "path": self.first_path,
                    "originalSHA256": hashlib.sha256(self.first_original).hexdigest(),
                    "patchedSHA256": hashlib.sha256(self.first_patched).hexdigest(),
                    "originalSize": len(self.first_original),
                    "patchedSize": len(self.first_patched),
                    "removedAnnotation": self.first_annotation.decode("utf-8").strip(),
                },
                {
                    "path": self.second_path,
                    "originalSHA256": hashlib.sha256(self.second_original).hexdigest(),
                    "patchedSHA256": hashlib.sha256(self.second_patched).hexdigest(),
                    "originalSize": len(self.second_original),
                    "patchedSize": len(self.second_patched),
                    "removedAnnotation": self.second_annotation.decode("utf-8").strip(),
                },
            ],
        }
        self.hunks = (
            (self.first_annotation, b""),
            (self.second_annotation, b""),
        )
        self.files = {}
        self.modes = {self.first_path: 0o444, self.second_path: 0o640}
        for relative, contents in ((self.first_path, self.first_original), (self.second_path, self.second_original)):
            path = self.checkout / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
            path.chmod(self.modes[relative])
            self.files[relative] = path
        (self.checkout / "LICENSE.txt").write_bytes(self.license)
        lock = {
            "pins": [
                {
                    "identity": self.approved_patch["identity"],
                    "kind": "remoteSourceControl",
                    "location": self.approved_patch["url"],
                    "state": {
                        "revision": self.approved_patch["revision"],
                        "version": self.approved_patch["version"],
                    },
                }
            ]
        }
        (self.root / "Package.resolved").write_text(json.dumps(lock), encoding="utf-8")

        self.revision = self.approved_patch["revision"]
        self.dirty = False
        self.pretend_clean = False
        for name, value in (
            ("APPROVED_PATCH", self.approved_patch),
            ("PATCH_HUNKS", self.hunks),
            ("LICENSE_SIZE", len(self.license)),
        ):
            change = patch.object(helper, name, value)
            change.start()
            self.addCleanup(change.stop)
        git_patch = patch.object(helper, "_run_git", side_effect=self.fake_git)
        git_patch.start()
        self.addCleanup(git_patch.stop)

    def fake_git(self, checkout, *arguments):
        if arguments == ("rev-parse", "--show-toplevel"):
            return str(checkout).encode("utf-8") + b"\n"
        if arguments == ("rev-parse", "HEAD"):
            return self.revision.encode("utf-8") + b"\n"
        changed = sorted(
            relative
            for relative, path in self.files.items()
            if path.read_bytes() != (self.first_original if relative == self.first_path else self.second_original)
        )
        if arguments[:1] == ("status",):
            if self.dirty:
                return b"?? unrelated\0"
            if self.pretend_clean:
                return b""
            entries = [(relative, b" M " + os.fsencode(relative) + b"\0") for relative in changed]
            for path in checkout.rglob(".imrse-argument-parser-*"):
                if path.is_file():
                    relative = path.relative_to(checkout).as_posix()
                    entries.append((relative, b"?? " + os.fsencode(relative) + b"\0"))
            return b"".join(record for _, record in sorted(entries))
        if arguments[:3] == ("diff", "--name-only", "-z"):
            return b"".join(relative.encode("utf-8") + b"\0" for relative in changed)
        if arguments[:3] == ("diff", "--summary", "-z"):
            return b""
        raise AssertionError(f"unexpected Git query: {arguments}")

    def host(self, authorized=True):
        environment = {
            "GITHUB_ACTIONS": "true",
            "RUNNER_ENVIRONMENT": "github-hosted" if authorized else "self-hosted",
            "RUNNER_OS": "macOS",
            "RUNNER_ARCH": "ARM64",
        }
        return (
            patch.dict(os.environ, environment),
            patch.object(helper.platform, "system", return_value="Darwin"),
            patch.object(helper.platform, "machine", return_value="arm64"),
        )

    def invoke(self, verify_only=False, authorized=True):
        patches = self.host(authorized)
        for active in patches:
            active.start()
        try:
            return helper.patch_dependency(self.root, self.receipt_path, verify_only=verify_only)
        finally:
            for active in reversed(patches):
                active.stop()

    def snapshot(self):
        return {
            str(path.relative_to(self.base)): (path.read_bytes(), stat.S_IMODE(path.stat().st_mode))
            for path in self.base.rglob("*")
            if path.is_file()
        }

    def assert_rejected_without_writes(self, **options):
        before = self.snapshot()
        with self.assertRaises(helper.PatchError):
            self.invoke(**options)
        self.assertEqual(self.snapshot(), before)

    def test_apply_writes_only_two_files_and_exact_receipt_then_verifies_read_only(self):
        self.invoke()
        self.assertEqual(self.files[self.first_path].read_bytes(), self.first_patched)
        self.assertEqual(self.files[self.second_path].read_bytes(), self.second_patched)
        for relative, mode in self.modes.items():
            self.assertEqual(stat.S_IMODE(self.files[relative].stat().st_mode), mode)
        expected_receipt = (
            json.dumps(self.approved_patch, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode("utf-8")
        self.assertEqual(self.receipt_path.read_bytes(), expected_receipt)
        self.assertEqual(json.loads(self.receipt_path.read_text(encoding="utf-8")), self.approved_patch)
        self.assertEqual(list(self.checkout.rglob(".imrse-argument-parser-*")), [])
        before_verification = self.snapshot()
        self.invoke(verify_only=True)
        self.assertEqual(self.snapshot(), before_verification)

    def test_mismatched_revision_fails_before_writing(self):
        self.revision = "not-the-approved-revision"
        self.assert_rejected_without_writes()

    def test_mismatched_source_hash_fails_before_writing(self):
        self.files[self.first_path].chmod(0o644)
        self.files[self.first_path].write_bytes(b"unexpected source bytes")
        self.pretend_clean = True
        self.assert_rejected_without_writes()

    def test_dirty_dependency_checkout_fails_before_writing(self):
        self.dirty = True
        self.assert_rejected_without_writes()

    def test_fixture_git_status_reports_staged_temporary_as_untracked(self):
        staged = self.checkout / ".imrse-argument-parser-fixture"
        staged.write_bytes(b"staged bytes")
        try:
            status = self.fake_git(
                self.checkout,
                "status",
                "--porcelain=v1",
                "-z",
                "--untracked-files=all",
            )
            self.assertEqual(status, b"?? .imrse-argument-parser-fixture\0")
        finally:
            staged.unlink()

    def test_unauthorized_host_fails_before_writing(self):
        self.assert_rejected_without_writes(authorized=False)

    def test_mismatched_root_lock_pin_fails_before_writing(self):
        lock_path = self.root / "Package.resolved"
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
        lock["pins"][0]["state"]["revision"] = "not-the-approved-revision"
        lock_path.write_text(json.dumps(lock), encoding="utf-8")
        self.assert_rejected_without_writes()

    def test_receipt_inside_source_root_is_rejected_before_writing(self):
        before = self.snapshot()
        with self.assertRaises(helper.PatchError):
            self.invoke_receipt_inside_source()
        self.assertEqual(self.snapshot(), before)

    def invoke_receipt_inside_source(self):
        patches = self.host()
        for active in patches:
            active.start()
        try:
            return helper.patch_dependency(
                self.root,
                self.root / "patch-receipt.json",
                verify_only=False,
            )
        finally:
            for active in reversed(patches):
                active.stop()


if __name__ == "__main__":
    unittest.main()
