import hashlib
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from io import StringIO
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from scripts import package_local_candidate as packager
from scripts.package_local_candidate import (
    BUILD_PROVENANCE_FILE,
    BUILD_PROVENANCE_SCOPE,
    CERTIFICATE_SIGNING_LABEL,
    CANDIDATE_VERSION,
    C_RUNTIME_DEPENDENCIES,
    CI_VALIDATION_RECEIPT_FILE,
    EXPECTED_APP_VERSION,
    EXPECTED_BUNDLE_ID,
    EXPECTED_BUILD_VERSION,
    FORBIDDEN_FILE_NAMES,
    FORBIDDEN_PATH_COMPONENTS,
    LOCK_FILES,
    PackageError,
    RUNTIME_DEPENDENCIES,
    SOURCE_INPUT_MANIFEST_FILE,
    architecture_set_is_arm64_only,
    bundle_tree_sha256,
    candidate_manifest,
    copy_source_inputs,
    create_zip,
    expected_release_build_command,
    git_blob_contents,
    identity_keychain_path_sha256,
    normalized_release_build_command,
    pin_codesign_executable,
    read_pins,
    read_source_info,
    record_build_provenance,
    sha256_file,
    source_git_files,
    sign_and_verify,
    normalize_certificate_sha1,
    normalize_signing_keychain_path,
    validate_app_version_metadata,
    validate_build_provenance,
    validate_built_app_bundle,
    validate_no_bundled_user_data,
    validate_required_resources,
    validate_source_copy,
    validate_symlinks,
)


ROOT = Path(__file__).resolve().parents[2]
TEST_CERTIFICATE_SHA1 = "0123456789abcdef0123456789abcdef01234567"


