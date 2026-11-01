import hashlib
import io
import json
import plistlib
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import package_local_candidate as package
from scripts import retain_ci_test_app as retention


SOURCE_COMMIT = "a" * 40
SOURCE_TREE = "b" * 40
ROOT = Path(__file__).resolve().parents[2]


class RetainCITestAppTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.workspace = Path(self.temporary.name)
        self.source_root = self.workspace / "source"
        self.source_root.mkdir()
        (self.source_root / "Resources").mkdir()
        self.source_info = {
            "CFBundleExecutable": "imrse",
            "CFBundleIdentifier": package.EXPECTED_BUNDLE_ID,
            "CFBundleShortVersionString": package.EXPECTED_APP_VERSION,
            "CFBundleVersion": package.EXPECTED_BUILD_VERSION,
            "LSMinimumSystemVersion": package.EXPECTED_MINIMUM_OS,
        }
        with (self.source_root / "Resources/Info.plist").open("wb") as destination:
            plistlib.dump(self.source_info, destination)
        self.app = self.workspace / "dist/imrse.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Resources").mkdir()
        with (self.app / "Contents/Info.plist").open("wb") as destination:
            plistlib.dump(self.source_info, destination)
        self.executable = self.app / "Contents/MacOS/imrse"
        self.executable.write_bytes(b"fixture executable bytes")
        self.executable.chmod(0o751)
        self.receipt_path = self.app / "Contents/Resources" / retention.RECEIPT_PATH.rsplit("/", 1)[-1]
        self.output = self.workspace / "retained"
        self._write_receipt()
        self.git_patch = patch.object(package, "run", side_effect=self.fake_git)
        self.git_patch.start()
        self.addCleanup(self.git_patch.stop)

    def fake_git(self, command, cwd=None, **kwargs):
        arguments = command[1:]
        if arguments == ["rev-parse", "HEAD^{commit}"] or arguments == ["rev-parse", "--verify", "HEAD^{commit}"]:
            return SOURCE_COMMIT + "\n"
        if arguments == ["rev-parse", "HEAD^{tree}"] or arguments == ["rev-parse", "--verify", f"{SOURCE_COMMIT}^{{tree}}"]:
            return SOURCE_TREE + "\n"
        if arguments == ["rev-parse", "--show-toplevel"]:
            return str(self.source_root) + "\n"
        if arguments == ["status", "--porcelain=v1", "--untracked-files=all"]:
            return ""
        raise AssertionError(f"unexpected git command: {command}")

    def _write_receipt(self, source_commit=SOURCE_COMMIT, source_tree=SOURCE_TREE):
        receipt = {
            "schemaVersion": 1,
            "validationMode": "unsigned-ci-package-validation-only",
            "distributionEligible": False,
            "codeSigningPerformed": False,
            "signingCertificateSHA1": None,
            "signatureReceipt": None,
            "releaseBuildProvenanceCreated": False,
            "source": {"commitSHA": source_commit, "treeSHA": source_tree},
            "product": {
                "bundleIdentifier": package.EXPECTED_BUNDLE_ID,
                "executableSHA256": package.sha256_file(self.executable),
                "infoPlistSHA256": package.sha256_file(self.app / "Contents/Info.plist"),
                "hostArchitecture": "arm64",
                "machoArchitectures": {"Contents/MacOS/imrse": "arm64"},
            },
            "checks": {"cleanCommittedSourceAndVersionMatch": "passed"},
        }
        self.receipt_path.write_text(json.dumps(receipt, sort_keys=True) + "\n", encoding="utf-8")

    def retain(self, expected_commit=SOURCE_COMMIT):
        return retention.retain_ci_test_app(
            self.source_root,
            self.app,
            self.output,
            expected_commit,
            "417",
            "2",
        )

    def test_retains_inventory_receipt_and_mode_preserving_archive(self):
        output = self.retain()
        manifest = json.loads((output / retention.MANIFEST_NAME).read_text(encoding="utf-8"))
        self.assertEqual(manifest["source"], {"commitSHA": SOURCE_COMMIT, "treeSHA": SOURCE_TREE})
        self.assertEqual(manifest["ci"], {"runID": "417", "runAttempt": "2"})
        self.assertEqual(manifest["app"]["bundleIdentifier"], package.EXPECTED_BUNDLE_ID)
        self.assertEqual(manifest["app"]["architecture"], "arm64")
        self.assertFalse(manifest["limits"]["distributionEligible"])
        self.assertFalse(manifest["limits"]["codeSigningPerformed"])
        self.assertFalse(manifest["limits"]["releaseBuildProvenanceCreated"])
        self.assertFalse(manifest["limits"]["compilerAttestation"])
        self.assertFalse(manifest["limits"]["nativeAdmission"])
        receipt_entry = next(entry for entry in manifest["app"]["inventory"] if entry["path"] == retention.RECEIPT_PATH)
        self.assertEqual(manifest["app"]["ciValidationReceiptSHA256"], receipt_entry["sha256"])
        archive_path = output / retention.ARCHIVE_NAME
        self.assertEqual(manifest["archive"]["sizeBytes"], archive_path.stat().st_size)
        self.assertEqual(manifest["archive"]["sha256"], package.sha256_file(archive_path))
        checksums = (output / retention.CHECKSUMS_NAME).read_text(encoding="utf-8")
        self.assertIn(f"{manifest['archive']['sha256']}  {retention.ARCHIVE_NAME}\n", checksums)
        self.assertIn(f"{hashlib.sha256((output / retention.MANIFEST_NAME).read_bytes()).hexdigest()}  {retention.MANIFEST_NAME}\n", checksums)
        with tarfile.open(archive_path, "r:gz") as archive:
            members = {member.name.rstrip("/"): member for member in archive.getmembers()}
            expected_names = {
                "imrse.app",
                "imrse.app/Contents",
                "imrse.app/Contents/Info.plist",
                "imrse.app/Contents/MacOS",
                "imrse.app/Contents/MacOS/imrse",
                "imrse.app/Contents/Resources",
                f"imrse.app/{retention.RECEIPT_PATH}",
            }
            self.assertEqual(set(members), expected_names)
            self.assertTrue(all(name == "imrse.app" or name.startswith("imrse.app/") for name in members))
            executable_member = members["imrse.app/Contents/MacOS/imrse"]
            self.assertEqual(executable_member.mode, 0o751)
            with archive.extractfile(executable_member) as extracted:
                self.assertEqual(extracted.read(), self.executable.read_bytes())
            for entry in manifest["app"]["inventory"]:
                name = "imrse.app" if entry["path"] == "." else f"imrse.app/{entry['path']}"
                self.assertEqual(members[name].mode, entry["mode"])
                if entry["type"] == "file":
                    with archive.extractfile(members[name]) as content:
                        self.assertEqual(hashlib.sha256(content.read()).hexdigest(), entry["sha256"])

    def test_rejects_source_and_receipt_mismatch(self):
        with self.assertRaises(retention.RetentionError):
            self.retain("c" * 40)
        self._write_receipt(source_tree="c" * 40)
        with self.assertRaises(retention.RetentionError):
            self.retain()
        self.assertFalse(self.output.exists())

    def test_rejects_archive_bytes_that_differ_from_inventory(self):
        original_add = tarfile.TarFile.add

        def corrupt_add(archive, source, arcname=None, recursive=True):
            if arcname == "imrse.app/Contents/MacOS/imrse":
                info = archive.gettarinfo(source, arcname)
                archive.addfile(info, io.BytesIO(b"x" * info.size))
            else:
                original_add(archive, source, arcname=arcname, recursive=recursive)

        with patch.object(tarfile.TarFile, "add", corrupt_add):
            with self.assertRaisesRegex(retention.RetentionError, "archived bytes differ"):
                self.retain()
        self.assertFalse((self.output / retention.MANIFEST_NAME).exists())

    def test_rejects_symlink_entries(self):
        (self.app / "Contents/Resources/linked").symlink_to(self.executable)
        with self.assertRaises(retention.RetentionError):
            self.retain()
        self.assertFalse(self.output.exists())

    def test_rejects_inventory_limit_before_hashing(self):
        for index in range(retention.MAX_ENTRIES):
            (self.app / "Contents/Resources" / f"extra-{index}").touch()
        with self.assertRaises(retention.RetentionError):
            self.retain()
        self.assertFalse(self.output.exists())

    def test_rejects_app_size_limit_before_hashing(self):
        oversized = self.app / "Contents/Resources/oversized"
        with oversized.open("wb") as destination:
            destination.truncate(retention.MAX_APP_BYTES + 1)
        with self.assertRaises(retention.RetentionError):
            self.retain()
        self.assertFalse(self.output.exists())

    def test_refuses_existing_output_directory(self):
        self.output.mkdir()
        marker = self.output / "keep.txt"
        marker.write_text("unchanged", encoding="utf-8")
        with self.assertRaises(retention.RetentionError):
            self.retain()
        self.assertEqual(marker.read_text(encoding="utf-8"), "unchanged")

    def test_private_workflow_is_branch_pinned_unsigned_and_fail_closed(self):
        workflow = (ROOT / ".github/workflows/private-test-app.yml").read_text(encoding="utf-8")
        events = workflow.partition("on:\n")[2].partition("\npermissions:\n")[0]
        self.assertEqual(events, "  push:\n    branches:\n      - capy/heh-1-test-build-20261101")
        self.assertIn("runs-on: macos-26", workflow)
        self.assertIn("DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer", workflow)
        self.assertIn('IMRSE_CI_PACKAGE_VALIDATION: "1"', workflow)
        self.assertIn("IMRSE_EXPECTED_SOURCE_COMMIT: ${{ github.sha }}", workflow)
        self.assertIn("ref: ${{ github.sha }}", workflow)
        self.assertIn("xcodebuild -version && swift --version", workflow)
        self.assertIn("bash -n scripts/build-app.sh", workflow)
        self.assertIn("plutil -lint Resources/Info.plist", workflow)
        self.assertIn("Ensure Metal compiler is available", workflow)
        self.assertIn("./scripts/build-app.sh", workflow)
        self.assertIn("Retain unsigned CI app for private testing", workflow)
        self.assertIn("--expected-commit \"$IMRSE_EXPECTED_SOURCE_COMMIT\"", workflow)
        self.assertIn("IMRSE_DIST_DIR: ${{ runner.temp }}/imrse-ci-package-validation", workflow)
        self.assertNotIn("IMRSE_SIGNING_", workflow)
        self.assertNotIn("IMRSE_RELEASE", workflow)
        self.assertNotIn("codesign", workflow)
        self.assertNotIn("sign-app", workflow)
        self.assertNotIn("release", workflow.lower())
        self.assertNotIn("continue-on-error:", workflow)
        self.assertNotIn("if: always()", workflow)
        self.assertIn("actions/upload-artifact@v4", workflow)
        self.assertIn("if-no-files-found: error", workflow)
        self.assertIn(
            "name: imrse-ci-test-app-${{ github.run_id }}-${{ github.run_attempt }}",
            workflow,
        )
        self.assertIn("CI_RUN_ID: ${{ github.run_id }}", workflow)
        self.assertIn("CI_RUN_ATTEMPT: ${{ github.run_attempt }}", workflow)


if __name__ == "__main__":
    unittest.main()
