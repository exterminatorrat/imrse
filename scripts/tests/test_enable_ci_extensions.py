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
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("enable_ci_extensions", ROOT / "scripts/enable-ci-extensions.py")
enable = importlib.util.module_from_spec(spec)
spec.loader.exec_module(enable)


class EnableCIExtensionsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / "source"
        self.checkouts = self.root / ".build/checkouts"
        self.checkouts.mkdir(parents=True)
        self.home = self.base / "home"
        (self.home / "Library").mkdir(parents=True)
        self.output = self.base / "output"
        self.output.mkdir()
        self.receipt = self.output / "extension-enablement.json"
        self.approvals = enable.PACKAGES
        self.revisions, self.status = {}, {}
        specs = []
        pins = []
        for identity, original in enable.PACKAGES.items():
            checkout = self.checkouts / identity
            checkout.mkdir()
            hashes = {}
            for name in original["sources"]:
                path = checkout / name
                path.parent.mkdir(parents=True, exist_ok=True)
                contents = f"fixture:{identity}:{name}".encode()
                path.write_bytes(contents)
                hashes[name] = hashlib.sha256(contents).hexdigest()
            item = dict(original, identity=identity, sources=hashes)
            specs.append(item)
            self.revisions[identity] = item["revision"]
            self.status[identity] = ""
            pins.append({"identity": identity, "kind": "remoteSourceControl", "location": item["url"],
                         "state": {"version": item["version"], "revision": item["revision"]}})
        self.packages_patch = patch.object(enable, "PACKAGES", {item["identity"]: item for item in specs})
        self.packages_patch.start()
        self.addCleanup(self.packages_patch.stop)
        (self.root / "Package.resolved").write_text(json.dumps({"pins": pins}))
        self.git_patch = patch.object(enable, "git_output", side_effect=self.fake_git)
        self.git_patch.start()
        self.addCleanup(self.git_patch.stop)

    def fake_git(self, checkout, *args):
        identity = checkout.name
        if args == ("rev-parse", "HEAD"):
            return self.revisions[identity]
        if args == ("status", "--porcelain", "--untracked-files=all"):
            return self.status[identity]
        raise AssertionError(args)

    def run_enabled(self):
        env = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS", "RUNNER_ARCH": "ARM64"}
        with patch.dict(os.environ, env), patch("platform.system", return_value="Darwin"), \
             patch("platform.machine", return_value="arm64"), patch("pathlib.Path.home", return_value=self.home):
            enable.enable(self.root, self.receipt)

    def assert_no_outputs(self):
        self.assertFalse(self.receipt.exists())
        security = self.home / "Library/org.swift.swiftpm/security"
        self.assertFalse(security.exists())

    def test_pins_and_source_hashes_are_fixed(self):
        encoded = json.dumps(self.approvals, sort_keys=True, separators=(",", ":")).encode()
        self.assertEqual(hashlib.sha256(encoded).hexdigest(), "89089583b00d12264dce783b07643350d6ac242c3e2a6db680856b1cb3dbe163")

    def test_writes_only_exact_approved_entries_and_public_receipt(self):
        self.run_enabled()
        security = self.home / "Library/org.swift.swiftpm/security"
        expected = {
            "plugins.json": [{"fingerprint": enable.PACKAGES["mlx-swift"]["revision"], "packageIdentity": "mlx-swift", "targetName": "CudaBuild"}],
            "macros.json": [{"fingerprint": enable.PACKAGES["mlx-swift-lm"]["revision"], "packageIdentity": "mlx-swift-lm", "targetName": "MLXHuggingFaceMacros"}],
        }
        for name, entries in expected.items():
            self.assertEqual(json.loads((security / name).read_text()), entries)
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual([item["registryEntry"] for item in receipt["packages"]], [expected["plugins.json"][0], expected["macros.json"][0]])
        self.assertTrue(all(item["sourceSHA256"] for item in receipt["packages"]))

    def test_changed_pin_or_checkout_revision_writes_nothing(self):
        pins = json.loads((self.root / "Package.resolved").read_text())
        pins["pins"][0]["state"]["revision"] = "c" * 40
        (self.root / "Package.resolved").write_text(json.dumps(pins))
        with self.assertRaisesRegex(enable.EnableError, "approved pins"):
            self.run_enabled()
        self.assert_no_outputs()
        pins["pins"][0]["state"]["revision"] = enable.PACKAGES["mlx-swift"]["revision"]
        (self.root / "Package.resolved").write_text(json.dumps(pins))
        self.revisions["mlx-swift"] = "c" * 40
        with self.assertRaisesRegex(enable.EnableError, "checkout revision"):
            self.run_enabled()
        self.assert_no_outputs()

    def test_changed_approved_source_hash_writes_nothing(self):
        source = self.checkouts / "mlx-swift-lm/Libraries/MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift"
        source.write_text("tampered fixture")
        with self.assertRaisesRegex(enable.EnableError, "source hash"):
            self.run_enabled()
        self.assert_no_outputs()

    def test_dirty_checkout_writes_nothing(self):
        self.status["mlx-swift"] = " M Plugins/CudaBuild/plugin.swift"
        with self.assertRaisesRegex(enable.EnableError, "not clean"):
            self.run_enabled()
        self.assert_no_outputs()

    def test_nonempty_existing_registry_blocks_both_registry_writes(self):
        security = self.home / "Library/org.swift.swiftpm/security"
        security.mkdir(parents=True)
        original = b'[{"fingerprint":"unapproved"}]\n'
        (security / "macros.json").write_bytes(original)
        with self.assertRaisesRegex(enable.EnableError, "existing destination"):
            self.run_enabled()
        self.assertFalse((security / "plugins.json").exists())
        self.assertEqual((security / "macros.json").read_bytes(), original)
        self.assertFalse(self.receipt.exists())

    def test_host_environment_and_actual_platform_are_both_required(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}), patch("platform.system", return_value="Darwin"), \
             patch("platform.machine", return_value="arm64"), patch("pathlib.Path.home", return_value=self.home):
            with self.assertRaisesRegex(enable.EnableError, "GitHub-hosted macOS ARM64"):
                enable.enable(self.root, self.receipt)
        self.assert_no_outputs()
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS", "RUNNER_ARCH": "ARM64"}), \
             patch("platform.system", return_value="Linux"), patch("platform.machine", return_value="arm64"), \
             patch("pathlib.Path.home", return_value=self.home):
            with self.assertRaisesRegex(enable.EnableError, "GitHub-hosted macOS ARM64"):
                enable.enable(self.root, self.receipt)
        self.assert_no_outputs()

    def test_symlink_destination_is_refused_without_traversal(self):
        target = self.base / "outside"
        target.mkdir()
        (self.home / "Library/org.swift.swiftpm").symlink_to(target, target_is_directory=True)
        with self.assertRaises(OSError):
            self.run_enabled()
        self.assertFalse((target / "security/plugins.json").exists())
        self.assertFalse(self.receipt.exists())


if __name__ == "__main__":
    unittest.main()
