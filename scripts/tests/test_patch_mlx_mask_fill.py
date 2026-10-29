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
SPEC = importlib.util.spec_from_file_location("patch_mlx_mask_fill", HELPER_PATH)
helper = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = helper
SPEC.loader.exec_module(helper)


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
        self.git_preimage = self.original
        self.patched = b"after approved fixture\n"
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
            "files": [self.file_spec],
        }
        self.packages = {
            "mlx-swift": {
                "url": "https://github.com/ml-explore/mlx-swift", "version": "0.31.6",
                "revision": self.approved["revision"], "target": "FixturePlugin",
                "registry": "plugins.json", "sources": {"Plugins/Fixture/plugin.swift": digest(b"plugin\n")},
            },
            "mlx-swift-lm": {
                "url": "https://example.invalid/mlx-swift-lm", "version": "test-2",
                "revision": "b" * 40, "target": "FixtureMacro", "registry": "macros.json",
                "sources": {"Sources/Fixture/macro.swift": digest(b"macro\n")},
            },
        }
        self._write(self.mlx / self.source_relative, self.original)
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
        records = []
        for identity, spec in self.packages.items():
            entry = {"fingerprint": spec["revision"], "packageIdentity": identity,
                     "targetName": spec["target"]}
            records.append({"identity": identity, "url": spec["url"], "version": spec["version"],
                            "revision": spec["revision"], "sourceSHA256": spec["sources"],
                            "registryEntry": entry})
        return {"schemaVersion": 1, "packages": records}

    def _committed_literal(self, root, commit, path, name):
        self.committed_reads.append((Path(root), commit, path, name))
        self.assertEqual(path, helper.EXTENSION_HELPER)
        self.assertEqual(name, "PACKAGES")
        return self.packages

    def _fake_git(self, checkout, *args):
        checkout = Path(checkout)
        if args == ("rev-parse", "--show-toplevel"):
            return (str(checkout) + "\n").encode()
        if args == ("rev-parse", "HEAD"):
            if checkout == self.root:
                return (self.root_head + "\n").encode()
            identity = "mlx-swift" if checkout == self.mlx else "mlx-swift-lm"
            return (self.packages[identity]["revision"] + "\n").encode()
        if args[:1] == ("show",):
            self.assertEqual(args[1], f"HEAD:{self.source_relative}")
            return self.git_preimage
        if checkout == self.mlx and args[:1] == ("status",):
            if self.source.read_bytes() != self.original:
                result = b" M " + self.source_relative.encode() + b"\0"
                return result + (b"?? unexpected\0" if self.extra_drift else b"")
            return b""
        if checkout == self.lm and args[:1] == ("status",):
            return b" M drift\0" if self.dirty_lm else b""
        if checkout == self.mlx and args[:1] == ("diff",):
            changed = self.source.read_bytes() != self.original
            if args[1] == "--name-only":
                return self.source_relative.encode() + b"\0" if changed else b""
            if args[1] == "--summary":
                return b""
            if args[1] == "--numstat":
                return b"1\t1\t" + self.source_relative.encode() + b"\0" if changed else b""
        raise AssertionError((checkout, args))

    @property
    def source(self):
        return self.mlx / self.source_relative

    def invoke(self, verify_only=False):
        return helper.run(self.root, self.receipt, self.extension_receipt, verify_only)

    def snapshot(self):
        return (self.source.read_bytes(), self.source.stat().st_mode & 0o777,
                (self.root / "Package.resolved").read_bytes(), self.extension_receipt.read_bytes(),
                (self.mlx / "LICENSE").read_bytes(),
                (self.mlx / "Plugins/Fixture/plugin.swift").read_bytes(),
                (self.lm / "Sources/Fixture/macro.swift").read_bytes(),
                self.receipt.read_bytes() if self.receipt.exists() else None)

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
        self.assertEqual(self.receipt.read_bytes(), helper._json_bytes(self.approved))
        self.assertEqual(self.committed_reads, [(self.root, self.root_head, helper.EXTENSION_HELPER, "PACKAGES")])
        before_verification = self.snapshot()
        self.invoke(verify_only=True)
        self.assertEqual(self.snapshot(), before_verification)

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
        self.git_preimage = b"unexpected preimage\n"
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
        self.assertEqual(value, helper.APPROVED_MLX_PATCH)
        self.assertEqual(set(value), {"schemaVersion", "identity", "version", "url", "revision", "license", "files"})
        self.assertEqual((value["schemaVersion"], value["identity"], value["version"], value["url"],
                          value["revision"]),
                         (1, "mlx-swift", "0.31.6", "https://github.com/ml-explore/mlx-swift",
                          "0bb916c67f4b9e5c682cbe02a42c701c93ab5021"))
        self.assertEqual(set(value["license"]), {"path", "sha256"})
        self.assertEqual(value["license"], {"path": "LICENSE",
                                             "sha256": "44326a4ea062241ae6fc26ee2ec90bdc81af7eb7b9d3966181b733fa69d42057"})
        self.assertEqual(set(value["files"][0]), {"path", "originalSHA256", "patchedSHA256",
                                                    "originalSize", "patchedSize", "oldText", "newText"})
        self.assertEqual(value["files"][0]["path"], "Source/MLX/MLXArray+maskFill.swift")
        self.assertEqual(value["files"][0]["originalSHA256"],
                         "5e6ae4e844cbd2ea61032a3c45e5281248072a350be012ae6409ade2250920fe")
        self.assertEqual(value["files"][0]["patchedSHA256"],
                         "391cde3f3480fe9fd434b5ce4bcd4a55166e06db18a7c5a0e1577f43f06a4063")
        self.assertEqual(value["files"][0]["oldText"], "guard let info = dtype.finfo else {")
        self.assertEqual(value["files"][0]["newText"], "guard dtype.finfo != nil else {")
        self.assertEqual(value["files"][0]["originalSize"], 495)
        self.assertEqual(value["files"][0]["patchedSize"], 491)


if __name__ == "__main__":
    unittest.main()
