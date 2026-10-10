import hashlib
from contextlib import redirect_stdout
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
    normalized_release_build_command,
    read_pins,
    read_source_info,
    record_build_provenance,
    sha256_file,
    source_git_files,
    sign_and_verify,
    normalize_certificate_sha1,
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
        self.codesign_available_sha1 = TEST_CERTIFICATE_SHA1
        self.codesign_actual_sha1 = TEST_CERTIFICATE_SHA1
        self.codesign_signature_type = "certificate-signed"
        self.codesign_identifiers = {}
        self.codesign_designated_requirements = {}
        self.codesign_commented_designated_requirements = set()
        self.codesign_designated_outputs = {}
        self.codesign_patcher = patch.object(packager, "run", side_effect=self.stub_packager_run)
        self.codesign_patcher.start()
        self.addCleanup(self.codesign_patcher.stop)

    def stub_packager_run(self, command, **kwargs):
        if command[0] != "codesign":
            return self.real_packager_run(command, **kwargs)
        command = [str(argument) for argument in command]
        self.codesign_calls.append(command)
        path = Path(command[-1])
        if "--sign" in command:
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
        (product / "Contents/MacOS").mkdir(parents=True)
        (product / "Contents/MacOS/imrse").write_bytes(b"\xcf\xfa\xed\xfe fake product executable")
        (product / "Contents/Info.plist").write_bytes((self.source_root / "Resources/Info.plist").read_bytes())
        provenance_path = record_build_provenance(
            self.source_root,
            self.source_commit,
            self.source_tree,
            build_root,
            copy_root,
            expected_release_build_command(build_root),
            TEST_CERTIFICATE_SHA1,
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
            )
            self.assertEqual(record["sourceCommitSHA"], self.source_commit)
            self.assertEqual(record["sourceTreeSHA"], self.source_tree)
            self.assertEqual(record["schemaVersion"], 4)
            self.assertEqual(record["inputCopyRelativePath"], "source")
            self.assertEqual(record["buildInputs"]["lockFilesSHA256"], {path: sha256_file(self.source_root / path) for path in LOCK_FILES})
            self.assertEqual(record["build"]["command"], normalized_release_build_command())
            self.assertEqual(record["build"]["workingDirectoryRelativePath"], "source")
            self.assertEqual(record["build"]["signingCertificateSHA1"], TEST_CERTIFICATE_SHA1)
            self.assertEqual(record["product"]["signatureReceipt"]["certificateSHA1"], TEST_CERTIFICATE_SHA1)
            self.assertEqual(record["product"]["signatureReceipt"]["bundle"]["identifier"], EXPECTED_BUNDLE_ID)
            self.assertIn("not an independent compiler attestation", record["build"]["provenanceScope"])
            self.assertNotIn(str(build_root), json.dumps(record["build"]))
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
            *(f"--build-command-arg={argument}" for argument in command),
        ]
        with patch.object(packager, "record_build_provenance", return_value=build_root / BUILD_PROVENANCE_FILE) as recorder:
            with redirect_stdout(StringIO()):
                result = packager.main(argv)
        self.assertEqual(result, 0)
        self.assertEqual(recorder.call_args.args[4], working_directory)
        self.assertEqual(recorder.call_args.args[5], command)
        self.assertEqual(recorder.call_args.args[6], TEST_CERTIFICATE_SHA1)

    def test_certificate_sha1_requires_one_explicit_40_hex_selector(self):
        self.assertEqual(normalize_certificate_sha1(TEST_CERTIFICATE_SHA1.upper()), TEST_CERTIFICATE_SHA1)
        for invalid in (None, "", "-", "a" * 39, "g" * 40, "a" * 39 + ":"):
            with self.subTest(invalid=invalid):
                with self.assertRaisesRegex(PackageError, "caller-selected 40-hex certificate SHA-1"):
                    normalize_certificate_sha1(invalid)

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
            receipt = packager.sign_app_bundle(bundle, TEST_CERTIFICATE_SHA1.upper())
        self.assertEqual(receipt["certificateSHA1"], TEST_CERTIFICATE_SHA1)
        self.assertEqual(receipt["bundle"]["identifier"], EXPECTED_BUNDLE_ID)
        self.assertEqual(
            {item["relativePath"]: item["identifier"] for item in receipt["codeItems"]},
            {"Contents/MacOS/imrse": EXPECTED_BUNDLE_ID, "Contents/Frameworks/helper": "com.example.helper"},
        )
        self.assertEqual(self.codesign_signers, [TEST_CERTIFICATE_SHA1] * 3)
        nested_receipt = next(item for item in receipt["codeItems"] if item["relativePath"] == "Contents/Frameworks/helper")
        self.assertEqual(nested_receipt["defaultDesignatedRequirement"], f'identifier "com.example.helper" and anchor apple generic and certificate leaf H"{TEST_CERTIFICATE_SHA1}"')
        verification_commands = [command for command in self.codesign_calls if "--verify" in command]
        self.assertEqual(len(verification_commands), 3)
        self.assertTrue(all(f'-R=certificate leaf H"{TEST_CERTIFICATE_SHA1}"' in command for command in verification_commands))
        self.assertTrue(any("--deep" in command for command in verification_commands))
        first_leaf_verification = next(index for index, command in enumerate(self.codesign_calls) if "--verify" in command)
        first_default_requirement_read = next(index for index, command in enumerate(self.codesign_calls) if "-r-" in command)
        self.assertLess(first_leaf_verification, first_default_requirement_read)

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
                    sign_and_verify(bundle, [main], TEST_CERTIFICATE_SHA1)

    def test_certificate_signer_rejects_adhoc_and_mismatched_certificate_output(self):
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp) / "imrse.app"
            main = bundle / "Contents/MacOS/imrse"
            main.parent.mkdir(parents=True)
            main.write_bytes(b"\xcf\xfa\xed\xfe fake main Mach-O")
            self.codesign_signature_type = "ad-hoc"
            with self.assertRaisesRegex(PackageError, "does not satisfy the selected certificate"):
                sign_and_verify(bundle, [main], TEST_CERTIFICATE_SHA1)
            self.codesign_signature_type = "certificate-signed"
            self.codesign_actual_sha1 = "f" * 40
            with self.assertRaisesRegex(PackageError, "does not satisfy the selected certificate"):
                sign_and_verify(bundle, [main], TEST_CERTIFICATE_SHA1)
            with self.assertRaisesRegex(PackageError, "no matching signing identity"):
                sign_and_verify(bundle, [main], "f" * 40)

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
                )
            self.assertFalse((build_root / BUILD_PROVENANCE_FILE).exists())

            provenance_path = record_build_provenance(
                self.source_root,
                self.source_commit,
                self.source_tree,
                build_root,
                copy_root,
                expected,
                TEST_CERTIFICATE_SHA1,
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
                )

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
                packager.sign_app_bundle(bundle, TEST_CERTIFICATE_SHA1)
            self.assertEqual(self.codesign_calls, [])

        with tempfile.TemporaryDirectory() as temp:
            build_root, copy_root, _, product, provenance_path = self.make_build_fixture(Path(temp))
            provenance_path.unlink()
            receipt = product / "Contents/Resources" / CI_VALIDATION_RECEIPT_FILE
            receipt.parent.mkdir(parents=True, exist_ok=True)
            receipt.write_text('{"distributionEligible":false}')
            with self.assertRaisesRegex(PackageError, "cannot be signed"):
                record_build_provenance(
                    self.source_root,
                    self.source_commit,
                    self.source_tree,
                    build_root,
                    copy_root,
                    expected_release_build_command(build_root),
                    TEST_CERTIFICATE_SHA1,
                )
            self.assertFalse(provenance_path.exists())

        with tempfile.TemporaryDirectory() as temp:
            build_root, _, _, product, provenance_path = self.make_build_fixture(Path(temp))
            receipt = product / "Contents/Resources" / CI_VALIDATION_RECEIPT_FILE
            receipt.parent.mkdir(parents=True, exist_ok=True)
            receipt.write_text('{"distributionEligible":false}')
            with self.assertRaisesRegex(PackageError, "cannot be signed"):
                validate_build_provenance(
                    provenance_path,
                    self.source_root,
                    product,
                    build_root,
                    self.source_commit,
                    self.source_tree,
                    TEST_CERTIFICATE_SHA1,
                )

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
            })
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
            })
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
            })
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
        self.assertIn('"$ROOT/scripts/package_local_candidate.py" sign-app', script)
        self.assertIn('"$ROOT/scripts/package_local_candidate.py" validate-ci-app', script)
        self.assertIn('--app "$STAGED_APP"', script)
        self.assertIn('--signing-certificate-sha1 "$SIGNING_CERTIFICATE_SHA1"', script)
        self.assertNotIn('SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"', script)
        self.assertNotIn('CODESIGN_ARGS=(--deep', script)
        for invalid in (None, "-", "x" * 40):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as temp:
                output = Path(temp) / "dist"
                environment = os.environ.copy()
                environment.pop("IMRSE_CI_PACKAGE_VALIDATION", None)
                environment.pop("IMRSE_SIGNING_CERTIFICATE_SHA1", None)
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

    def test_ci_build_validation_rejects_signers_release_inputs_and_unsafe_mode(self):
        cases = (
            ("signer", {"IMRSE_SIGNING_CERTIFICATE_SHA1": "not-a-selected-cert"}, "cannot use a signing selector"),
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
                self.assertEqual(argv[argv.index(b"--configuration") + 1], b"release")
                architecture_options = [index for index, argument in enumerate(argv) if argument == b"--arch"]
                self.assertEqual(len(architecture_options), 1)
                self.assertEqual(argv[architecture_options[0] + 1].decode(), expected_architecture)
                self.assertNotIn(b"--triple", argv)
                self.assertIn(b"--only-use-versions-from-resolved-file", argv)
                self.assertEqual(argv[-2:], [b"--product", b"imrse"])
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
        self.assertIn('PYTHONDONTWRITEBYTECODE: "1"', package_job)
        self.assertIn("IMRSE_DIST_DIR: ${{ runner.temp }}/imrse-ci-package-validation", package_job)
        self.assertNotIn("IMRSE_SIGNING_CERTIFICATE_SHA1", package_job)
        self.assertIn("bash -n scripts/build-app.sh", package_job)
        self.assertIn("plutil -lint Resources/Info.plist", package_job)
        self.assertIn("python3 -m unittest discover -s scripts/tests -p 'test_package_local_candidate.py' -v", package_job)
        self.assertIn("./scripts/build-app.sh", package_job)
        self.assertNotIn("upload-artifact", package_job)
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
        ))

    def test_sign_app_cli_routes_build_output_to_the_explicit_signer(self):
        output = StringIO()
        with patch.object(packager, "sign_app_bundle") as signer:
            with redirect_stdout(output):
                self.assertEqual(packager.main([
                    "sign-app",
                    "--app", "/tmp/build/products/imrse.app",
                    "--signing-certificate-sha1", TEST_CERTIFICATE_SHA1,
                ]), 0)
        self.assertEqual(signer.call_args.args, (Path("/tmp/build/products/imrse.app"), TEST_CERTIFICATE_SHA1))
        self.assertIn("Signed and verified certificate-selected app", output.getvalue())

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
            (source / "Contents/MacOS/imrse").write_bytes(b"input")
            source_info = read_source_info(ROOT)
            (source / "Contents/Info.plist").write_bytes(plistlib.dumps(source_info))
            bundle = Path(temp) / "candidate.app"
            (bundle / "Contents/MacOS").mkdir(parents=True)
            (bundle / "Contents/MacOS/imrse").write_bytes(b"candidate")
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(source_info))
            resources = bundle / "Contents/Resources/ThirdPartyLicenses"
            resources.mkdir(parents=True)
            for dependency in (*RUNTIME_DEPENDENCIES, *C_RUNTIME_DEPENDENCIES):
                (resources / dependency[4]).write_text(dependency[4])
            (resources / "mlx-core-LICENSE").write_text("mlx-core-LICENSE")
            yyjson_hash = hashlib.sha256(b"yyjson-LICENSE").hexdigest()
            build_receipt = {
                "certificateSHA1": TEST_CERTIFICATE_SHA1,
                "signatureType": "certificate-signed",
                "bundle": {
                    "certificateSHA1": TEST_CERTIFICATE_SHA1,
                    "signatureType": "certificate-signed",
                    "identifier": EXPECTED_BUNDLE_ID,
                    "defaultDesignatedRequirement": 'identifier "org.imrse.app" and anchor apple generic',
                },
                "codeItems": [{
                    "relativePath": "Contents/MacOS/imrse",
                    "certificateSHA1": TEST_CERTIFICATE_SHA1,
                    "signatureType": "certificate-signed",
                    "identifier": EXPECTED_BUNDLE_ID,
                    "defaultDesignatedRequirement": 'identifier "org.imrse.app" and anchor apple generic',
                }],
            }
            candidate_receipt = {
                **build_receipt,
                "bundle": {**build_receipt["bundle"], "defaultDesignatedRequirement": 'identifier "org.imrse.app" and anchor apple generic and candidate'},
            }
            build_record = {
                "build": {
                    "configuration": "release",
                    "workingDirectoryRelativePath": "source",
                    "command": normalized_release_build_command(),
                    "commandPathValuesRelativeToBuildRoot": True,
                    "signingCertificateSHA1": TEST_CERTIFICATE_SHA1,
                    "provenanceScope": "local builder-supplied invocation metadata and product hashes; not an independent compiler attestation",
                },
                "product": {"signatureReceipt": build_receipt},
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
            )
            manifest = candidate_manifest(*manifest_args)
            wrong_candidate_receipt = {**candidate_receipt, "certificateSHA1": "f" * 40}
            with self.assertRaisesRegex(PackageError, "signature receipts do not match"):
                candidate_manifest(*manifest_args[:-1], wrong_candidate_receipt)
            empty_candidate_receipt = {**candidate_receipt, "codeItems": []}
            with self.assertRaisesRegex(PackageError, "signature receipts do not match"):
                candidate_manifest(*manifest_args[:-1], empty_candidate_receipt)
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
        self.assertEqual(manifest["schemaVersion"], 4)
        self.assertEqual(manifest["source"]["buildProduct"]["signatureReceipt"], build_receipt)
        self.assertEqual(manifest["signing"]["certificateSHA1"], TEST_CERTIFICATE_SHA1)
        self.assertEqual(manifest["signing"]["signatureType"], CERTIFICATE_SIGNING_LABEL)
        self.assertFalse(manifest["signing"]["developerID"])
        self.assertFalse(manifest["signing"]["notarized"])
        self.assertEqual(manifest["signing"]["candidateReceipt"], candidate_receipt)
        self.assertIn("no TCC reuse claim", " ".join(manifest["limitations"]))
        install_guide = (ROOT / "docs/manual-candidate-install.md").read_text()
        self.assertIn("caller-selected 40-hex certificate SHA-1", install_guide)
        self.assertIn("IMRSE_SIGNING_CERTIFICATE_SHA1", install_guide)
        self.assertIn("--signing-certificate-sha1", install_guide)
        self.assertIn("not proof that its private key is available", install_guide)
        self.assertIn("no TCC reuse promise", install_guide)
        self.assertNotIn("ad-hoc signed", install_guide)
        self.assertEqual(manifest["source"]["buildProduct"]["configuration"], "release")
        self.assertEqual(manifest["source"]["buildProduct"]["workingDirectoryRelativePath"], "source")
        self.assertNotIn("candidateDeltaPatch", manifest["source"])
        self.assertNotIn("preservedStateSnapshot", manifest["source"])
        self.assertNotIn("baseCommitSHA", manifest["source"])
        self.assertNotIn("sourceRegressionGate", manifest["verification"])

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