class PackageLocalCandidateTests(unittest.TestCase):
    def setUp(self):
        self.real_packager_run = packager.run
        self.codesign_calls = []
        self.codesign_signers = []
        self.codesign_identity_keychains = []
        self.codesign_available_sha1 = TEST_CERTIFICATE_SHA1
        self.codesign_actual_sha1 = TEST_CERTIFICATE_SHA1
        self.codesign_signature_type = "certificate-signed"
        self.codesign_identifiers = {}
        self.codesign_designated_requirements = {}
        self.codesign_commented_designated_requirements = set()
        self.codesign_designated_outputs = {}
        self.keychain_temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.keychain_temp.cleanup)
        self.signing_keychain_path = Path(self.keychain_temp.name) / "selected.keychain-db"
        self.signing_keychain_path.touch()
        self.codesign_executable_path = (Path(self.keychain_temp.name) / "codesign-test-double").resolve()
        self.codesign_executable_path.write_bytes(b"fake codesign executable for unit tests")
        self.codesign_executable_path.chmod(0o700)
        self.codesign_executable_sha256 = sha256_file(self.codesign_executable_path)
        self.codesign_pin = pin_codesign_executable(self.codesign_executable_path, self.codesign_executable_sha256)
        self.codesign_patcher = patch.object(packager, "run", side_effect=self.stub_packager_run)
        self.codesign_patcher.start()
        self.addCleanup(self.codesign_patcher.stop)

    def stub_packager_run(self, command, **kwargs):
        if command[0] != str(self.codesign_executable_path):
            return self.real_packager_run(command, **kwargs)
        command = [str(argument) for argument in command]
        self.codesign_calls.append(command)
        path = Path(command[-1])
        if "--sign" in command:
            keychain_indexes = [index for index, argument in enumerate(command) if argument == "--keychain"]
            if len(keychain_indexes) != 1 or keychain_indexes[0] + 1 >= len(command):
                raise AssertionError("every signing invocation must name exactly one identity keychain")
            selected_keychain = command[keychain_indexes[0] + 1]
            self.codesign_identity_keychains.append(selected_keychain)
            if selected_keychain != str(self.signing_keychain_path.resolve()):
                raise PackageError("stubbed codesign received a different identity keychain")
            selected_sha1 = command[command.index("--sign") + 1]
            self.codesign_signers.append(selected_sha1)
            if selected_sha1 != self.codesign_available_sha1:
                raise PackageError("stubbed codesign has no matching signing identity")
            if any(argument in {"-r", "-r-", "--requirements"} or argument.startswith("-r=") for argument in command):
                raise AssertionError("signing must keep the system default designated requirement")
            return ""
        if "--verify" in command:
            requirements = [argument for argument in command if argument.startswith("-R=")]
            expected = f'-R=certificate leaf H"{self.codesign_actual_sha1.lower()}"'
            if self.codesign_signature_type != "certificate-signed" or requirements != [expected]:
                raise PackageError("stubbed code signature does not satisfy the selected certificate requirement")
            return "valid signature"
        if "-dv" in command:
            identifier = self.codesign_identifiers.get(str(path), EXPECTED_BUNDLE_ID)
            if self.codesign_signature_type == "ad-hoc":
                return f"Executable={path}\nIdentifier={identifier}\nSignature=adhoc\nTeamIdentifier=not set\n"
            return f"Executable={path}\nIdentifier={identifier}\nAuthority=Stub Certificate\nTeamIdentifier=not set\n"
        if "-d" in command and "-r-" in command:
            output = self.codesign_designated_outputs.get(str(path))
            if output is not None:
                return output
            identifier = self.codesign_identifiers.get(str(path), EXPECTED_BUNDLE_ID)
            requirement = self.codesign_designated_requirements.get(
                str(path),
                f'identifier "{identifier}" and anchor apple generic and certificate leaf H"{self.codesign_actual_sha1.lower()}"',
            )
            comment = "# " if str(path) in self.codesign_commented_designated_requirements else ""
            return f"Executable={path}\n{comment}designated => {requirement}\n"
        raise AssertionError(f"unexpected codesign command in unit stub: {command}")

    def signing_tool_environment(self):
        return {
            "IMRSE_SIGNING_CODESIGN_EXECUTABLE": str(self.codesign_executable_path),
            "IMRSE_SIGNING_CODESIGN_SHA256": self.codesign_executable_sha256,
        }

    def create_private_signing_receipt(self, bundle, receipt_path, result=None, producer="builder"):
        bundle = Path(bundle)
        receipt_path = Path(receipt_path)
        receipt_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if result is None:
            result = packager.sign_app_bundle(bundle, TEST_CERTIFICATE_SHA1, self.signing_keychain_path, self.codesign_pin)
        reservation = packager.reserve_private_signing_receipt(receipt_path, bundle)
        try:
            packager.write_private_signing_receipt(
                reservation,
                packager.private_signing_receipt_payload(
                    result,
                    producer,
                    bundle,
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                ),
            )
        except Exception:
            packager.close_private_signing_receipt_reservation(reservation, remove=True)
            raise
        packager.close_private_signing_receipt_reservation(reservation)
        return receipt_path

    def private_builder_receipt_path(self, build_root):
        return Path(build_root) / "products/.private-signing-stage/signing-execution-receipt.json"

    @classmethod
    def setUpClass(cls):
        cls.source_temp = tempfile.TemporaryDirectory()
        cls.source_root = Path(cls.source_temp.name) / "clean-source"
        subprocess.run(
            ["git", "clone", "--quiet", "--local", "--no-hardlinks", str(ROOT), str(cls.source_root)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        cls.source_commit = packager.run(["git", "rev-parse", "HEAD"], cwd=cls.source_root).strip()
        cls.source_tree = packager.run(["git", "rev-parse", "HEAD^{tree}"], cwd=cls.source_root).strip()

    @classmethod
    def tearDownClass(cls):
        cls.source_temp.cleanup()

    def make_build_fixture(self, base):
        base = Path(base).resolve(strict=True)
        build_root = base / "isolated-build"
        copy_root, manifest_path = copy_source_inputs(
            self.source_root,
            self.source_commit,
            self.source_tree,
            build_root,
        )
        product = build_root / "products/imrse.app"
        product.parent.mkdir(parents=True)
        private_stage = product.parent / ".private-signing-stage"
        private_stage.mkdir(mode=0o700)
        staged_product = private_stage / "imrse.app"
        (staged_product / "Contents/MacOS").mkdir(parents=True)
        (staged_product / "Contents/MacOS/imrse").write_bytes(b"\xcf\xfa\xed\xfe fake product executable")
        (staged_product / "Contents/Info.plist").write_bytes((self.source_root / "Resources/Info.plist").read_bytes())
        brand = staged_product / "Contents/Resources/Brand"
        brand.mkdir(parents=True)
        (brand / "imrse-menubar-template.pdf").write_bytes(b"fake menu-bar template")
        licenses = staged_product / "Contents/Resources/ThirdPartyLicenses"
        licenses.mkdir(parents=True)
        for dependency in (*RUNTIME_DEPENDENCIES, *C_RUNTIME_DEPENDENCIES):
            (licenses / dependency[4]).write_text(dependency[4])
        (licenses / "mlx-core-LICENSE").write_text("mlx-core-LICENSE")
        private_receipt_path = self.create_private_signing_receipt(
            staged_product,
            private_stage / "signing-execution-receipt.json",
        )
        staged_product.rename(product)
        provenance_path = record_build_provenance(
            self.source_root,
            self.source_commit,
            self.source_tree,
            build_root,
            copy_root,
            expected_release_build_command(build_root),
            TEST_CERTIFICATE_SHA1,
            self.signing_keychain_path,
            self.codesign_pin,
            private_receipt_path,
        )
        return build_root, copy_root, manifest_path, product, provenance_path

    def invoke_ci_build_with_stubbed_swift(self, base, host_architecture):
        stub_directory = Path(base) / "stubs"
        stub_directory.mkdir()
        uname = stub_directory / "uname"
        uname.write_text(
            "#!/bin/sh\n"
            "case \"$1\" in\n"
            "  -s) printf 'Darwin\\n' ;;\n"
            "  -m) printf '%s\\n' \"$IMRSE_TEST_HOST_ARCHITECTURE\" ;;\n"
            "  *) exit 2 ;;\n"
            "esac\n"
        )
        uname.chmod(0o755)
        swift = stub_directory / "swift"
        swift.write_text(
            "#!/bin/sh\n"
            "printf '%s\\0' \"$@\" > \"$IMRSE_TEST_SWIFT_ARGV_CAPTURE\"\n"
            "exit 97\n"
        )
        swift.chmod(0o755)
        xcodebuild = stub_directory / "xcodebuild"
        xcodebuild.write_bytes(swift.read_bytes())
        xcodebuild.chmod(0o755)
        capture = Path(base) / "swift-argv"
        output = Path(base) / "ci-output"
        environment = os.environ.copy()
        environment.update({
            "IMRSE_CI_PACKAGE_VALIDATION": "1",
            "IMRSE_DIST_DIR": str(output),
            "IMRSE_TEST_HOST_ARCHITECTURE": host_architecture,
            "IMRSE_TEST_SWIFT_ARGV_CAPTURE": str(capture),
            "PATH": os.pathsep.join((str(stub_directory), environment["PATH"])),
        })
        environment.pop("IMRSE_SIGNING_CERTIFICATE_SHA1", None)
        environment.pop("IMRSE_SIGNING_KEYCHAIN_PATH", None)
        environment.pop("IMRSE_SIGNING_CODESIGN_EXECUTABLE", None)
        environment.pop("IMRSE_SIGNING_CODESIGN_SHA256", None)
        for key in ("IMRSE_RELEASE_SOURCE_COMMIT", "IMRSE_RELEASE_SOURCE_TREE", "IMRSE_RELEASE_BUILD_ROOT"):
            environment.pop(key, None)
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/build-app.sh")],
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        argv = capture.read_bytes().split(b"\0")[:-1] if capture.exists() else None
        return result, argv, output

    def clone_source(self, parent):
        source = parent / "dirty-source"
        subprocess.run(
            ["git", "clone", "--quiet", "--local", "--no-hardlinks", str(self.source_root), str(source)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return source

    def test_candidate_metadata_is_020_build13_and_matches_source_exactly(self):
        info = read_source_info(ROOT)
        self.assertEqual(CANDIDATE_VERSION, "0.2.0-beta.1")
        self.assertEqual(info["CFBundleShortVersionString"], EXPECTED_APP_VERSION)
        self.assertEqual(info["CFBundleVersion"], EXPECTED_BUILD_VERSION)
        self.assertEqual(EXPECTED_BUILD_VERSION, "13")
        validate_app_version_metadata(info, info)
        with self.assertRaisesRegex(PackageError, "clean-source Resources/Info.plist"):
            validate_app_version_metadata(info, {**info, "CFBundleVersion": "12"})
        with self.assertRaisesRegex(PackageError, "does not match"):
            validate_app_version_metadata({**info, "LSUIElement": False}, info)

    def test_runtime_inventory_matches_current_dependency_pins_and_notice(self):
        pins = read_pins(ROOT)
        notice = (ROOT / "Resources/THIRD_PARTY_NOTICES.md").read_text()
        self.assertIn("not evidence that a particular candidate contains those dependencies", notice)
        for identity, version, revision, modules, license_name in RUNTIME_DEPENDENCIES:
            self.assertEqual(pins[identity], {"version": version, "revision": revision})
            self.assertIn(identity, notice)
            self.assertTrue(all(module in notice for module in modules))
            self.assertIn(license_name, notice)
        for identity, version, revision, symbols, license_name in C_RUNTIME_DEPENDENCIES:
            self.assertEqual(pins[identity], {"version": version, "revision": revision})
            for evidence in (identity, version, revision, *symbols, license_name):
                self.assertIn(evidence, notice)
        self.assertIn("ThirdPartyLicenses/mlx-core-LICENSE", notice)
        self.assertTrue((ROOT / "LICENSE").is_file())
        with patch("scripts.package_local_candidate.run", return_value="_yyjson_read_opts\n"):
            self.assertEqual(packager.validate_runtime_symbols(ROOT / "unused-binary"), {"_yyjson_read_opts"})
        with patch("scripts.package_local_candidate.run", return_value=""):
            with self.assertRaisesRegex(PackageError, "C runtime"):
                packager.validate_runtime_symbols(ROOT / "unused-binary")

    def test_source_input_copy_is_bound_to_clean_commit_and_tree_without_absolute_paths(self):
        with tempfile.TemporaryDirectory() as temp:
            build_root = Path(temp) / "isolated-build"
            copy_root, manifest_path = copy_source_inputs(
                self.source_root,
                self.source_commit,
                self.source_tree,
                build_root,
            )
            manifest = json.loads(manifest_path.read_text())
            self.assertEqual(manifest["sourceCommitSHA"], self.source_commit)
            self.assertEqual(manifest["sourceTreeSHA"], self.source_tree)
            self.assertGreater(len(manifest["files"]), 20)
            self.assertNotIn(str(self.source_root), json.dumps(manifest))
            self.assertNotIn(str(build_root), json.dumps(manifest))
            self.assertFalse(os.path.samefile(self.source_root / "Package.swift", copy_root / "Package.swift"))
            self.assertEqual(validate_source_copy(self.source_root, copy_root, manifest, self.source_commit, self.source_tree), copy_root.resolve())
            (copy_root / "Package.swift").write_bytes((copy_root / "Package.swift").read_bytes() + b"\n")
            with self.assertRaisesRegex(PackageError, "content differs"):
                validate_source_copy(self.source_root, copy_root, manifest, self.source_commit, self.source_tree)

    def test_source_input_manifest_rejects_unknown_fields_and_noninteger_versions(self):
        with tempfile.TemporaryDirectory() as temp:
            _, manifest_path = copy_source_inputs(
                self.source_root,
                self.source_commit,
                self.source_tree,
                Path(temp) / "isolated-build",
            )
            original = json.loads(manifest_path.read_text())
            invalid_manifests = []
            wrong_version = json.loads(json.dumps(original))
            wrong_version["schemaVersion"] = True
            invalid_manifests.append(("schema version type", wrong_version))
            unknown_top_level = json.loads(json.dumps(original))
            unknown_top_level["unredactedDebugPath"] = str(Path(temp) / "private-source-manifest-path")
            invalid_manifests.append(("unknown top-level field", unknown_top_level))
            unknown_file_field = json.loads(json.dumps(original))
            unknown_file_field["files"][0]["unredactedDebugPath"] = str(Path(temp) / "private-source-file-path")
            invalid_manifests.append(("unknown file field", unknown_file_field))
            absolute_file_path = json.loads(json.dumps(original))
            absolute_file_path["files"][0]["path"] = str(Path(temp) / "private-source-file-path")
            invalid_manifests.append(("absolute file path", absolute_file_path))
            wrong_file_type = json.loads(json.dumps(original))
            wrong_file_type["files"][0]["size"] = True
            invalid_manifests.append(("file size type", wrong_file_type))
            for label, manifest in invalid_manifests:
                with self.subTest(label=label):
                    manifest_path.write_text(json.dumps(manifest))
                    with self.assertRaises(PackageError) as caught:
                        packager.read_source_input_manifest(manifest_path)
                    self.assertNotIn("private-source-", str(caught.exception))

    def test_strict_json_decoder_rejects_duplicate_keys_and_nonstandard_numbers(self):
        cases = (
            ("top-level duplicate", '{"repository":"safe","repository":"private-sentinel"}', "JSON object contains duplicate keys"),
            ("nested duplicate", '{"outer":{"path":"safe","path":"private-sentinel"}}', "JSON object contains duplicate keys"),
            ("escaped duplicate", '{"outer":{"repository":"safe","repo\\u0073itory":"private-sentinel"}}', "JSON object contains duplicate keys"),
            ("NaN", '{"value":NaN}', "JSON contains a nonstandard numeric constant"),
            ("positive Infinity", '{"value":Infinity}', "JSON contains a nonstandard numeric constant"),
            ("negative Infinity", '{"value":-Infinity}', "JSON contains a nonstandard numeric constant"),
        )
        for label, payload, safe_message in cases:
            with self.subTest(label=label), self.assertRaises(ValueError) as caught:
                packager.strict_json_loads(payload)
            self.assertEqual(str(caught.exception), safe_message)
            self.assertNotIn("private-sentinel", str(caught.exception))

    def test_source_copy_rejects_terminal_dotdot_source_ancestor_before_writing(self):
        with tempfile.TemporaryDirectory() as temp:
            parent = Path(temp)
            source = self.clone_source(parent)
            alias_component = parent / "build-root-parent"
            alias_component.mkdir()
            build_root = alias_component / ".."
            with self.assertRaisesRegex(PackageError, "build root must be separate from the source checkout"):
                copy_source_inputs(source, self.source_commit, self.source_tree, build_root)
            self.assertFalse((parent / "source").exists())
            self.assertFalse((parent / SOURCE_INPUT_MANIFEST_FILE).exists())

    def test_source_copy_rejects_dirty_or_mismatched_source_before_creating_build_root(self):
        with tempfile.TemporaryDirectory() as temp:
            source = self.clone_source(Path(temp))
            build_root = Path(temp) / "must-not-exist"
            (source / "untracked-packaging-test.txt").write_text("dirty")
            with self.assertRaisesRegex(PackageError, "worktree must be clean"):
                copy_source_inputs(source, self.source_commit, self.source_tree, build_root)
            self.assertFalse(build_root.exists())
        with tempfile.TemporaryDirectory() as temp:
            build_root = Path(temp) / "must-not-exist"
            with self.assertRaises(PackageError):
                copy_source_inputs(self.source_root, self.source_commit, "0" * 40, build_root)
            self.assertFalse(build_root.exists())

    def test_source_copy_rejects_assume_unchanged_mutation_before_creating_build_root(self):
        with tempfile.TemporaryDirectory() as temp:
            source = self.clone_source(Path(temp))
            license_path = source / "LICENSE"
            subprocess.run(
                ["git", "update-index", "--assume-unchanged", "--", "LICENSE"],
                cwd=source,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            license_path.write_bytes(license_path.read_bytes() + b"\nlocal mutation")
            status = packager.run(["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=source).strip()
            self.assertEqual(status, "")
            build_root = Path(temp) / "must-not-exist"
            with self.assertRaisesRegex(PackageError, "differs from committed Git blob: LICENSE"):
                copy_source_inputs(source, self.source_commit, self.source_tree, build_root)
            self.assertFalse(build_root.exists())

    def test_source_blob_verification_compares_raw_committed_symlink_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            source = self.clone_source(Path(temp))
            relative = "packaging-test-symlink"
            link = source / relative
            target = "relative-target-bytes"
            link.symlink_to(target)
            subprocess.run(
                ["git", "add", "--", relative],
                cwd=source,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            tree = packager.run(["git", "write-tree"], cwd=source).strip()
            entries = source_git_files(source, tree)
            entry = next(item for item in entries if item["path"] == relative)
            self.assertEqual(entry["kind"], "symlink")
            blob = git_blob_contents(source, [entry["gitBlobSHA"]])[entry["gitBlobSHA"]]
            self.assertEqual(blob, os.fsencode(target))
            link.unlink()
            link.symlink_to("different-target-bytes")
            with self.assertRaisesRegex(PackageError, "differs from committed Git blob: packaging-test-symlink"):
                source_git_files(source, tree)

    def test_source_copy_refuses_existing_inputs_without_removing_them(self):
        with tempfile.TemporaryDirectory() as temp:
            build_root = Path(temp) / "isolated-build"
            build_root.mkdir()
            marker = build_root / "source/keep.txt"
            marker.parent.mkdir()
            marker.write_text("preserve")
            with self.assertRaisesRegex(PackageError, "refusing to overwrite"):
                copy_source_inputs(self.source_root, self.source_commit, self.source_tree, build_root)
            self.assertEqual(marker.read_text(), "preserve")
            self.assertFalse((build_root / SOURCE_INPUT_MANIFEST_FILE).exists())

    def test_build_provenance_binds_copy_lockfiles_and_exact_product_hashes(self):
        with tempfile.TemporaryDirectory() as temp:
            build_root, copy_root, manifest_path, product, provenance_path = self.make_build_fixture(Path(temp))
            record = validate_build_provenance(
                provenance_path,
                self.source_root,
                product,
                build_root,
                self.source_commit,
                self.source_tree,
                TEST_CERTIFICATE_SHA1,
                self.signing_keychain_path,
                self.codesign_pin,
            )
            self.assertEqual(record["sourceCommitSHA"], self.source_commit)
            self.assertEqual(record["sourceTreeSHA"], self.source_tree)
            self.assertEqual(record["schemaVersion"], 6)
            self.assertEqual(record["inputCopyRelativePath"], "source")
            self.assertEqual(record["buildInputs"]["lockFilesSHA256"], {path: sha256_file(self.source_root / path) for path in LOCK_FILES})
            self.assertEqual(record["build"]["command"], normalized_release_build_command())
            self.assertEqual(record["build"]["workingDirectoryRelativePath"], "source")
            self.assertEqual(record["build"]["signingCertificateSHA1"], TEST_CERTIFICATE_SHA1)
            expected_keychain_path_hash = identity_keychain_path_sha256(self.signing_keychain_path.resolve())
            self.assertEqual(record["build"]["identityKeychainPathSHA256"], expected_keychain_path_hash)
            self.assertEqual(record["build"]["codesignExecutableSHA256"], self.codesign_executable_sha256)
            self.assertEqual(record["product"]["signatureReceipt"]["certificateSHA1"], TEST_CERTIFICATE_SHA1)
            self.assertEqual(record["product"]["signatureReceipt"]["identityKeychainPathSHA256"], expected_keychain_path_hash)
            self.assertEqual(record["product"]["signatureReceipt"]["bundle"]["identifier"], EXPECTED_BUNDLE_ID)
            execution = record["product"]["signingExecutionReceipt"]
            self.assertEqual(execution["representation"], "PUBLIC-REDACTED-OBSERVED-ORDERED-ARGV")
            self.assertEqual(execution["producer"], "builder")
            self.assertEqual(execution["identityKeychainPathSHA256"], expected_keychain_path_hash)
            self.assertEqual(execution["codesignExecutablePathSHA256"], hashlib.sha256(str(self.codesign_executable_path).encode()).hexdigest())
            self.assertEqual(execution["codesignExecutableFilesystemIdentity"]["inode"], self.codesign_pin.filesystem_identity[1])
            self.assertEqual(execution["signedBundleFilesystemIdentity"]["inode"], product.stat().st_ino)
            self.assertEqual(len(execution["calls"]), 2)
            self.assertEqual(execution["calls"][0]["argv"][-1], {"selector": "bundle-relative-target", "path": "Contents/MacOS/imrse"})
            private = packager.read_private_signing_receipt(self.private_builder_receipt_path(build_root), product)
            self.assertEqual(private["evidenceRepresentation"], "PRIVATE-OBSERVED-UNREDACTED-ARGV-AND-CONTEXT")
            self.assertEqual(private["producer"], "builder")
            self.assertEqual(private["privateEvidence"]["vector"]["calls"][0]["argv"][-1], str(build_root / "products/.private-signing-stage/imrse.app/Contents/MacOS/imrse"))
            self.assertEqual(private["privateReceiptStorage"]["file"]["mode"], 0o600)
            self.assertEqual(private["privateReceiptStorage"]["directory"]["mode"], 0o700)
            self.assertIn("not an independent compiler", record["build"]["provenanceScope"])
            self.assertNotIn(str(build_root), json.dumps(record["build"]))
            self.assertNotIn(str(self.signing_keychain_path), json.dumps(record))
            self.assertNotIn(str(self.signing_keychain_path.parent), json.dumps(record))
            self.assertNotIn(str(self.codesign_executable_path), json.dumps(record))
            self.assertNotIn(str(self.private_builder_receipt_path(build_root)), json.dumps(record))
            self.assertEqual(manifest_path.name, SOURCE_INPUT_MANIFEST_FILE)
            self.assertEqual(copy_root.resolve(), (build_root / "source").resolve())
            (product / "Contents/MacOS/imrse").write_bytes(b"changed after provenance")
            with self.assertRaisesRegex(PackageError, "hashes"):
                validate_build_provenance(
                    provenance_path,
                    self.source_root,
                    product,
                    build_root,
                    self.source_commit,
                    self.source_tree,
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                )

    def test_record_build_cli_preserves_option_like_builder_argv_values(self):
        build_root = Path("/tmp/record-build-fixture")
        working_directory = build_root / "source"
        command = expected_release_build_command(build_root)
        argv = [
            "record-build",
            "--source-root",
            str(self.source_root),
            "--source-commit",
            self.source_commit,
            "--source-tree",
            self.source_tree,
            "--build-root",
            str(build_root),
            "--working-directory",
            str(working_directory),
            "--signing-certificate-sha1",
            TEST_CERTIFICATE_SHA1,
            "--signing-keychain-path",
            str(self.signing_keychain_path),
            "--codesign-executable",
            str(self.codesign_executable_path),
            "--codesign-sha256",
            self.codesign_executable_sha256,
            "--signing-execution-receipt",
            str(build_root / "private/signing-receipt.json"),
            *(f"--build-command-arg={argument}" for argument in command),
        ]
        with patch.object(packager, "record_build_provenance", return_value=build_root / BUILD_PROVENANCE_FILE) as recorder:
            with redirect_stdout(StringIO()):
                result = packager.main(argv)
        self.assertEqual(result, 0)
        self.assertEqual(recorder.call_args.args[4], working_directory)
        self.assertEqual(recorder.call_args.args[5], command)
        self.assertEqual(recorder.call_args.args[6], TEST_CERTIFICATE_SHA1)
        self.assertEqual(recorder.call_args.args[7], self.signing_keychain_path)
        self.assertEqual(recorder.call_args.args[8], self.codesign_pin)
        self.assertEqual(recorder.call_args.args[9], build_root / "private/signing-receipt.json")

    def test_certificate_sha1_requires_one_explicit_40_hex_selector(self):
        self.assertEqual(normalize_certificate_sha1(TEST_CERTIFICATE_SHA1.upper()), TEST_CERTIFICATE_SHA1)
        for invalid in (None, "", "-", "a" * 39, "g" * 40, "a" * 39 + ":"):
            with self.subTest(invalid=invalid):
                with self.assertRaisesRegex(PackageError, "caller-selected 40-hex certificate SHA-1"):
                    normalize_certificate_sha1(invalid)

    def test_signing_keychain_requires_explicit_absolute_existing_regular_file_metadata(self):
        self.assertEqual(
            normalize_signing_keychain_path(self.signing_keychain_path),
            self.signing_keychain_path.resolve(),
        )
        directory = Path(self.keychain_temp.name)
        for invalid in (
            None,
            "",
            Path("relative.keychain-db"),
            Path("~/selected.keychain-db"),
            directory / "missing.keychain-db",
            directory,
        ):
            with self.subTest(invalid=invalid), self.assertRaises(PackageError):
                normalize_signing_keychain_path(invalid)

    def test_codesign_executable_pin_requires_explicit_path_hash_and_stable_file(self):
        self.assertEqual(self.codesign_pin.path, self.codesign_executable_path.resolve())
        self.assertEqual(self.codesign_pin.sha256, self.codesign_executable_sha256)
        for path, digest in (
            (None, self.codesign_executable_sha256),
            (Path("relative-codesign"), self.codesign_executable_sha256),
            (self.codesign_executable_path, "f" * 64),
            (self.codesign_executable_path, "f" * 63),
        ):
            with self.subTest(path=path, digest=digest), self.assertRaises(PackageError):
                pin_codesign_executable(path, digest)
        alias = Path(self.keychain_temp.name) / "codesign-alias"
        alias.symlink_to(self.codesign_executable_path)
        with self.assertRaisesRegex(PackageError, "physically stable"):
            pin_codesign_executable(alias, self.codesign_executable_sha256)
        replacement = Path(self.keychain_temp.name) / "replacement"
        replacement.write_bytes(self.codesign_executable_path.read_bytes())
        replacement.chmod(0o700)
        replacement.replace(self.codesign_executable_path)
        with self.assertRaisesRegex(PackageError, "changed identity or SHA-256"):
            packager.validate_codesign_executable_pin(self.codesign_pin)

    def test_final_signing_uses_same_certificate_for_bundle_and_nested_macho(self):
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp) / "imrse.app"
            main = bundle / "Contents/MacOS/imrse"
            nested = bundle / "Contents/Frameworks/helper"
            main.parent.mkdir(parents=True)
            nested.parent.mkdir(parents=True)
            main.write_bytes(b"\xcf\xfa\xed\xfe fake main Mach-O")
            nested.write_bytes(b"\xcf\xfa\xed\xfe fake nested Mach-O")
            self.codesign_identifiers[str(nested.resolve())] = "com.example.helper"
            self.codesign_commented_designated_requirements.add(str(nested.resolve()))
            result = packager.sign_app_bundle(bundle, TEST_CERTIFICATE_SHA1.upper(), self.signing_keychain_path, self.codesign_pin)
        receipt = result["signatureReceipt"]
        self.assertEqual(receipt["certificateSHA1"], TEST_CERTIFICATE_SHA1)
        self.assertEqual(
            receipt["identityKeychainPathSHA256"],
            identity_keychain_path_sha256(self.signing_keychain_path.resolve()),
        )
        self.assertEqual(receipt["codesignExecutableSHA256"], self.codesign_executable_sha256)
        self.assertEqual(receipt["bundle"]["identifier"], EXPECTED_BUNDLE_ID)
        self.assertEqual(
            {item["relativePath"]: item["identifier"] for item in receipt["codeItems"]},
            {"Contents/MacOS/imrse": EXPECTED_BUNDLE_ID, "Contents/Frameworks/helper": "com.example.helper"},
        )
        self.assertEqual(self.codesign_signers, [TEST_CERTIFICATE_SHA1] * 3)
        self.assertEqual(self.codesign_identity_keychains, [str(self.signing_keychain_path.resolve())] * 3)
        self.assertEqual(result["signingExecutionReceipt"]["representation"], "PUBLIC-REDACTED-OBSERVED-ORDERED-ARGV")
        self.assertEqual(result["signingExecutionReceipt"]["producer"], "builder")
        self.assertEqual(len(result["signingExecutionReceipt"]["calls"]), 3)
        self.assertEqual(len(result["privateSigningVector"]["calls"]), 3)
        self.assertEqual(result["privateSigningVector"]["calls"][0]["argv"][0], str(self.codesign_executable_path))
        self.assertEqual(result["privateSigningVector"]["calls"][0]["argv"][3], str(self.signing_keychain_path.resolve()))
        public_json = json.dumps(result["signingExecutionReceipt"])
        self.assertNotIn(str(self.codesign_executable_path), public_json)
        self.assertNotIn(str(self.signing_keychain_path), public_json)
        nested_receipt = next(item for item in receipt["codeItems"] if item["relativePath"] == "Contents/Frameworks/helper")
        self.assertEqual(nested_receipt["defaultDesignatedRequirement"], f'identifier "com.example.helper" and anchor apple generic and certificate leaf H"{TEST_CERTIFICATE_SHA1}"')
        verification_commands = [command for command in self.codesign_calls if "--verify" in command]
        self.assertTrue(all(command[0] == str(self.codesign_executable_path) for command in self.codesign_calls))
        self.assertEqual(len(verification_commands), 3)
        self.assertTrue(all(f'-R=certificate leaf H"{TEST_CERTIFICATE_SHA1}"' in command for command in verification_commands))
        self.assertTrue(any("--deep" in command for command in verification_commands))
        first_leaf_verification = next(index for index, command in enumerate(self.codesign_calls) if "--verify" in command)
        first_default_requirement_read = next(index for index, command in enumerate(self.codesign_calls) if "-r-" in command)
        self.assertLess(first_leaf_verification, first_default_requirement_read)

    def test_private_signing_receipt_keeps_actual_vectors_outside_public_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            bundle = base / "imrse.app"
            main = bundle / "Contents/MacOS/imrse"
            main.parent.mkdir(parents=True)
            main.write_bytes(b"\xcf\xfa\xed\xfe fake main Mach-O")
            receipt_path = base / "private-stage/signing-execution-receipt.json"
            receipt_path.parent.mkdir(mode=0o700)
            secret_home = base / "private-home"
            secret_tmp = base / "private-tmp"
            with patch.dict(os.environ, {"HOME": str(secret_home), "TMPDIR": str(secret_tmp)}):
                signing_result = packager.sign_app_bundle(bundle, TEST_CERTIFICATE_SHA1, self.signing_keychain_path, self.codesign_pin)
                self.create_private_signing_receipt(bundle, receipt_path, signing_result)
            private_receipt = packager.read_private_signing_receipt(receipt_path, bundle)
            private_vector = private_receipt["privateEvidence"]["vector"]
            public_receipt = signing_result["signingExecutionReceipt"]
            self.assertEqual(private_vector["calls"][0]["argv"][-1], str(main.resolve()))
            self.assertEqual(private_vector["calls"][1]["argv"][-1], str(bundle.resolve()))
            self.assertEqual(private_vector["calls"][0]["context"]["home"], str(secret_home))
            self.assertEqual(private_vector["calls"][0]["context"]["temporaryDirectory"], str(secret_tmp))
            self.assertEqual(private_vector["calls"][0]["context"]["workingDirectory"], os.getcwd())
            self.assertEqual(private_receipt["privateReceiptStorage"]["file"]["mode"], 0o600)
            self.assertEqual(private_receipt["privateReceiptStorage"]["directory"]["mode"], 0o700)
            self.assertEqual(receipt_path.stat().st_uid, os.getuid())
            self.assertEqual(receipt_path.stat().st_nlink, 1)
            self.assertNotEqual(receipt_path.parent, bundle)
            self.assertFalse((bundle / receipt_path.name).exists())
            public_json = json.dumps(public_receipt)
            for private_value in (str(secret_home), str(secret_tmp), str(self.signing_keychain_path), str(self.codesign_executable_path), str(bundle), str(receipt_path)):
                self.assertNotIn(private_value, public_json)
            self.assertEqual(public_receipt["representation"], "PUBLIC-REDACTED-OBSERVED-ORDERED-ARGV")
            self.assertEqual(public_receipt["calls"][0]["argv"][-1], {"selector": "bundle-relative-target", "path": "Contents/MacOS/imrse"})
            self.assertEqual(
                public_receipt["calls"][0]["executionContext"]["workingDirectoryPathSHA256"],
                hashlib.sha256(os.getcwd().encode("utf-8")).hexdigest(),
            )
            self.assertEqual(
                public_receipt["calls"][0]["executionContext"]["homePathSHA256"],
                hashlib.sha256(str(secret_home).encode("utf-8")).hexdigest(),
            )
            self.assertEqual(public_receipt["codesignExecutableFilesystemIdentity"]["inode"], self.codesign_pin.filesystem_identity[1])
            self.assertEqual(public_receipt["signedBundleFilesystemIdentity"]["inode"], bundle.stat().st_ino)

    def test_candidate_private_signature_receipt_rejects_unknown_path_fields(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            bundle = base / "imrse.app"
            main = bundle / "Contents/MacOS/imrse"
            main.parent.mkdir(parents=True)
            main.write_bytes(b"\xcf\xfa\xed\xfe candidate executable")
            receipt_path = base / "private-stage/candidate-signing-receipt.json"
            receipt_path.parent.mkdir(mode=0o700)
            signing_result = sign_and_verify(
                bundle,
                [main],
                TEST_CERTIFICATE_SHA1,
                self.signing_keychain_path,
                self.codesign_pin,
                producer="candidate",
            )
            self.create_private_signing_receipt(
                bundle,
                receipt_path,
                result=signing_result,
                producer="candidate",
            )
            receipt = packager.read_private_signing_receipt(receipt_path, bundle)
            receipt["signatureReceipt"]["unredactedDebugPath"] = str(base / "private-signature-path")
            receipt_path.write_text(json.dumps(receipt))
            with self.assertRaises(PackageError) as caught:
                packager.validate_private_signing_receipt(
                    packager.read_private_signing_receipt(receipt_path, bundle),
                    "candidate",
                    bundle,
                    [main],
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                )
            self.assertNotIn("private-signature-path", str(caught.exception))

    def test_imported_schema6_provenance_rejects_unknown_path_fields(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            build_root, _, _, product, provenance_path = self.make_build_fixture(base)
            original = json.loads(provenance_path.read_text())
            sentinel = str(base / "private-public-path")
            injection_paths = (
                ("provenance", ()),
                ("source input manifest", ("sourceInputManifest",)),
                ("build inputs", ("buildInputs",)),
                ("build", ("build",)),
                ("product", ("product",)),
                ("execution receipt", ("product", "signingExecutionReceipt")),
                ("call", ("product", "signingExecutionReceipt", "calls", 0)),
                ("identity", ("product", "signingExecutionReceipt", "calls", 0, "codesignExecutableFilesystemIdentity")),
                ("context", ("product", "signingExecutionReceipt", "calls", 0, "executionContext")),
                ("signature receipt", ("product", "signatureReceipt")),
                ("signature bundle", ("product", "signatureReceipt", "bundle")),
                ("signature code item", ("product", "signatureReceipt", "codeItems", 0)),
            )
            for label, path in injection_paths:
                with self.subTest(label=label):
                    record = json.loads(json.dumps(original))
                    target = record
                    for key in path:
                        target = target[key]
                    target["unredactedDebugPath"] = sentinel
                    execution = record["product"]["signingExecutionReceipt"]
                    execution["redactedVectorSHA256"] = packager.canonical_json_sha256(execution["calls"])
                    provenance_path.write_text(json.dumps(record))
                    with self.assertRaises(PackageError) as caught:
                        validate_build_provenance(
                            provenance_path,
                            self.source_root,
                            product,
                            build_root,
                            self.source_commit,
                            self.source_tree,
                            TEST_CERTIFICATE_SHA1,
                            self.signing_keychain_path,
                            self.codesign_pin,
                        )
                    self.assertNotIn(sentinel, str(caught.exception))

    def test_private_signing_receipt_rejects_collisions_insecure_storage_and_in_bundle_paths(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            bundle = base / "imrse.app"
            (bundle / "Contents/MacOS").mkdir(parents=True)
            (bundle / "Contents/MacOS/imrse").write_bytes(b"\xcf\xfa\xed\xfe fake executable")
            bundle.chmod(0o700)
            private_stage = base / "private-stage"
            private_stage.mkdir(mode=0o700)
            collision = private_stage / "signing-receipt.json"
            collision.write_text("existing")
            with self.assertRaisesRegex(PackageError, "created exclusively"):
                packager.reserve_private_signing_receipt(collision, bundle)
            with self.assertRaisesRegex(PackageError, "outside the app"):
                packager.reserve_private_signing_receipt(bundle / "receipt.json", bundle)
            public_stage = base / "public-stage"
            public_stage.mkdir(mode=0o755)
            with self.assertRaisesRegex(PackageError, "owner-private directory"):
                packager.reserve_private_signing_receipt(public_stage / "receipt.json", bundle)
            self.assertEqual(self.codesign_calls, [])

    def test_private_signing_receipt_reservation_is_single_write(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            bundle = base / "imrse.app"
            main = bundle / "Contents/MacOS/imrse"
            main.parent.mkdir(parents=True)
            main.write_bytes(b"\xcf\xfa\xed\xfe fake executable")
            receipt_path = base / "private-stage/receipt.json"
            receipt_path.parent.mkdir(mode=0o700)
            signing_result = packager.sign_app_bundle(bundle, TEST_CERTIFICATE_SHA1, self.signing_keychain_path, self.codesign_pin)
            receipt_payload = packager.private_signing_receipt_payload(
                signing_result,
                "builder",
                bundle,
                TEST_CERTIFICATE_SHA1,
                self.signing_keychain_path,
                self.codesign_pin,
            )
            reservation = packager.reserve_private_signing_receipt(receipt_path, bundle)
            packager.write_private_signing_receipt(reservation, receipt_payload)
            with self.assertRaisesRegex(PackageError, "already been written"):
                packager.write_private_signing_receipt(reservation, receipt_payload)
            packager.close_private_signing_receipt_reservation(reservation)
            self.assertEqual(packager.read_private_signing_receipt(receipt_path, bundle)["producer"], "builder")

    def test_private_signing_receipt_uses_nonblocking_open_and_rejects_entry_replacement(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            bundle = base / "imrse.app"
            (bundle / "Contents/MacOS").mkdir(parents=True)
            receipt_path = base / "private-stage/receipt.json"
            receipt_path.parent.mkdir(mode=0o700)
            original_open = os.open

            def assert_nonblocking_open(path, flags, *args, **kwargs):
                if path == receipt_path.name and "dir_fd" in kwargs:
                    if not flags & os.O_NONBLOCK:
                        raise AssertionError("receipt file must be opened nonblocking")
                return original_open(path, flags, *args, **kwargs)

            os.mkfifo(receipt_path, 0o600)
            with patch.object(packager.os, "open", side_effect=assert_nonblocking_open):
                with self.assertRaisesRegex(PackageError, "owner-only exclusive regular file"):
                    packager.read_private_signing_receipt(receipt_path, bundle)

            receipt_path.unlink()
            receipt_path.write_text("{}")
            receipt_path.chmod(0o600)

            def replace_after_open(path, flags, *args, **kwargs):
                fd = assert_nonblocking_open(path, flags, *args, **kwargs)
                if path == receipt_path.name and "dir_fd" in kwargs:
                    receipt_path.unlink()
                    os.mkfifo(receipt_path, 0o600)
                return fd

            with patch.object(packager.os, "open", side_effect=replace_after_open):
                with self.assertRaisesRegex(PackageError, "identity changed while reading"):
                    packager.read_private_signing_receipt(receipt_path, bundle)

    def test_record_build_rejects_private_argv_and_identity_tampering_without_leaking_paths(self):
        tampering = ("operand", "filesystem identity", "selected keychain")
        for label in tampering:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp:
                build_root, copy_root, _, product, provenance_path = self.make_build_fixture(Path(temp))
                receipt_path = self.private_builder_receipt_path(build_root)
                receipt = json.loads(receipt_path.read_text())
                vector = receipt["privateEvidence"]["vector"]
                if label == "operand":
                    vector["calls"][0]["argv"][-1] = str(Path(temp) / "private-operand")
                elif label == "filesystem identity":
                    vector["signedBundleFilesystemIdentity"]["inode"] += 1
                else:
                    alternate_keychain = Path(temp) / "alternate.keychain-db"
                    alternate_keychain.touch()
                    vector["identityKeychainPath"] = str(alternate_keychain.resolve())
                    vector["identityKeychainPathSHA256"] = identity_keychain_path_sha256(alternate_keychain.resolve())
                    for call in vector["calls"]:
                        call["argv"][3] = str(alternate_keychain.resolve())
                receipt["privateEvidence"]["vectorSHA256"] = packager.canonical_json_sha256(vector)
                receipt_path.write_text(json.dumps(receipt))
                provenance_path.unlink()
                with self.assertRaises(PackageError) as caught:
                    record_build_provenance(
                        self.source_root,
                        self.source_commit,
                        self.source_tree,
                        build_root,
                        copy_root,
                        expected_release_build_command(build_root),
                        TEST_CERTIFICATE_SHA1,
                        self.signing_keychain_path,
                        self.codesign_pin,
                        receipt_path,
                    )
                self.assertNotIn(str(Path(temp)), str(caught.exception))
                self.assertFalse(provenance_path.exists())

    def test_designated_requirement_rejects_missing_empty_or_duplicate_lines(self):
        for label, output in (
            ("missing", ""),
            ("empty", "# designated =>\n"),
            ("ambiguous", 'designated => identifier "one"\n# designated => identifier "two"\n'),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp:
                bundle = Path(temp) / "imrse.app"
                main = bundle / "Contents/MacOS/imrse"
                main.parent.mkdir(parents=True)
                main.write_bytes(b"\xcf\xfa\xed\xfe fake main Mach-O")
                self.codesign_designated_outputs[str(main.resolve())] = output
                with self.assertRaisesRegex(PackageError, "default designated requirement is missing or ambiguous"):
                    sign_and_verify(bundle, [main], TEST_CERTIFICATE_SHA1, self.signing_keychain_path, self.codesign_pin)

    def test_certificate_signer_rejects_adhoc_and_mismatched_certificate_output(self):
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp) / "imrse.app"
            main = bundle / "Contents/MacOS/imrse"
            main.parent.mkdir(parents=True)
            main.write_bytes(b"\xcf\xfa\xed\xfe fake main Mach-O")
            self.codesign_signature_type = "ad-hoc"
            with self.assertRaisesRegex(PackageError, "does not satisfy the selected certificate"):
                sign_and_verify(bundle, [main], TEST_CERTIFICATE_SHA1, self.signing_keychain_path, self.codesign_pin)
            self.codesign_signature_type = "certificate-signed"
            self.codesign_actual_sha1 = "f" * 40
            with self.assertRaisesRegex(PackageError, "does not satisfy the selected certificate"):
                sign_and_verify(bundle, [main], TEST_CERTIFICATE_SHA1, self.signing_keychain_path, self.codesign_pin)
            with self.assertRaisesRegex(PackageError, "no matching signing identity"):
                sign_and_verify(bundle, [main], "f" * 40, self.signing_keychain_path, self.codesign_pin)

    def test_codesign_executable_physical_identity_must_survive_each_invocation(self):
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp) / "imrse.app"
            main = bundle / "Contents/MacOS/imrse"
            main.parent.mkdir(parents=True)
            main.write_bytes(b"\xcf\xfa\xed\xfe fake main Mach-O")

            def replace_after_sign(command, **kwargs):
                result = self.stub_packager_run(command, **kwargs)
                if "--sign" in command:
                    replacement = self.codesign_executable_path.with_name("same-content-replacement")
                    replacement.write_bytes(self.codesign_executable_path.read_bytes())
                    replacement.chmod(0o700)
                    replacement.replace(self.codesign_executable_path)
                return result

            with patch.object(packager, "run", side_effect=replace_after_sign):
                with self.assertRaisesRegex(PackageError, "changed identity or SHA-256"):
                    sign_and_verify(bundle, [main], TEST_CERTIFICATE_SHA1, self.signing_keychain_path, self.codesign_pin)

    def test_build_provenance_rejects_wrong_builder_argv_paths_and_working_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp).resolve(strict=True)
            build_root = base / "isolated-build"
            copy_root, _ = copy_source_inputs(
                self.source_root,
                self.source_commit,
                self.source_tree,
                build_root,
            )
            product = build_root / "products/imrse.app"
            (product / "Contents/MacOS").mkdir(parents=True)
            (product / "Contents/MacOS/imrse").write_bytes(b"\xcf\xfa\xed\xfe fake product executable")
            (product / "Contents/Info.plist").write_bytes((self.source_root / "Resources/Info.plist").read_bytes())
            expected = expected_release_build_command(build_root)

            wrong_configuration = expected.copy()
            wrong_configuration[wrong_configuration.index("--configuration") + 1] = "debug"
            wrong_product = expected.copy()
            wrong_product[wrong_product.index("--product") + 1] = "different-product"
            reordered = expected.copy()
            cache_index = reordered.index("--cache-path")
            config_index = reordered.index("--config-path")
            reordered[cache_index:cache_index + 2], reordered[config_index:config_index + 2] = (
                reordered[config_index:config_index + 2],
                reordered[cache_index:cache_index + 2],
            )
            free_token = [*expected, "release"]
            missing_build_system = expected.copy()
            build_system_index = missing_build_system.index("--build-system")
            del missing_build_system[build_system_index:build_system_index + 2]
            outside_scratch = expected.copy()
            outside_scratch[outside_scratch.index("--scratch-path") + 1] = str(base / "outside-scratch")

            for label, command in (
                ("configuration", wrong_configuration),
                ("product", wrong_product),
                ("order", reordered),
                ("free token", free_token),
                ("build system", missing_build_system),
                ("path", outside_scratch),
            ):
                with self.subTest(label=label):
                    with self.assertRaisesRegex(PackageError, "exact isolated Release invocation"):
                        record_build_provenance(
                            self.source_root,
                            self.source_commit,
                            self.source_tree,
                            build_root,
                            copy_root,
                            command,
                            TEST_CERTIFICATE_SHA1,
                            self.signing_keychain_path,
                            self.codesign_pin,
                            self.private_builder_receipt_path(build_root),
                        )
                    self.assertFalse((build_root / BUILD_PROVENANCE_FILE).exists())

            with self.assertRaisesRegex(PackageError, "working directory must be the isolated copied source"):
                record_build_provenance(
                    self.source_root,
                    self.source_commit,
                    self.source_tree,
                    build_root,
                    self.source_root,
                    expected,
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                    self.private_builder_receipt_path(build_root),
                )
            self.assertFalse((build_root / BUILD_PROVENANCE_FILE).exists())

            self.create_private_signing_receipt(
                product,
                self.private_builder_receipt_path(build_root),
            )
            provenance_path = record_build_provenance(
                self.source_root,
                self.source_commit,
                self.source_tree,
                build_root,
                copy_root,
                expected,
                TEST_CERTIFICATE_SHA1,
                self.signing_keychain_path,
                self.codesign_pin,
                self.private_builder_receipt_path(build_root),
            )
            record = json.loads(provenance_path.read_text())
            self.assertEqual(record["build"]["command"], normalized_release_build_command())
            record["build"]["command"] = [
                "swift",
                "build",
                "--configuration",
                "debug",
                "--product",
                "different-product",
                "--only-use-versions-from-resolved-file",
                "release",
                "imrse",
            ]
            provenance_path.write_text(json.dumps(record))
            with self.assertRaisesRegex(PackageError, "does not match the isolated Release builder record"):
                validate_build_provenance(
                    provenance_path,
                    self.source_root,
                    product,
                    build_root,
                    self.source_commit,
                    self.source_tree,
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                )

    def test_record_build_provenance_rejects_duplicate_private_receipt_keys(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp).resolve(strict=True)
            build_root, copy_root, _, _, provenance_path = self.make_build_fixture(base)
            private_receipt_path = self.private_builder_receipt_path(build_root)
            private_path_sentinel = str(base / "PRIVATE_SENTINEL/Keychains/login.keychain-db")
            receipt = private_receipt_path.read_text()
            duplicate_producer = f'"producer": {json.dumps(private_path_sentinel)},\n  "producer": "builder",'
            self.assertIn('"producer": "builder",', receipt)
            private_receipt_path.write_text(receipt.replace('"producer": "builder",', duplicate_producer, 1))
            provenance_path.unlink()

            with self.assertRaises(PackageError) as caught:
                record_build_provenance(
                    self.source_root,
                    self.source_commit,
                    self.source_tree,
                    build_root,
                    copy_root,
                    expected_release_build_command(build_root),
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                    private_receipt_path,
                )

            self.assertNotIn(private_path_sentinel, str(caught.exception))
            self.assertEqual(str(caught.exception), "private signing receipt is invalid JSON")
            self.assertFalse(provenance_path.exists())

    def test_build_provenance_rejects_manifest_changes_and_later_source_dirt(self):
        with tempfile.TemporaryDirectory() as temp:
            build_root, _, manifest_path, product, provenance_path = self.make_build_fixture(Path(temp))
            manifest = json.loads(manifest_path.read_text())
            manifest["sourceTreeSHA"] = "0" * 40
            manifest_path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(PackageError, "manifest does not match"):
                validate_build_provenance(
                    provenance_path,
                    self.source_root,
                    product,
                    build_root,
                    self.source_commit,
                    self.source_tree,
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                )
        with tempfile.TemporaryDirectory() as temp:
            source = self.clone_source(Path(temp))
            build_root, _, _, product, provenance_path = self.make_build_fixture(Path(temp))
            (source / "untracked-after-build.txt").write_text("dirty")
            with self.assertRaisesRegex(PackageError, "worktree must be clean"):
                validate_build_provenance(
                    provenance_path,
                    source,
                    product,
                    build_root,
                    self.source_commit,
                    self.source_tree,
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                )
        with tempfile.TemporaryDirectory() as temp:
            source = self.clone_source(Path(temp))
            build_root, copy_root, _, product, provenance_path = self.make_build_fixture(Path(temp))
            license_path = source / "LICENSE"
            subprocess.run(
                ["git", "update-index", "--assume-unchanged", "--", "LICENSE"],
                cwd=source,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            license_path.write_bytes(license_path.read_bytes() + b"\nlocal mutation")
            self.assertEqual(packager.run(["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=source).strip(), "")
            with self.assertRaisesRegex(PackageError, "differs from committed Git blob: LICENSE"):
                validate_build_provenance(
                    provenance_path,
                    source,
                    product,
                    build_root,
                    self.source_commit,
                    self.source_tree,
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                )
            provenance_path.unlink()
            with self.assertRaisesRegex(PackageError, "differs from committed Git blob: LICENSE"):
                record_build_provenance(
                    source,
                    self.source_commit,
                    self.source_tree,
                    build_root,
                    copy_root,
                    expected_release_build_command(build_root),
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                    self.private_builder_receipt_path(build_root),
            )
            self.assertFalse(provenance_path.exists())

    def test_build_provenance_rejects_forged_signer_and_designated_requirement_receipts(self):
        for field, replacement in (
            ("certificateSHA1", "f" * 40),
            ("defaultDesignatedRequirement", 'identifier "forged.bundle" and anchor apple generic'),
            ("identifier", "forged.bundle"),
        ):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temp:
                build_root, _, _, product, provenance_path = self.make_build_fixture(Path(temp))
                record = json.loads(provenance_path.read_text())
                record["product"]["signatureReceipt"]["bundle"][field] = replacement
                provenance_path.write_text(json.dumps(record))
                with self.assertRaisesRegex(PackageError, "signature receipt does not match"):
                    validate_build_provenance(
                        provenance_path,
                        self.source_root,
                        product,
                        build_root,
                        self.source_commit,
                        self.source_tree,
                        TEST_CERTIFICATE_SHA1,
                        self.signing_keychain_path,
                        self.codesign_pin,
                    )
        with tempfile.TemporaryDirectory() as temp:
            build_root, _, _, product, provenance_path = self.make_build_fixture(Path(temp))
            record = json.loads(provenance_path.read_text())
            record["build"]["signingCertificateSHA1"] = "f" * 40
            provenance_path.write_text(json.dumps(record))
            with self.assertRaisesRegex(PackageError, "isolated Release builder record"):
                validate_build_provenance(
                    provenance_path,
                    self.source_root,
                    product,
                    build_root,
                    self.source_commit,
                    self.source_tree,
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                )
        with tempfile.TemporaryDirectory() as temp:
            build_root, _, _, product, provenance_path = self.make_build_fixture(Path(temp))
            record = json.loads(provenance_path.read_text())
            different_keychain_path = Path(temp) / "different.keychain-db"
            different_keychain_path.touch()
            record["build"]["identityKeychainPathSHA256"] = identity_keychain_path_sha256(different_keychain_path.resolve())
            provenance_path.write_text(json.dumps(record))
            with self.assertRaisesRegex(PackageError, "isolated Release builder record"):
                validate_build_provenance(
                    provenance_path,
                    self.source_root,
                    product,
                    build_root,
                    self.source_commit,
                    self.source_tree,
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                )
        with tempfile.TemporaryDirectory() as temp:
            build_root, _, _, product, provenance_path = self.make_build_fixture(Path(temp))
            record = json.loads(provenance_path.read_text())
            record["build"]["codesignExecutableSHA256"] = "f" * 64
            provenance_path.write_text(json.dumps(record))
            with self.assertRaisesRegex(PackageError, "isolated Release builder record"):
                validate_build_provenance(
                    provenance_path,
                    self.source_root,
                    product,
                    build_root,
                    self.source_commit,
                    self.source_tree,
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                )
        with tempfile.TemporaryDirectory() as temp:
            build_root, _, _, product, provenance_path = self.make_build_fixture(Path(temp))
            record = json.loads(provenance_path.read_text())
            record["product"]["signatureReceipt"]["codesignExecutableSHA256"] = "f" * 64
            provenance_path.write_text(json.dumps(record))
            with self.assertRaisesRegex(PackageError, "signature receipt does not match"):
                validate_build_provenance(
                    provenance_path,
                    self.source_root,
                    product,
                    build_root,
                    self.source_commit,
                    self.source_tree,
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                )
        with tempfile.TemporaryDirectory() as temp:
            build_root, _, _, product, provenance_path = self.make_build_fixture(Path(temp))
            self.codesign_actual_sha1 = "f" * 40
            with self.assertRaisesRegex(PackageError, "does not satisfy the selected certificate"):
                validate_build_provenance(
                    provenance_path,
                    self.source_root,
                    product,
                    build_root,
                    self.source_commit,
                    self.source_tree,
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                )

    def test_ci_validation_receipt_blocks_signing_and_release_provenance(self):
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp) / "imrse.app"
            executable = bundle / "Contents/MacOS/imrse"
            receipt = bundle / "Contents/Resources" / CI_VALIDATION_RECEIPT_FILE
            executable.parent.mkdir(parents=True)
            receipt.parent.mkdir(parents=True)
            executable.write_bytes(b"\xcf\xfa\xed\xfe fake executable")
            receipt.write_text('{"distributionEligible":false}')
            with self.assertRaisesRegex(PackageError, "cannot be signed"):
                packager.sign_app_bundle(bundle, TEST_CERTIFICATE_SHA1, self.signing_keychain_path, self.codesign_pin)
            self.assertEqual(self.codesign_calls, [])

        with tempfile.TemporaryDirectory() as temp:
            build_root, copy_root, _, product, provenance_path = self.make_build_fixture(Path(temp))
            provenance_path.unlink()
            receipt = product / "Contents/Resources" / CI_VALIDATION_RECEIPT_FILE
            receipt.parent.mkdir(parents=True, exist_ok=True)
            receipt.write_text('{"distributionEligible":false}')
            calls_before_provenance_refusal = len(self.codesign_calls)
            with self.assertRaisesRegex(PackageError, "cannot be signed"):
                record_build_provenance(
                    self.source_root,
                    self.source_commit,
                    self.source_tree,
                    build_root,
                    copy_root,
                    expected_release_build_command(build_root),
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                    self.private_builder_receipt_path(build_root),
                )
            self.assertEqual(len(self.codesign_calls), calls_before_provenance_refusal)
            self.assertFalse(provenance_path.exists())

        with tempfile.TemporaryDirectory() as temp:
            build_root, _, _, product, provenance_path = self.make_build_fixture(Path(temp))
            receipt = product / "Contents/Resources" / CI_VALIDATION_RECEIPT_FILE
            receipt.parent.mkdir(parents=True, exist_ok=True)
            receipt.write_text('{"distributionEligible":false}')
            calls_before_provenance_validation = len(self.codesign_calls)
            with self.assertRaisesRegex(PackageError, "cannot be signed"):
                validate_build_provenance(
                    provenance_path,
                    self.source_root,
                    product,
                    build_root,
                    self.source_commit,
                    self.source_tree,
                    TEST_CERTIFICATE_SHA1,
                    self.signing_keychain_path,
                    self.codesign_pin,
                )
            self.assertEqual(len(self.codesign_calls), calls_before_provenance_validation)


    def test_ci_package_validation_writes_only_a_non_distribution_receipt(self):
        runtime_modules = {module for dependency in RUNTIME_DEPENDENCIES for module in dependency[3]}
        runtime_symbols = {symbol for dependency in C_RUNTIME_DEPENDENCIES for symbol in dependency[3]}
        for host, architecture in (("arm64", "arm64"), ("x86_64", "x86_64")):
            with self.subTest(host=host), tempfile.TemporaryDirectory() as temp:
                app = Path(temp) / "imrse.app"
                main_binary = app / "Contents/MacOS/imrse"
                resources = app / "Contents/Resources"
                (resources / "Brand").mkdir(parents=True)
                main_binary.parent.mkdir(parents=True)
                main_binary.write_bytes(b"\xcf\xfa\xed\xfe fake CI executable")
                (app / "Contents/Info.plist").write_bytes((self.source_root / "Resources/Info.plist").read_bytes())
                (resources / "Brand/imrse-menubar-template.pdf").write_bytes(b"fixture")
                with patch.object(packager, "validate_required_resources") as required_resources, \
                        patch.object(packager, "macho_architectures", return_value={architecture}), \
                        patch.object(packager, "validate_runtime_modules", return_value=runtime_modules) as modules_check, \
                        patch.object(packager, "validate_runtime_symbols", return_value=runtime_symbols) as symbols_check, \
                        patch.object(packager, "pin_codesign_executable", side_effect=AssertionError("CI must not inspect codesign")), \
                        patch.object(packager.platform, "machine", return_value=host):
                    receipt_path = packager.validate_ci_package_app(app, self.source_root, "release")
                receipt = json.loads(receipt_path.read_text())
                self.assertEqual(receipt_path.name, CI_VALIDATION_RECEIPT_FILE)
                self.assertEqual(receipt["validationMode"], "unsigned-ci-package-validation-only")
                self.assertFalse(receipt["distributionEligible"])
                self.assertFalse(receipt["codeSigningPerformed"])
                self.assertFalse(receipt["releaseBuildProvenanceCreated"])
                self.assertIsNone(receipt["signingCertificateSHA1"])
                self.assertIsNone(receipt["signatureReceipt"])
                self.assertEqual(receipt["product"]["hostArchitecture"], architecture)
                self.assertEqual(receipt["product"]["machoArchitectures"], {"Contents/MacOS/imrse": architecture})
                self.assertEqual(receipt["checks"]["requiredResourcesAndLegalNotices"], "passed")
                required_resources.assert_called_once()
                modules_check.assert_called_once_with(main_binary.resolve(), architecture)
                symbols_check.assert_called_once_with(main_binary.resolve(), architecture)
        self.assertEqual(self.codesign_calls, [])

    def test_ci_package_validation_reports_sorted_actual_architectures_on_mismatch(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "imrse.app"
            main_binary = app / "Contents/MacOS/imrse"
            resources = app / "Contents/Resources"
            (resources / "Brand").mkdir(parents=True)
            main_binary.parent.mkdir(parents=True)
            main_binary.write_bytes(b"\xcf\xfa\xed\xfe fake CI executable")
            (app / "Contents/Info.plist").write_bytes((self.source_root / "Resources/Info.plist").read_bytes())
            (resources / "Brand/imrse-menubar-template.pdf").write_bytes(b"fixture")
            with patch.object(packager, "validate_required_resources"), \
                    patch.object(packager, "macho_architectures", return_value={"x86_64", "arm64"}), \
                    patch.object(packager.platform, "machine", return_value="arm64"):
                with self.assertRaisesRegex(
                    PackageError,
                    r"does not match the arm64 CI host; found \['arm64', 'x86_64'\]: Contents/MacOS/imrse",
                ):
                    packager.validate_ci_package_app(app, self.source_root, "release")
            self.assertFalse((resources / CI_VALIDATION_RECEIPT_FILE).exists())

    def test_missing_or_invalid_input_bundle_fails_without_touching_it(self):
        source_info = read_source_info(ROOT)
        with self.assertRaises(PackageError):
            validate_built_app_bundle(ROOT / "does-not-exist.app", source_info)
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "imrse.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            with self.assertRaises(PackageError):
                validate_built_app_bundle(app, source_info)
            self.assertFalse((app / "Contents/Info.plist").exists())

    def test_valid_bundle_metadata_must_match_the_committed_build13_plist(self):
        source_info = read_source_info(ROOT)
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "imrse.app"
            contents = app / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            (contents / "MacOS/imrse").write_bytes(b"test app executable")
            (contents / "Info.plist").write_bytes(plistlib.dumps(source_info))
            bundle, info = validate_built_app_bundle(app, source_info)
            self.assertEqual(bundle.name, "imrse.app")
            self.assertEqual(info["CFBundleVersion"], "13")
            (contents / "Info.plist").write_bytes(plistlib.dumps({**source_info, "CFBundleVersion": "12"}))
            with self.assertRaisesRegex(PackageError, "does not match"):
                validate_built_app_bundle(app, source_info)

    def test_build_script_refuses_existing_outputs_and_incomplete_release_provenance(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "products"
            output.mkdir()
            environment = os.environ.copy()
            environment.pop("IMRSE_CI_PACKAGE_VALIDATION", None)
            environment.update({
                "IMRSE_DIST_DIR": str(output),
                "IMRSE_REQUIRE_EMPTY_APP_OUTPUT": "1",
                "IMRSE_SIGNING_CERTIFICATE_SHA1": TEST_CERTIFICATE_SHA1,
                "IMRSE_SIGNING_KEYCHAIN_PATH": str(Path(temp) / "selected.keychain-db"),
                **self.signing_tool_environment(),
            })
            Path(environment["IMRSE_SIGNING_KEYCHAIN_PATH"]).touch()
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/build-app.sh")],
                cwd=ROOT,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("required fresh app output directory already exists", result.stdout)
            self.assertEqual(list(output.iterdir()), [])
        with tempfile.TemporaryDirectory() as temp:
            build_root = Path(temp) / "release-build"
            build_root.mkdir()
            external_cache = Path(temp) / "external-cache"
            external_cache.mkdir()
            marker = external_cache / "keep.txt"
            marker.write_text("preserve")
            (build_root / "cache").symlink_to(external_cache, target_is_directory=True)
            environment = os.environ.copy()
            environment.pop("IMRSE_CI_PACKAGE_VALIDATION", None)
            environment.pop("SWIFTPM_CACHE_PATH", None)
            environment.update({
                "IMRSE_RELEASE_SOURCE_COMMIT": self.source_commit,
                "IMRSE_RELEASE_SOURCE_TREE": self.source_tree,
                "IMRSE_RELEASE_BUILD_ROOT": str(build_root),
                "IMRSE_SIGNING_CERTIFICATE_SHA1": TEST_CERTIFICATE_SHA1,
                "IMRSE_SIGNING_KEYCHAIN_PATH": str(Path(temp) / "selected.keychain-db"),
                **self.signing_tool_environment(),
            })
            Path(environment["IMRSE_SIGNING_KEYCHAIN_PATH"]).touch()
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/build-app.sh")],
                cwd=ROOT,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Release build output already exists", result.stdout)
            self.assertTrue((build_root / "cache").is_symlink())
            self.assertEqual(marker.read_text(), "preserve")
        with tempfile.TemporaryDirectory() as temp:
            build_root = Path(temp) / "release-build"
            external_cache = Path(temp) / "external-cache"
            environment = os.environ.copy()
            environment.pop("IMRSE_CI_PACKAGE_VALIDATION", None)
            environment.update({
                "IMRSE_RELEASE_SOURCE_COMMIT": self.source_commit,
                "IMRSE_RELEASE_SOURCE_TREE": self.source_tree,
                "IMRSE_RELEASE_BUILD_ROOT": str(build_root),
                "SWIFTPM_CACHE_PATH": str(external_cache),
                "IMRSE_SIGNING_CERTIFICATE_SHA1": TEST_CERTIFICATE_SHA1,
                "IMRSE_SIGNING_KEYCHAIN_PATH": str(Path(temp) / "selected.keychain-db"),
                **self.signing_tool_environment(),
            })
            Path(environment["IMRSE_SIGNING_KEYCHAIN_PATH"]).touch()
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/build-app.sh")],
                cwd=ROOT,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("isolated SwiftPM cache path", result.stdout)
            self.assertFalse(build_root.exists())
        environment = os.environ.copy()
        environment.pop("IMRSE_CI_PACKAGE_VALIDATION", None)
        for key in ("IMRSE_RELEASE_SOURCE_COMMIT", "IMRSE_RELEASE_SOURCE_TREE", "IMRSE_RELEASE_BUILD_ROOT"):
            environment.pop(key, None)
        environment.pop("SWIFTPM_CACHE_PATH", None)
        environment["IMRSE_RELEASE_SOURCE_COMMIT"] = self.source_commit
        environment["IMRSE_SIGNING_CERTIFICATE_SHA1"] = TEST_CERTIFICATE_SHA1
        environment.update(self.signing_tool_environment())
        with tempfile.TemporaryDirectory() as temp:
            keychain_path = Path(temp) / "selected.keychain-db"
            keychain_path.touch()
            environment["IMRSE_SIGNING_KEYCHAIN_PATH"] = str(keychain_path)
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/build-app.sh")],
                cwd=ROOT,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Release mode requires", result.stdout)

    def test_build_script_fails_closed_without_certificate_selector(self):
        script = (ROOT / "scripts/build-app.sh").read_text()
        self.assertIn('SIGNING_CERTIFICATE_SHA1="${IMRSE_SIGNING_CERTIFICATE_SHA1:-}"', script)
        self.assertIn('CI_PACKAGE_VALIDATION="${IMRSE_CI_PACKAGE_VALIDATION:-0}"', script)
        self.assertNotIn("export HOME TMPDIR", script)
        self.assertIn('env "HOME=$BUILD_HOME" "TMPDIR=$BUILD_TMPDIR" "$@"', script)
        self.assertIn('run_isolated_swift_build "${BUILD_COMMAND[@]}"', script)
        self.assertIn('BIN="$(run_isolated_swift_build swift build', script)
        self.assertIn('"$ROOT/scripts/package_local_candidate.py" sign-app', script)
        self.assertIn('"$ROOT/scripts/package_local_candidate.py" validate-ci-app', script)
        self.assertIn('--app "$STAGED_APP"', script)
        self.assertIn('--signing-certificate-sha1 "$SIGNING_CERTIFICATE_SHA1"', script)
        self.assertIn('--signing-keychain-path "$SIGNING_KEYCHAIN_PATH"', script)
        self.assertIn('--signing-execution-receipt "$SIGNING_EXECUTION_RECEIPT"', script)
        self.assertIn('SIGNING_KEYCHAIN_PATH="${IMRSE_SIGNING_KEYCHAIN_PATH:-}"', script)
        self.assertIn('SIGNING_CODESIGN_EXECUTABLE="${IMRSE_SIGNING_CODESIGN_EXECUTABLE:-}"', script)
        self.assertIn('SIGNING_CODESIGN_SHA256="${IMRSE_SIGNING_CODESIGN_SHA256:-}"', script)
        self.assertIn('validate-signing-keychain --path "$SIGNING_KEYCHAIN_PATH"', script)
        self.assertNotIn('SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"', script)
        self.assertNotIn('CODESIGN_ARGS=(--deep', script)
        for invalid in (None, "-", "x" * 40):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / "dist"
                environment = os.environ.copy()
                environment.pop("IMRSE_CI_PACKAGE_VALIDATION", None)
                environment.pop("IMRSE_SIGNING_CERTIFICATE_SHA1", None)
                environment.pop("IMRSE_SIGNING_KEYCHAIN_PATH", None)
                environment["IMRSE_DIST_DIR"] = str(output)
                if invalid is not None:
                    environment["IMRSE_SIGNING_CERTIFICATE_SHA1"] = invalid
                result = subprocess.run(
                    ["bash", str(ROOT / "scripts/build-app.sh")],
                    cwd=ROOT,
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("caller-selected 40-hex certificate SHA-1", result.stdout)
                self.assertFalse(output.exists())

    def test_build_script_scopes_release_home_and_tmp_to_swift_invocations(self):
        script = (ROOT / "scripts/build-app.sh").read_text()
        start = script.index("run_isolated_swift_build() {")
        end = script.index("\n}", start) + 2
        function = script[start:end]
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            probe = base / "capture-environment"
            probe.write_text('#!/bin/sh\nprintf "%s|%s\\n" "$HOME" "$TMPDIR"\n')
            probe.chmod(0o700)
            build_home = base / "build-home"
            build_tmp = base / "build-tmp"
            build_home.mkdir()
            build_tmp.mkdir()
            caller_home = base / "caller-home"
            caller_tmp = base / "caller-tmp"
            environment = os.environ.copy()
            environment.update({
                "BUILD_HOME": str(build_home),
                "BUILD_TMPDIR": str(build_tmp),
                "HOME": str(caller_home),
                "TMPDIR": str(caller_tmp),
                "RELEASE_COMMIT": "release",
                "IMRSE_TEST_PROBE": str(probe),
            })
            invocation = function + '\nrun_isolated_swift_build "$IMRSE_TEST_PROBE"\nprintf "outer=%s|%s\\n" "$HOME" "$TMPDIR"'
            result = subprocess.run(
                ["bash", "-c", invocation],
                env=environment,
                check=True,
                stdout=subprocess.PIPE,
                text=True,
            )
            self.assertEqual(result.stdout.splitlines(), [f"{build_home}|{build_tmp}", f"outer={caller_home}|{caller_tmp}"])
            environment["RELEASE_COMMIT"] = ""
            result = subprocess.run(
                ["bash", "-c", invocation],
                env=environment,
                check=True,
                stdout=subprocess.PIPE,
                text=True,
            )
            self.assertEqual(result.stdout.splitlines(), [f"{caller_home}|{caller_tmp}", f"outer={caller_home}|{caller_tmp}"])

    def test_build_script_fails_closed_without_or_with_invalid_keychain_selector(self):
        for keychain_path, expected in (
            (None, "explicitly selected keychain path"),
            ("relative.keychain-db", "signing keychain path must be absolute"),
            ("/path/that/does/not/exist.keychain-db", "existing regular file"),
        ):
            with self.subTest(keychain_path=keychain_path), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / "dist"
                environment = os.environ.copy()
                environment.pop("IMRSE_CI_PACKAGE_VALIDATION", None)
                environment.update({
                    "IMRSE_SIGNING_CERTIFICATE_SHA1": TEST_CERTIFICATE_SHA1,
                    "IMRSE_DIST_DIR": str(output),
                })
                environment.pop("IMRSE_SIGNING_KEYCHAIN_PATH", None)
                if keychain_path is not None:
                    environment["IMRSE_SIGNING_KEYCHAIN_PATH"] = keychain_path
                result = subprocess.run(
                    ["bash", str(ROOT / "scripts/build-app.sh")],
                    cwd=ROOT,
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stdout)
                self.assertFalse(output.exists())

    def test_build_script_requires_a_valid_explicit_codesign_executable_pin(self):
        for path, digest, expected in (
            (None, self.codesign_executable_sha256, "explicitly pinned codesign executable"),
            (str(self.codesign_executable_path), None, "explicitly pinned codesign executable"),
            ("relative-codesign", self.codesign_executable_sha256, "codesign executable path must be absolute"),
            ("/path/that/does/not/exist/codesign", "f" * 64, "stable, existing executable file"),
            (str(self.codesign_executable_path), "f" * 63, "caller-selected 64-hex codesign executable SHA-256"),
            (str(self.codesign_executable_path), "f" * 64, "does not match the selected SHA-256"),
        ):
            with self.subTest(path=path, digest=digest), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / "dist"
                keychain_path = Path(temp) / "selected.keychain-db"
                keychain_path.touch()
                environment = os.environ.copy()
                environment.pop("IMRSE_CI_PACKAGE_VALIDATION", None)
                environment.update({
                    "IMRSE_DIST_DIR": str(output),
                    "IMRSE_SIGNING_CERTIFICATE_SHA1": TEST_CERTIFICATE_SHA1,
                    "IMRSE_SIGNING_KEYCHAIN_PATH": str(keychain_path),
                })
                environment.pop("IMRSE_SIGNING_CODESIGN_EXECUTABLE", None)
                environment.pop("IMRSE_SIGNING_CODESIGN_SHA256", None)
                if path is not None:
                    environment["IMRSE_SIGNING_CODESIGN_EXECUTABLE"] = path
                if digest is not None:
                    environment["IMRSE_SIGNING_CODESIGN_SHA256"] = digest
                result = subprocess.run(
                    ["bash", str(ROOT / "scripts/build-app.sh")],
                    cwd=ROOT,
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stdout)
                self.assertFalse(output.exists())

    def test_ci_build_validation_rejects_signers_release_inputs_and_unsafe_mode(self):
        cases = (
            ("signer", {"IMRSE_SIGNING_CERTIFICATE_SHA1": "not-a-selected-cert"}, "cannot use a signing selector"),
            ("keychain", {"IMRSE_SIGNING_KEYCHAIN_PATH": "/selected/keychain"}, "cannot use a signing selector"),
            ("codesign-path", {"IMRSE_SIGNING_CODESIGN_EXECUTABLE": "/selected/codesign"}, "cannot use a signing selector"),
            ("codesign-sha256", {"IMRSE_SIGNING_CODESIGN_SHA256": "f" * 64}, "cannot use a signing selector"),
            ("release", {"IMRSE_RELEASE_SOURCE_COMMIT": "0" * 40}, "cannot use a signing selector or Release provenance inputs"),
            ("configuration", {"CONFIGURATION": "debug"}, "requires CONFIGURATION=release"),
            ("output", {"IMRSE_DIST_DIR": None}, "requires a new absolute IMRSE_DIST_DIR"),
            ("mode", {"IMRSE_CI_PACKAGE_VALIDATION": "true"}, "must be 0 or 1"),
        )
        for label, updates, expected in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / "ci-products"
                environment = os.environ.copy()
                environment.update({
                    "IMRSE_CI_PACKAGE_VALIDATION": "1",
                    "IMRSE_DIST_DIR": str(output),
                })
                environment.pop("IMRSE_SIGNING_CERTIFICATE_SHA1", None)
                environment.pop("IMRSE_SIGNING_KEYCHAIN_PATH", None)
                environment.pop("IMRSE_SIGNING_CODESIGN_EXECUTABLE", None)
                environment.pop("IMRSE_SIGNING_CODESIGN_SHA256", None)
                for key in ("IMRSE_RELEASE_SOURCE_COMMIT", "IMRSE_RELEASE_SOURCE_TREE", "IMRSE_RELEASE_BUILD_ROOT"):
                    environment.pop(key, None)
                for key, value in updates.items():
                    if value is None:
                        environment.pop(key, None)
                    else:
                        environment[key] = value
                result = subprocess.run(
                    ["bash", str(ROOT / "scripts/build-app.sh")],
                    cwd=ROOT,
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stdout)
                self.assertFalse(output.exists())

    def test_ci_build_passes_the_validated_host_architecture_to_swift(self):
        self.assertIn("platforms: [.macOS(.v14)]", (ROOT / "Package.swift").read_text())
        for host_architecture, expected_architecture in (
            ("arm64", "arm64"),
            ("x86_64", "x86_64"),
        ):
            with self.subTest(host_architecture=host_architecture), tempfile.TemporaryDirectory() as temp:
                result, argv, output = self.invoke_ci_build_with_stubbed_swift(Path(temp), host_architecture)
                self.assertEqual(result.returncode, 97, result.stdout)
                self.assertIsNotNone(argv)
                self.assertEqual(argv[0], b"build")
                self.assertEqual(argv[argv.index(b"-configuration") + 1], b"Release")
                architecture_options = [index for index, argument in enumerate(argv) if argument == b"-destination"]
                self.assertEqual(len(architecture_options), 1)
                self.assertEqual(argv[architecture_options[0] + 1].decode(), f"platform=macOS,arch={expected_architecture}")
                self.assertNotIn(b"--triple", argv)
                self.assertIn(b"-onlyUsePackageVersionsFromResolvedFile", argv)
                self.assertIn(b"-disableAutomaticPackageResolution", argv)
                self.assertIn(b"-skipPackageUpdates", argv)
                self.assertEqual(argv[argv.index(b"-resultBundlePath") + 1].decode(), str(output.resolve() / "CI-BUILD.xcresult"))
                self.assertEqual(argv[argv.index(b"-jobs") + 1], b"1")
                self.assertIn(b"OTHER_SWIFT_FLAGS=$(inherited) -warnings-as-errors -j1", argv)
                self.assertIn(b"SWIFT_COMPILATION_MODE=wholemodule", argv)
                self.assertIn(b"SWIFT_WHOLE_MODULE_OPTIMIZATION=YES", argv)
                self.assertIn(b"SWIFT_SUPPRESS_WARNINGS=NO", argv)
                self.assertIn(b"SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", argv)
                self.assertIn(b"SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO", argv)
                self.assertNotIn(b"-skipPackagePluginValidation", argv)
                self.assertNotIn(b"-skipMacroValidation", argv)
                self.assertEqual(argv[argv.index(b"-scheme") + 1], b"imrse")
                self.assertTrue(output.is_dir())

    def test_ci_build_rejects_unsupported_host_before_invoking_swift(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            result, argv, output = self.invoke_ci_build_with_stubbed_swift(base, "sparc")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("CI package validation does not support host architecture sparc", result.stdout)
            self.assertIsNone(argv)
            self.assertFalse(output.exists())

    def test_package_workflow_selects_unsigned_ci_validation_and_never_publishes_it(self):
        workflow = (ROOT / ".github/workflows/verify.yml").read_text()
        package_job = workflow.partition("  package:\n")[2].partition("\n  design:\n")[0]
        self.assertIn('IMRSE_CI_PACKAGE_VALIDATION: "1"', package_job)
        self.assertIn("IMRSE_EXPECTED_SOURCE_COMMIT: ${{ github.event.pull_request.head.sha || github.sha }}", package_job)
        self.assertIn("ref: ${{ github.event.pull_request.head.sha || github.sha }}", package_job)
        self.assertIn('PYTHONDONTWRITEBYTECODE: "1"', package_job)
        self.assertIn('IMRSE_CI_CANDIDATE_DIR="$RUNNER_TEMP/imrse-ci-candidate"', package_job)
        self.assertIn('IMRSE_DIST_DIR="$RUNNER_TEMP/imrse-ci-package-validation"', package_job)
        self.assertNotIn("IMRSE_SIGNING_CERTIFICATE_SHA1", package_job)
        self.assertNotIn("IMRSE_SIGNING_KEYCHAIN_PATH", package_job)
        self.assertNotIn("IMRSE_SIGNING_CODESIGN_EXECUTABLE", package_job)
        self.assertNotIn("IMRSE_SIGNING_CODESIGN_SHA256", package_job)
        self.assertIn("bash -n scripts/build-app.sh", package_job)
        self.assertIn("plutil -lint Resources/Info.plist", package_job)
        self.assertIn("python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v", package_job)
        vendor_test = "swift test --package-path Vendor/EventSource --jobs 1 -Xswiftc -warnings-as-errors"
        self.assertIn(vendor_test, package_job)
        self.assertIn("swift package resolve --only-use-versions-from-resolved-file", package_job)
        self.assertIn("swift package show-dependencies --only-use-versions-from-resolved-file --format json", package_job)
        self.assertIn("checkout revision differs from Package.resolved", package_job)
        self.assertIn("EventSource must resolve to Vendor/EventSource", package_job)
        self.assertIn("root graph activates optional EventSource AsyncHTTPClient/NIO dependencies", package_job)
        self.assertIn("all three ConcreteTransportTests", package_job)
        self.assertIn("./scripts/build-app.sh", package_job)
        self.assertIn("grep -E 'swiftc|swift-frontend'", package_job)
        self.assertIn("-whole-module-optimization", package_job)
        self.assertIn("scripts/export-ci-candidate.py", package_job)
        self.assertIn("actions/upload-artifact@v4", package_job)
        self.assertIn("name: imrse-ci-arm64-unsigned-${{ github.run_id }}-${{ github.run_attempt }}", package_job)
        self.assertIn("path: ${{ runner.temp }}/imrse-ci-candidate", package_job)
        self.assertIn("if-no-files-found: error", package_job)
        self.assertNotIn("actions/create-release", package_job)
        self.assertNotIn("gh release", package_job)
        self.assertNotIn("continue-on-error", package_job)

    def test_ci_python_bytecode_suppression_keeps_fresh_source_clone_clean(self):
        self.assertEqual(
            subprocess.run(
                ["git", "status", "--porcelain=v1", "--untracked-files=all"],
                cwd=self.source_root,
                check=True,
                stdout=subprocess.PIPE,
                text=True,
            ).stdout,
            "",
        )
        environment = os.environ.copy()
        environment.pop("PYTHONPYCACHEPREFIX", None)
        environment.pop("PYTHONPATH", None)
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        result = subprocess.run(
            [
                sys.executable,
                "-c",
                "import sys; sys.pycache_prefix = None; import scripts.package_local_candidate; print(sys.pycache_prefix, sys.dont_write_bytecode)",
            ],
            cwd=self.source_root,
            env=environment,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout.strip(), "None True")
        self.assertFalse((self.source_root / "scripts/__pycache__").exists())
        status = subprocess.run(
            ["git", "status", "--porcelain=v1", "--untracked-files=all"],
            cwd=self.source_root,
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout
        self.assertEqual(status, "")

    def test_package_cli_propagates_the_same_certificate_selector(self):
        argv = [
            "package",
            "--app", "/tmp/build/products/imrse.app",
            "--source-commit", self.source_commit,
            "--source-tree", self.source_tree,
            "--build-root", "/tmp/build",
            "--output", "/tmp/candidate",
            "--signing-certificate-sha1", TEST_CERTIFICATE_SHA1,
            "--signing-keychain-path", str(self.signing_keychain_path),
            "--codesign-executable", str(self.codesign_executable_path),
            "--codesign-sha256", self.codesign_executable_sha256,
        ]
        with patch.object(packager, "create_candidate") as create:
            self.assertEqual(packager.main(argv), 0)
        self.assertEqual(create.call_args.args, (
            Path("/tmp/build/products/imrse.app"),
            self.source_commit,
            self.source_tree,
            Path("/tmp/build"),
            Path("/tmp/candidate"),
            TEST_CERTIFICATE_SHA1,
            self.signing_keychain_path,
            self.codesign_pin,
        ))

    def test_package_cli_reaches_signing_with_the_selected_keychain(self):
        class StopAfterSigning(Exception):
            pass

        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp).resolve(strict=True)
            build_root = base / "isolated-build"
            product = build_root / "products/imrse.app"
            executable = product / "Contents/MacOS/imrse"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"\xcf\xfa\xed\xfe fake package executable")
            (product / "Contents/Info.plist").write_bytes(b"fixture plist")
            source_manifest = packager.source_input_manifest(self.source_root, self.source_commit, self.source_tree)
            (build_root / SOURCE_INPUT_MANIFEST_FILE).write_text(json.dumps(source_manifest))
            (build_root / BUILD_PROVENANCE_FILE).write_text("stub provenance")
            output = base / "candidate-output"
            app_info = {"CFBundleIdentifier": EXPECTED_BUNDLE_ID}

            def stub_run(command, **kwargs):
                if command[0] == str(self.codesign_executable_path):
                    return self.stub_packager_run(command, **kwargs)
                return ""

            with ExitStack() as patches:
                patches.enter_context(patch.object(packager, "__file__", str(self.source_root / "scripts/package_local_candidate.py")))
                patches.enter_context(patch.object(packager.platform, "system", return_value="Darwin"))
                patches.enter_context(patch.object(packager.platform, "machine", return_value="arm64"))
                patches.enter_context(patch.object(packager, "validate_source_checkout", return_value=ROOT))
                patches.enter_context(patch.object(packager, "canonical_build_root", return_value=build_root))
                patches.enter_context(patch.object(packager, "validate_source_copy"))
                patches.enter_context(patch.object(packager, "read_source_info", return_value=app_info))
                patches.enter_context(patch.object(packager, "validate_app_version_metadata"))
                patches.enter_context(patch.object(packager, "validate_built_app_bundle", return_value=(product, app_info)))
                patches.enter_context(patch.object(packager, "validate_build_provenance", return_value={}))
                patches.enter_context(patch.object(packager, "check_quarantine_metadata"))
                patches.enter_context(patch.object(packager, "read_pins", return_value={}))
                patches.enter_context(patch.object(packager, "validate_required_resources"))
                patches.enter_context(patch.object(packager, "thin_bundle_to_arm64", side_effect=packager.macho_files))
                patches.enter_context(patch.object(packager, "validate_runtime_modules", return_value=set()))
                patches.enter_context(patch.object(packager, "validate_runtime_symbols", return_value=set()))
                patches.enter_context(patch.object(packager, "run", side_effect=stub_run))
                signer = patches.enter_context(patch.object(packager, "sign_and_verify", wraps=packager.sign_and_verify))
                zip_writer = patches.enter_context(patch.object(packager, "create_zip", side_effect=StopAfterSigning))
                with self.assertRaises(StopAfterSigning):
                    packager.main([
                        "package",
                        "--app", str(product),
                        "--source-commit", self.source_commit,
                        "--source-tree", self.source_tree,
                        "--build-root", str(build_root),
                        "--output", str(output),
                        "--signing-certificate-sha1", TEST_CERTIFICATE_SHA1,
                        "--signing-keychain-path", str(self.signing_keychain_path),
                        "--codesign-executable", str(self.codesign_executable_path),
                        "--codesign-sha256", self.codesign_executable_sha256,
                    ])

            self.assertEqual(signer.call_args.args[2:], (
                TEST_CERTIFICATE_SHA1,
                self.signing_keychain_path.resolve(),
                self.codesign_pin,
            ))
            self.assertEqual(len(self.codesign_identity_keychains), 2)
            self.assertEqual(self.codesign_identity_keychains, [str(self.signing_keychain_path.resolve())] * 2)
            self.assertEqual(self.codesign_signers, [TEST_CERTIFICATE_SHA1] * 2)
            self.assertEqual(sum("--sign" in command for command in self.codesign_calls), 2)
            zip_writer.assert_called_once()

    def test_signed_cli_actions_require_an_explicit_keychain_argument(self):
        cases = (
            [
                "sign-app", "--app", "/tmp/imrse.app",
                "--signing-certificate-sha1", TEST_CERTIFICATE_SHA1,
                "--codesign-executable", str(self.codesign_executable_path),
                "--codesign-sha256", self.codesign_executable_sha256,
                "--signing-execution-receipt", "/tmp/private/signing-receipt.json",
            ],
            [
                "record-build",
                "--source-commit", self.source_commit,
                "--source-tree", self.source_tree,
                "--build-root", "/tmp/build",
                "--working-directory", "/tmp/build/source",
                "--signing-certificate-sha1", TEST_CERTIFICATE_SHA1,
                "--codesign-executable", str(self.codesign_executable_path),
                "--codesign-sha256", self.codesign_executable_sha256,
                "--signing-execution-receipt", "/tmp/private/signing-receipt.json",
                "--build-command-arg=swift",
            ],
            [
                "package",
                "--app", "/tmp/build/products/imrse.app",
                "--source-commit", self.source_commit,
                "--source-tree", self.source_tree,
                "--build-root", "/tmp/build",
                "--output", "/tmp/candidate",
                "--signing-certificate-sha1", TEST_CERTIFICATE_SHA1,
                "--codesign-executable", str(self.codesign_executable_path),
                "--codesign-sha256", self.codesign_executable_sha256,
            ],
        )
        for argv in cases:
            with self.subTest(action=argv[0]), redirect_stderr(StringIO()), self.assertRaises(SystemExit):
                packager.main(argv)

    def test_package_cli_rejects_invalid_keychain_before_native_or_signing_calls(self):
        with patch.object(packager.platform, "system") as system_check, \
                patch.object(packager, "run") as command_runner, \
                redirect_stderr(StringIO()):
            result = packager.main([
                "package",
                "--app", "/tmp/build/products/imrse.app",
                "--source-commit", self.source_commit,
                "--source-tree", self.source_tree,
                "--build-root", "/tmp/build",
                "--output", "/tmp/candidate",
                "--signing-certificate-sha1", TEST_CERTIFICATE_SHA1,
                "--signing-keychain-path", "/path/that/does/not/exist.keychain-db",
                "--codesign-executable", str(self.codesign_executable_path),
                "--codesign-sha256", self.codesign_executable_sha256,
            ])
        self.assertEqual(result, 1)
        system_check.assert_not_called()
        command_runner.assert_not_called()
        self.assertEqual(self.codesign_calls, [])

    def test_sign_app_cli_routes_build_output_to_the_explicit_signer(self):
        output = StringIO()
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp) / "imrse.app"
            main = bundle / "Contents/MacOS/imrse"
            main.parent.mkdir(parents=True)
            main.write_bytes(b"\xcf\xfa\xed\xfe fake CLI executable")
            receipt_path = Path(temp) / "private-stage/signing-execution-receipt.json"
            receipt_path.parent.mkdir(mode=0o700)
            with redirect_stdout(output):
                self.assertEqual(packager.main([
                    "sign-app",
                    "--app", str(bundle),
                    "--signing-certificate-sha1", TEST_CERTIFICATE_SHA1,
                    "--signing-keychain-path", str(self.signing_keychain_path),
                    "--codesign-executable", str(self.codesign_executable_path),
                    "--codesign-sha256", self.codesign_executable_sha256,
                    "--signing-execution-receipt", str(receipt_path),
                ]), 0)
            self.assertTrue(receipt_path.is_file())
            self.assertEqual(receipt_path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(packager.read_private_signing_receipt(receipt_path, bundle)["producer"], "builder")
            self.assertNotIn(str(receipt_path), output.getvalue())
        self.assertIn("Signed and verified certificate-selected app", output.getvalue())

    def test_signing_keychain_cli_validator_normalizes_and_rejects_invalid_paths(self):
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(packager.main(["validate-signing-keychain", "--path", str(self.signing_keychain_path)]), 0)
        self.assertEqual(output.getvalue().strip(), str(self.signing_keychain_path.resolve()))
        with redirect_stderr(StringIO()):
            self.assertEqual(packager.main(["validate-signing-keychain", "--path", str(self.signing_keychain_path.parent)]), 1)

    def test_codesign_cli_validator_checks_explicit_file_and_digest_without_running_it(self):
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(packager.main([
                "validate-codesign-executable",
                "--path", str(self.codesign_executable_path),
                "--sha256", self.codesign_executable_sha256,
            ]), 0)
        self.assertEqual(output.getvalue().strip(), str(self.codesign_executable_path.resolve()))
        self.assertEqual(self.codesign_calls, [])
        with redirect_stderr(StringIO()):
            self.assertEqual(packager.main([
                "validate-codesign-executable",
                "--path", str(self.codesign_executable_path),
                "--sha256", "f" * 64,
            ]), 1)

    def test_validate_ci_cli_routes_only_to_validation_receipt_creation(self):
        output = StringIO()
        receipt = Path("/tmp/imrse-ci/CI-PACKAGE-VALIDATION.json")
        with patch.object(packager, "validate_ci_package_app", return_value=receipt) as validator:
            with redirect_stdout(output):
                self.assertEqual(packager.main([
                    "validate-ci-app",
                    "--app", "/tmp/imrse-ci/imrse.app",
                    "--source-root", str(self.source_root),
                    "--configuration", "release",
                ]), 0)
        self.assertEqual(validator.call_args.args, (Path("/tmp/imrse-ci/imrse.app"), self.source_root, "release"))
        self.assertIn("CI validation-only receipt", output.getvalue())

    def test_manifest_records_runtime_dependency_and_license_hashes_without_old_delta_claims(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "products/imrse.app"
            (source / "Contents/MacOS").mkdir(parents=True)
            (source / "Contents/MacOS/imrse").write_bytes(b"\xcf\xfa\xed\xfe source")
            source_info = read_source_info(ROOT)
            (source / "Contents/Info.plist").write_bytes(plistlib.dumps(source_info))
            bundle = Path(temp) / "candidate.app"
            (bundle / "Contents/MacOS").mkdir(parents=True)
            (bundle / "Contents/MacOS/imrse").write_bytes(b"\xcf\xfa\xed\xfe candidate")
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(source_info))
            resources = bundle / "Contents/Resources/ThirdPartyLicenses"
            resources.mkdir(parents=True)
            for dependency in (*RUNTIME_DEPENDENCIES, *C_RUNTIME_DEPENDENCIES):
                (resources / dependency[4]).write_text(dependency[4])
            (resources / "mlx-core-LICENSE").write_text("mlx-core-LICENSE")
            yyjson_hash = hashlib.sha256(b"yyjson-LICENSE").hexdigest()
            build_signing = sign_and_verify(
                source,
                [source / "Contents/MacOS/imrse"],
                TEST_CERTIFICATE_SHA1,
                self.signing_keychain_path,
                self.codesign_pin,
                producer="builder",
            )
            candidate_signing = sign_and_verify(
                bundle,
                [bundle / "Contents/MacOS/imrse"],
                TEST_CERTIFICATE_SHA1,
                self.signing_keychain_path,
                self.codesign_pin,
            )
            build_receipt = build_signing["signatureReceipt"]
            candidate_receipt = {
                **candidate_signing["signatureReceipt"],
                "bundle": {
                    **candidate_signing["signatureReceipt"]["bundle"],
                    "defaultDesignatedRequirement": 'identifier "org.imrse.app" and anchor apple generic and candidate',
                },
            }
            build_record = {
                "build": {
                    "configuration": "release",
                    "workingDirectoryRelativePath": "source",
                    "command": normalized_release_build_command(),
                    "commandPathValuesRelativeToBuildRoot": True,
                    "signingCertificateSHA1": TEST_CERTIFICATE_SHA1,
                    "identityKeychainPathSHA256": identity_keychain_path_sha256(self.signing_keychain_path.resolve()),
                    "codesignExecutableSHA256": self.codesign_executable_sha256,
                    "provenanceScope": BUILD_PROVENANCE_SCOPE,
                },
                "product": {
                    "signatureReceipt": build_receipt,
                    "signingExecutionReceipt": build_signing["signingExecutionReceipt"],
                },
            }
            manifest_args = (
                ROOT,
                source,
                bundle_tree_sha256(source),
                bundle,
                "archive-hash",
                1,
                set(),
                {"_yyjson_read_opts"},
                "OK",
                build_record,
                "provenance-hash",
                self.source_commit,
                self.source_tree,
                "input-manifest-hash",
                candidate_receipt,
                candidate_signing["signingExecutionReceipt"],
                self.signing_keychain_path,
                self.codesign_pin,
            )
            manifest = candidate_manifest(*manifest_args)
            wrong_candidate_receipt = {**candidate_receipt, "certificateSHA1": "f" * 40}
            with self.assertRaisesRegex(PackageError, "signature receipts do not match"):
                candidate_manifest(*manifest_args[:14], wrong_candidate_receipt, *manifest_args[15:])
            wrong_codesign_receipt = {**candidate_receipt, "codesignExecutableSHA256": "f" * 64}
            with self.assertRaisesRegex(PackageError, "signature receipts do not match"):
                candidate_manifest(*manifest_args[:14], wrong_codesign_receipt, *manifest_args[15:])
            empty_candidate_receipt = {**candidate_receipt, "codeItems": []}
            with self.assertRaisesRegex(PackageError, "signature receipts do not match"):
                candidate_manifest(*manifest_args[:14], empty_candidate_receipt, *manifest_args[15:])
            wrong_build_record = {
                **build_record,
                "build": {**build_record["build"], "signingCertificateSHA1": "f" * 40},
            }
            wrong_build_args = list(manifest_args)
            wrong_build_args[9] = wrong_build_record
            with self.assertRaisesRegex(PackageError, "signature receipts do not match"):
                candidate_manifest(*wrong_build_args)
        yyjson = next(item for item in manifest["runtimeDependencies"] if item["package"] == "yyjson")
        self.assertEqual(yyjson["version"], "0.12.0")
        self.assertEqual(yyjson["revision"], "8b4a38dc994a110abaec8a400615567bd996105f")
        self.assertEqual(yyjson["binarySymbols"], ["_yyjson_read_opts"])
        self.assertEqual(yyjson["licenseSHA256"], yyjson_hash)
        self.assertEqual(manifest["source"]["commitSHA"], self.source_commit)
        self.assertEqual(manifest["source"]["buildProvenance"]["fileName"], BUILD_PROVENANCE_FILE)
        self.assertEqual(manifest["schemaVersion"], 6)
        self.assertEqual(manifest["source"]["buildProduct"]["signatureReceipt"], build_receipt)
        self.assertEqual(manifest["source"]["buildProduct"]["signingExecutionReceipt"]["producer"], "builder")
        self.assertEqual(manifest["signing"]["certificateSHA1"], TEST_CERTIFICATE_SHA1)
        self.assertEqual(
            manifest["signing"]["identityKeychainPathSHA256"],
            identity_keychain_path_sha256(self.signing_keychain_path.resolve()),
        )
        self.assertEqual(manifest["signing"]["codesignExecutableSHA256"], self.codesign_executable_sha256)
        self.assertNotIn(str(self.signing_keychain_path), json.dumps(manifest))
        self.assertNotIn(str(self.signing_keychain_path.parent), json.dumps(manifest))
        self.assertNotIn(str(self.codesign_executable_path), json.dumps(manifest))
        self.assertEqual(manifest["signing"]["signatureType"], CERTIFICATE_SIGNING_LABEL)
        self.assertFalse(manifest["signing"]["developerID"])
        self.assertFalse(manifest["signing"]["notarized"])
        self.assertEqual(manifest["signing"]["candidateReceipt"], candidate_receipt)
        self.assertEqual(manifest["signing"]["buildSigningExecutionReceipt"]["producer"], "builder")
        self.assertEqual(manifest["signing"]["candidateSigningExecutionReceipt"]["producer"], "candidate")
        self.assertEqual(manifest["signing"]["buildSigningExecutionReceipt"]["representation"], "PUBLIC-REDACTED-OBSERVED-ORDERED-ARGV")
        self.assertEqual(manifest["signing"]["candidateSigningExecutionReceipt"]["representation"], "PUBLIC-REDACTED-OBSERVED-ORDERED-ARGV")
        self.assertIn("no TCC reuse claim", " ".join(manifest["limitations"]))
        install_guide = (ROOT / "docs/manual-candidate-install.md").read_text()
        self.assertIn("caller-selected 40-hex certificate SHA-1", install_guide)
        self.assertIn("IMRSE_SIGNING_CERTIFICATE_SHA1", install_guide)
        self.assertIn("IMRSE_SIGNING_KEYCHAIN_PATH", install_guide)
        self.assertIn("IMRSE_SIGNING_CODESIGN_EXECUTABLE", install_guide)
        self.assertIn("IMRSE_SIGNING_CODESIGN_SHA256", install_guide)
        self.assertIn("schema-6 provenance", install_guide)
        self.assertIn("--signing-certificate-sha1", install_guide)
        self.assertIn("--signing-keychain-path", install_guide)
        self.assertIn("--codesign-executable", install_guide)
        self.assertIn("--codesign-sha256", install_guide)
        self.assertIn("not proof that its private key is available", install_guide)
        self.assertIn("SHA-256 of the canonical absolute keychain path string", install_guide)
        self.assertIn("the digest covers the path string, not the Keychain database contents", install_guide)
        self.assertIn("neither opens, reads, nor hashes the database", install_guide)
        self.assertIn("--keychain` restricts signing-identity lookup", install_guide)
        self.assertIn("chain construction still consults the standard keychain search list", install_guide)
        self.assertIn("no TCC reuse promise", install_guide)
        self.assertNotIn("ad-hoc signed", install_guide)
        self.assertEqual(manifest["source"]["buildProduct"]["configuration"], "release")
        self.assertEqual(manifest["source"]["buildProduct"]["workingDirectoryRelativePath"], "source")
        self.assertNotIn("candidateDeltaPatch", manifest["source"])
        self.assertNotIn("preservedStateSnapshot", manifest["source"])
        self.assertNotIn("baseCommitSHA", manifest["source"])
        self.assertNotIn("sourceRegressionGate", manifest["verification"])

    def test_builder_to_candidate_packaging_keeps_private_vectors_out_of_every_artifact(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            build_root, _, source_manifest_path, product, provenance_path = self.make_build_fixture(base)
            output = base / "candidate-output"
            secret_home = base / "observed-home"
            secret_tmp = base / "observed-tmp"
            private_receipt_path = self.private_builder_receipt_path(build_root)
            private_stage = private_receipt_path.parent
            candidate_receipt_paths = []
            original_read_receipt = packager.read_private_signing_receipt

            def capture_private_receipt(path, bundle):
                receipt = original_read_receipt(path, bundle)
                if receipt.get("producer") == "candidate":
                    candidate_receipt_paths.append(Path(path))
                    self.assertEqual(Path(path).stat().st_mode & 0o777, 0o600)
                    self.assertEqual(Path(path).parent.stat().st_mode & 0o777, 0o700)
                    self.assertNotEqual(Path(path).parent, Path(bundle))
                return receipt

            def stub_run(command, **kwargs):
                command = [str(argument) for argument in command]
                if command[0] == str(self.codesign_executable_path):
                    return self.stub_packager_run(command, **kwargs)
                if command[0] == "plutil":
                    return ""
                if command[0] == sys.executable and command[1:3] == ["-m", "unittest"]:
                    return "Ran 1 test\n\nOK\n"
                return self.real_packager_run(command, **kwargs)

            def reject_candidate(output_name):
                rejected_output = base / output_name
                with ExitStack() as patches:
                    patches.enter_context(patch.object(packager, "__file__", str(self.source_root / "scripts/package_local_candidate.py")))
                    patches.enter_context(patch.object(packager.platform, "system", return_value="Darwin"))
                    patches.enter_context(patch.object(packager.platform, "machine", return_value="arm64"))
                    patches.enter_context(patch.object(packager, "check_quarantine_metadata"))
                    patches.enter_context(patch.object(packager, "run", side_effect=stub_run))
                    with self.assertRaises(PackageError) as caught:
                        packager.create_candidate(
                            product,
                            self.source_commit,
                            self.source_tree,
                            build_root,
                            rejected_output,
                            TEST_CERTIFICATE_SHA1,
                            self.signing_keychain_path,
                            self.codesign_pin,
                        )
                self.assertFalse(rejected_output.exists())
                return caught.exception

            with ExitStack() as patches:
                patches.enter_context(patch.object(packager, "__file__", str(self.source_root / "scripts/package_local_candidate.py")))
                patches.enter_context(patch.object(packager.platform, "system", return_value="Darwin"))
                patches.enter_context(patch.object(packager.platform, "machine", return_value="arm64"))
                patches.enter_context(patch.object(packager.platform, "mac_ver", return_value=("15.0", ("", "", ""), "")))
                patches.enter_context(patch.object(packager, "check_quarantine_metadata"))
                patches.enter_context(patch.object(packager, "validate_required_resources"))
                patches.enter_context(patch.object(packager, "thin_bundle_to_arm64", side_effect=packager.macho_files))
                patches.enter_context(patch.object(packager, "validate_runtime_modules", return_value={"MLX"}))
                patches.enter_context(patch.object(packager, "validate_runtime_symbols", return_value={"_yyjson_read_opts"}))
                patches.enter_context(patch.object(packager, "read_private_signing_receipt", side_effect=capture_private_receipt))
                patches.enter_context(patch.object(packager, "run", side_effect=stub_run))
                with patch.dict(os.environ, {"HOME": str(secret_home), "TMPDIR": str(secret_tmp)}):
                    packager.create_candidate(
                        product,
                        self.source_commit,
                        self.source_tree,
                        build_root,
                        output,
                        TEST_CERTIFICATE_SHA1,
                        self.signing_keychain_path,
                        self.codesign_pin,
                    )
            self.assertEqual(len(candidate_receipt_paths), 1)
            self.assertFalse(candidate_receipt_paths[0].exists())
            self.assertTrue(private_receipt_path.is_file())
            expected_names = {
                packager.OUTPUT_NAME,
                BUILD_PROVENANCE_FILE,
                SOURCE_INPUT_MANIFEST_FILE,
                "MANIFEST.json",
                "SHA256SUMS",
            }
            self.assertEqual({path.name for path in output.iterdir()}, expected_names)
            artifact_text = "\n".join(
                path.read_text() for path in output.iterdir() if path.suffix == ".json"
            )
            for private_value in (
                str(base),
                str(secret_home),
                str(secret_tmp),
                str(self.signing_keychain_path),
                str(self.codesign_executable_path),
                str(private_receipt_path),
                str(candidate_receipt_paths[0]),
            ):
                self.assertNotIn(private_value, artifact_text)
            with zipfile.ZipFile(output / packager.OUTPUT_NAME) as archive:
                self.assertFalse(any("signing-receipt" in name or "private-candidate" in name for name in archive.namelist()))
            record = json.loads((output / BUILD_PROVENANCE_FILE).read_text())
            manifest = json.loads((output / "MANIFEST.json").read_text())
            self.assertEqual(record["product"]["signingExecutionReceipt"]["producer"], "builder")
            self.assertEqual(manifest["signing"]["candidateSigningExecutionReceipt"]["producer"], "candidate")
            self.assertEqual(manifest["signing"]["candidateSigningExecutionReceipt"]["representation"], "PUBLIC-REDACTED-OBSERVED-ORDERED-ARGV")
            self.assertEqual(manifest["signing"]["candidateSigningExecutionReceipt"]["codesignExecutableFilesystemIdentity"]["inode"], self.codesign_pin.filesystem_identity[1])

            builder_execution = record["product"]["signingExecutionReceipt"]
            builder_execution["calls"][0]["unredactedDebugPath"] = str(private_stage)
            builder_execution["redactedVectorSHA256"] = packager.canonical_json_sha256(builder_execution["calls"])
            provenance_path.write_text(json.dumps(record))
            caught = reject_candidate("rejected-candidate")
            self.assertNotIn(str(private_stage), str(caught))

            valid_provenance = (output / BUILD_PROVENANCE_FILE).read_text()
            valid_provenance_record = json.loads(valid_provenance)
            repository_json = json.dumps(valid_provenance_record["repository"])
            provenance_repository_field = f'"repository": {repository_json},'
            private_path_sentinel = str(base / "PRIVATE_SENTINEL/Keychains/login.keychain-db")
            duplicate_provenance = valid_provenance.replace(
                provenance_repository_field,
                f'"repository": {json.dumps(private_path_sentinel)},\n  {provenance_repository_field}',
                1,
            )
            self.assertNotEqual(duplicate_provenance, valid_provenance)
            provenance_path.write_text(duplicate_provenance)
            caught = reject_candidate("rejected-duplicate-build-provenance")
            self.assertNotIn(private_path_sentinel, str(caught))
            self.assertEqual(str(caught), "cannot read clean-source build provenance")

            valid_source_manifest = (output / SOURCE_INPUT_MANIFEST_FILE).read_text()
            valid_source_manifest_record = json.loads(valid_source_manifest)
            manifest_repository_json = json.dumps(valid_source_manifest_record["repository"])
            manifest_repository_field = f'"repository": {manifest_repository_json},'
            duplicate_source_manifest = valid_source_manifest.replace(
                manifest_repository_field,
                f'"repository": {json.dumps(private_path_sentinel)},\n  {manifest_repository_field}',
                1,
            )
            self.assertNotEqual(duplicate_source_manifest, valid_source_manifest)
            source_manifest_path.write_text(duplicate_source_manifest)
            valid_provenance_record["sourceInputManifest"]["sha256"] = sha256_file(source_manifest_path)
            provenance_path.write_text(json.dumps(valid_provenance_record))
            caught = reject_candidate("rejected-duplicate-source-input-manifest")
            self.assertNotIn(private_path_sentinel, str(caught))
            self.assertEqual(str(caught), "cannot read source input manifest")

    def test_required_license_notice_and_shader_resources_are_checked(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "imrse.app"
            resources = app / "Contents/Resources"
            for path in (resources / "ThirdPartyLicenses", resources / "imrse_ImrseLocal.bundle/Contents/Resources"):
                path.mkdir(parents=True)
            (resources / "IMRSE-LICENSE.txt").write_bytes((ROOT / "LICENSE").read_bytes())
            (resources / "THIRD_PARTY_NOTICES.md").write_bytes((ROOT / "Resources/THIRD_PARTY_NOTICES.md").read_bytes())
            (resources / "PillKit-Source-Dependency-Notice.md").write_bytes((ROOT / "pill-kit/THIRD_PARTY_NOTICES.md").read_bytes())
            (resources / "AgentElements-LICENSE").write_bytes((ROOT / "pill-kit/upstream/LICENSE").read_bytes())
            (resources / "imrse_ImrseLocal.bundle/Contents/Resources/Qwen3-APACHE-LICENSE.txt").write_text("license")
            (resources / "mlx-swift_Cmlx.bundle").mkdir()
            (resources / "mlx-swift_Cmlx.bundle/default.metallib").write_bytes(b"shader")
            for _, _, _, _, license_name in RUNTIME_DEPENDENCIES:
                (resources / "ThirdPartyLicenses" / license_name).write_text("license")
            for license_name in ("yyjson-LICENSE", "mlx-core-LICENSE"):
                (resources / "ThirdPartyLicenses" / license_name).write_text("license")
            validate_required_resources(app, ROOT)
            for license_name in ("yyjson-LICENSE", "mlx-core-LICENSE"):
                missing_license = resources / "ThirdPartyLicenses" / license_name
                missing_license.unlink()
                with self.assertRaisesRegex(PackageError, "required license or notice is missing"):
                    validate_required_resources(app, ROOT)
                missing_license.write_text("license")
            (resources / "IMRSE-LICENSE.txt").unlink()
            with self.assertRaises(PackageError):
                validate_required_resources(app, ROOT)

    def test_symlink_and_forbidden_user_data_checks_remain_enforced(self):
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp) / "imrse.app"
            (bundle / "Contents/Resources").mkdir(parents=True)
            (bundle / "Contents/Resources/credentials").mkdir()
            with self.assertRaisesRegex(PackageError, "must not be bundled"):
                validate_no_bundled_user_data(bundle)
            (bundle / "Contents/Resources/credentials").rmdir()
            (bundle / "Contents/Resources/config.json").write_text("{}")
            self.assertIn("credentials", FORBIDDEN_PATH_COMPONENTS)
            self.assertIn("config.json", FORBIDDEN_FILE_NAMES)
            with self.assertRaisesRegex(PackageError, "must not be bundled"):
                validate_no_bundled_user_data(bundle)
            (bundle / "Contents/Resources/config.json").unlink()
            (bundle / "Contents/Resources/plain.txt").write_text("data")
            (bundle / "Contents/Resources/config.json").symlink_to("plain.txt")
            with self.assertRaisesRegex(PackageError, "configuration file"):
                validate_no_bundled_user_data(bundle)
            (bundle / "Contents/Resources/config.json").unlink()
            (bundle / "Contents/Resources/outside").symlink_to(os.path.relpath(temp, bundle / "Contents/Resources"), target_is_directory=True)
            with self.assertRaisesRegex(PackageError, "escapes app bundle"):
                validate_symlinks(bundle)

    def test_zip_is_repeatable_and_preserves_executable_and_symlink_modes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "imrse.app"
            (root / "Contents/MacOS").mkdir(parents=True)
            executable = root / "Contents/MacOS/imrse"
            executable.write_bytes(b"binary")
            executable.chmod(0o755)
            (root / "Contents/Resources").mkdir()
            (root / "Contents/Resources/z.txt").write_text("z")
            (root / "Contents/Resources/a.txt").write_text("a")
            (root / "Contents/Resources/current.txt").symlink_to("a.txt")
            first = Path(temp) / "first.zip"
            second = Path(temp) / "second.zip"
            create_zip(root, first)
            create_zip(root, second)
            digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(digest(first), digest(second))
            with zipfile.ZipFile(first) as archive:
                names = archive.namelist()
                self.assertEqual(names, sorted(names))
                executable_info = archive.getinfo("imrse.app/Contents/MacOS/imrse")
                self.assertEqual((executable_info.external_attr >> 16) & 0o777, 0o755)
                link_info = archive.getinfo("imrse.app/Contents/Resources/current.txt")
                self.assertEqual((link_info.external_attr >> 16) & 0o170000, 0o120000)
                self.assertEqual(archive.read(link_info), b"a.txt")

    def test_arm64_gate_rejects_universal_and_intel_only_binaries(self):
        self.assertTrue(architecture_set_is_arm64_only({"arm64"}))
        self.assertFalse(architecture_set_is_arm64_only({"arm64", "x86_64"}))
        with self.assertRaises(PackageError):
            architecture_set_is_arm64_only({"x86_64"})


if __name__ == "__main__":
    unittest.main()
