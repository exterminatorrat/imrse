import ast
import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = ROOT / "scripts/patch-mlx-mask-fill.py"
sys.path.insert(0, str(ROOT / "scripts"))
from ci_mlx_approval import MLX_PATCH as EXPECTED_PATCH

SPEC = importlib.util.spec_from_file_location("patch_mlx_mask_fill", HELPER_PATH)
helper = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = helper
SPEC.loader.exec_module(helper)
MODULE_APPROVAL = EXPECTED_PATCH["files"][1]


def digest(contents):
    return hashlib.sha256(contents).hexdigest()


class PatchMLXMaskFillTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / "root"
        self.mlx = self.root / ".build/checkouts/mlx-swift"
        self.lm = self.root / ".build/checkouts/mlx-swift-lm"
        self.mlx.mkdir(parents=True)
        self.lm.mkdir(parents=True)
        self.output = self.base / "receipts"
        self.output.mkdir()
        self.receipt = self.output / "mlx-patch.json"
        self.extension_receipt = self.output / "extensions.json"
        self.source_relative = "Source/MLX/MLXArray+maskFill.swift"
        self.original = b"before approved fixture\n"
        self.patched = b"after approved fixture\n"
        self.module_relative = "Source/MLXNN/Module.swift"
        self.module_original = (b"if let value = value as? T {\n                return value\n"
                                b"if let value = value as? T {\n        self.value = value\n"
                                b"if let module = module as? T {\n                return module\n")
        value_hunk, module_hunk = MODULE_APPROVAL["replacements"]
        self.module_patched = self.module_original
        for hunk in (value_hunk, module_hunk):
            self.module_patched = self.module_patched.replace(hunk["oldText"].encode(), hunk["newText"].encode(), 1)
        self.module_spec = dict(MODULE_APPROVAL, originalSHA256=digest(self.module_original),
                                patchedSHA256=digest(self.module_patched), originalSize=len(self.module_original),
                                patchedSize=len(self.module_patched))
        self.license_bytes = b"synthetic license\n"
        self.file_spec = {
            "path": self.source_relative,
            "originalSHA256": digest(self.original),
            "patchedSHA256": digest(self.patched),
            "originalSize": len(self.original),
            "patchedSize": len(self.patched),
            "oldText": "before approved fixture",
            "newText": "after approved fixture",
        }
        self.approved = {
            "schemaVersion": 1,
            "identity": "mlx-swift",
            "version": "0.31.6",
            "url": "https://github.com/ml-explore/mlx-swift",
            "revision": "a" * 40,
            "license": {"path": "LICENSE", "sha256": digest(self.license_bytes)},
            "files": [self.file_spec, self.module_spec],
        }
        self.packages = {
            "mlx-swift": {"url": "https://github.com/ml-explore/mlx-swift", "version": "0.31.6",
                "revision": self.approved["revision"], "target": "FixturePlugin",
                "registry": "plugins.json", "sources": {"Plugins/Fixture/plugin.swift": digest(b"plugin\n")},
            },
            "mlx-swift-lm": {"url": "https://example.invalid/mlx-swift-lm", "version": "test-2",
                "revision": "b" * 40, "target": "FixtureMacro", "registry": "macros.json",
                "sources": {"Sources/Fixture/macro.swift": digest(b"macro\n")},
            },
        }
        self._write(self.mlx / self.source_relative, self.original)
        self._write(self.mlx / self.module_relative, self.module_original)
        self.source_paths = {self.source_relative: self.source, self.module_relative: self.module_source}
        self.source_preimages = {self.source_relative: self.original, self.module_relative: self.module_original}
        self._write(self.mlx / "LICENSE", self.license_bytes)
        self._write(self.mlx / "Plugins/Fixture/plugin.swift", b"plugin\n")
        self._write(self.lm / "Sources/Fixture/macro.swift", b"macro\n")
        pins = [{"identity": identity, "kind": "remoteSourceControl", "location": spec["url"],
                 "state": {"version": spec["version"], "revision": spec["revision"]}}
                for identity, spec in self.packages.items()]
        self._write(self.root / "Package.resolved", json.dumps({"pins": pins}).encode())
        self.expected_extension = self._extension_receipt()
        self.extension_receipt.write_bytes(helper._json_bytes(self.expected_extension))
        self.root_head = "c" * 40
        self.dirty_lm = False
        self.extra_drift = False
        self.partial_diff = False
        self.committed_reads = []
        self.patchers = [
            patch.object(helper, "APPROVED_MLX_PATCH", self.approved),
            patch.object(helper.ci_approval, "committed_literal", side_effect=self._committed_literal),
            patch.object(helper.ci_approval, "approved_extensions", return_value=self.expected_extension, create=True),
            patch.object(helper.ci_approval, "approved_mlx_patch", return_value=self.approved, create=True),
            patch.object(helper, "_git", side_effect=self._fake_git),
            patch("platform.system", return_value="Darwin"),
            patch("platform.machine", return_value="arm64"),
            patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                                    "RUNNER_OS": "macOS", "RUNNER_ARCH": "ARM64"}),
        ]
        for active in self.patchers:
            active.start()
            self.addCleanup(active.stop)

    def _write(self, path, contents):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)

    def _extension_receipt(self):
        return {"schemaVersion": 1, "packages": [
            {"identity": identity, "url": spec["url"], "version": spec["version"],
             "revision": spec["revision"], "sourceSHA256": spec["sources"],
             "registryEntry": {"fingerprint": spec["revision"], "packageIdentity": identity,
                               "targetName": spec["target"]}}
            for identity, spec in self.packages.items()]}

    def _committed_literal(self, root, commit, path, name):
        self.committed_reads.append((Path(root), commit, path, name))
        self.assertEqual(path, helper.EXTENSION_HELPER)
        self.assertEqual(name, "PACKAGES")
        return self.packages

    def _fake_git(self, checkout, *args):
        checkout = Path(checkout)
        if args[:1] == ("rev-parse",):
            if args[1] == "--show-toplevel":
                return (str(checkout) + "\n").encode()
            if checkout == self.root:
                return (self.root_head + "\n").encode()
            identity = "mlx-swift" if checkout == self.mlx else "mlx-swift-lm"
            return (self.packages[identity]["revision"] + "\n").encode()
        if args[:1] == ("show",):
            relative = args[1].removeprefix("HEAD:")
            return self.source_preimages[relative]
        if args[:1] == ("status",):
            if checkout == self.lm:
                return b" M drift\0" if self.dirty_lm else b""
            result = b"".join(b" M " + relative.encode() + b"\0" for relative in self._changed_sources())
            return result + (b"?? unexpected\0" if self.extra_drift else b"")
        if checkout == self.mlx and args[:1] == ("diff",):
            changed = self._changed_sources()
            if self.partial_diff:
                changed = changed[:1]
            if args[1] == "--name-only":
                return b"".join(relative.encode() + b"\0" for relative in changed)
            if args[1] == "--summary":
                return b""
            if args[1] == "--numstat":
                counts = {self.source_relative: 1, self.module_relative: 2}
                return b"".join(f"{counts[relative]}\t{counts[relative]}\t".encode()
                                 + relative.encode() + b"\0" for relative in changed)
        raise AssertionError((checkout, args))

    def _changed_sources(self):
        return [relative for relative in sorted(self.source_paths)
                if self.source_paths[relative].read_bytes() != self.source_preimages[relative]]

    @property
    def source(self):
        return self.mlx / self.source_relative

    @property
    def module_source(self):
        return self.mlx / self.module_relative

    def invoke(self, verify_only=False):
        return helper.run(self.root, self.receipt, self.extension_receipt, verify_only)

    def snapshot(self):
        other = (self.root / "Package.resolved", self.extension_receipt, self.mlx / "LICENSE",
                 self.mlx / "Plugins/Fixture/plugin.swift", self.lm / "Sources/Fixture/macro.swift")
        return (tuple((path.read_bytes(), path.stat().st_mode & 0o777) for path in self.source_paths.values()),
                *(path.read_bytes() for path in other), self.receipt.read_bytes() if self.receipt.exists() else None)

    def assert_rejected_without_patch(self):
        before = self.snapshot()
        with self.assertRaises(helper.PatchError):
            self.invoke()
        self.assertEqual(self.snapshot(), before)

    def test_apply_and_verify_only_use_canonical_receipt_and_preserve_mode(self):
        self.source.chmod(0o744)
        self.invoke()
        self.assertEqual(self.source.read_bytes(), self.patched)
        self.assertEqual(self.source.stat().st_mode & 0o777, 0o744)
        self.assertEqual(self.module_source.read_bytes(), self.module_patched)
        self.assertEqual(self.module_source.read_bytes().count(b"if let value = (value as Any) as? T {"), 1)
        self.assertIn(b"if let value = value as? T {\n        self.value = value", self.module_source.read_bytes())
        self.assertEqual(self.receipt.read_bytes(), helper._json_bytes(self.approved))
        self.assertEqual(self.committed_reads, [(self.root, self.root_head, helper.EXTENSION_HELPER, "PACKAGES")])
        before_verification = self.snapshot()
        self.invoke(verify_only=True)
        self.assertEqual(self.snapshot(), before_verification)

    def test_second_source_preimage_fails_before_any_write(self):
        self.module_original = b"wrong second preimage\n"
        self.module_source.write_bytes(self.module_original)
        self.source_preimages[self.module_relative] = self.module_original
        self.assert_rejected_without_patch()

    def test_partial_source_diff_is_rejected_in_verify_only(self):
        self.invoke()
        self.partial_diff = True
        before = self.snapshot()
        with self.assertRaisesRegex(helper.PatchError, "approved source change"):
            self.invoke(verify_only=True)
        self.assertEqual(self.snapshot(), before)

    def test_receipt_failure_rolls_back_both_sources(self):
        before = self.snapshot()
        with patch.object(helper.ci_mlx_patch_sources.os, "link", side_effect=OSError("receipt creation failed")), \
                self.assertRaisesRegex(helper.PatchError, "unable to create the new MLX patch receipt"):
            self.invoke()
        self.assertEqual(self.snapshot(), before)

    def test_duplicate_full_hunk_is_rejected_before_any_write(self):
        hunk = self.module_spec["replacements"][0]["oldText"].encode()
        self.module_original += b"\n" + hunk
        self.module_source.write_bytes(self.module_original)
        self.source_preimages[self.module_relative] = self.module_original
        self.module_spec.update(originalSHA256=digest(self.module_original), originalSize=len(self.module_original))
        self.assert_rejected_without_patch()

    def test_wrong_host_fails_before_any_write(self):
        before = self.snapshot()
        with patch("platform.machine", return_value="x86_64"):
            with self.assertRaisesRegex(helper.PatchError, "Darwin arm64"):
                self.invoke()
        self.assertEqual(self.snapshot(), before)

    def test_wrong_root_pin_fails_before_any_write(self):
        lock = json.loads((self.root / "Package.resolved").read_text())
        lock["pins"][0]["location"] = "https://wrong.invalid/mlx-swift"
        (self.root / "Package.resolved").write_text(json.dumps(lock))
        self.assert_rejected_without_patch()

    def test_wrong_source_preimage_fails_before_any_write(self):
        self.source_preimages[self.source_relative] = b"unexpected preimage\n"
        self.assert_rejected_without_patch()

    def test_wrong_license_fails_before_any_write(self):
        (self.mlx / "LICENSE").write_bytes(b"changed license\n")
        self.assert_rejected_without_patch()

    def test_symlinked_license_is_refused(self):
        license_path = self.mlx / "LICENSE"
        license_path.unlink()
        license_path.symlink_to(self.output / "extensions.json")
        self.assert_rejected_without_patch()

    def test_wrong_extension_receipt_fails_before_any_write(self):
        self.extension_receipt.write_text('{"schemaVersion":1,"packages":[]}\n')
        self.assert_rejected_without_patch()

    def test_duplicate_extension_receipt_keys_are_rejected(self):
        self.extension_receipt.write_text('{"schemaVersion":1,"schemaVersion":1,"packages":[]}\n')
        self.assert_rejected_without_patch()

    def test_changed_reviewed_extension_source_fails_before_any_write(self):
        (self.lm / "Sources/Fixture/macro.swift").write_text("changed macro\n")
        self.assert_rejected_without_patch()

    def test_changed_reviewed_plugin_source_fails_before_any_write(self):
        (self.mlx / "Plugins/Fixture/plugin.swift").write_text("changed plugin\n")
        self.assert_rejected_without_patch()

    def test_dirty_other_package_checkout_fails_before_any_write(self):
        self.dirty_lm = True
        self.assert_rejected_without_patch()

    def test_verify_only_rejects_unrelated_untracked_drift_without_writes(self):
        self.source.write_bytes(self.patched)
        self.module_source.write_bytes(self.module_patched)
        self.receipt.write_bytes(helper._json_bytes(self.approved))
        self.extra_drift = True
        before = self.snapshot()
        with self.assertRaisesRegex(helper.PatchError, "approved source change"):
            self.invoke(verify_only=True)
        self.assertEqual(self.snapshot(), before)

    def test_apply_refuses_existing_receipt_without_writes(self):
        self.receipt.write_bytes(b"existing")
        self.assert_rejected_without_patch()

    def test_receipt_inside_source_checkout_is_refused(self):
        before = self.snapshot()
        with self.assertRaisesRegex(helper.PatchError, "outside the source checkout"):
            helper.run(self.root, self.root / "patch.json", self.extension_receipt)
        self.assertEqual(self.snapshot(), before)


class ApprovedLiteralTests(unittest.TestCase):
    def test_literal_has_only_the_approved_schema_and_hunk(self):
        tree = ast.parse(HELPER_PATH.read_text(encoding="utf-8"))
        assignment = next(node for node in tree.body if isinstance(node, ast.Assign)
                          and any(isinstance(target, ast.Name) and target.id == "APPROVED_MLX_PATCH"
                                  for target in node.targets))
        value = ast.literal_eval(assignment.value)
        self.assertEqual(value, EXPECTED_PATCH)
        self.assertEqual(value, helper.APPROVED_MLX_PATCH)


if __name__ == "__main__":
    unittest.main()
