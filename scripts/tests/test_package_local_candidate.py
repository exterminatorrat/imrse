import hashlib
from contextlib import redirect_stdout
from io import StringIO
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from scripts import package_local_candidate as packager
from scripts.package_local_candidate import (
    BUILD_PROVENANCE_FILE,
    CANDIDATE_VERSION,
    C_RUNTIME_DEPENDENCIES,
    EXPECTED_APP_VERSION,
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
    validate_app_version_metadata,
    validate_build_provenance,
    validate_built_app_bundle,
    validate_no_bundled_user_data,
    validate_required_resources,
    validate_source_copy,
    validate_symlinks,
)


ROOT = Path(__file__).resolve().parents[2]


class PackageLocalCandidateTests(unittest.TestCase):
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
        build_root = base / "isolated-build"
        copy_root, manifest_path = copy_source_inputs(
            self.source_root,
            self.source_commit,
            self.source_tree,
            build_root,
        )
        product = build_root / "products/imrse.app"
        (product / "Contents/MacOS").mkdir(parents=True)
        (product / "Contents/MacOS/imrse").write_bytes(b"test product executable")
        (product / "Contents/Info.plist").write_bytes((self.source_root / "Resources/Info.plist").read_bytes())
        provenance_path = record_build_provenance(
            self.source_root,
            self.source_commit,
            self.source_tree,
            build_root,
            copy_root,
            expected_release_build_command(build_root),
        )
        return build_root, copy_root, manifest_path, product, provenance_path

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
            )
            self.assertEqual(record["sourceCommitSHA"], self.source_commit)
            self.assertEqual(record["sourceTreeSHA"], self.source_tree)
            self.assertEqual(record["inputCopyRelativePath"], "source")
            self.assertEqual(record["buildInputs"]["lockFilesSHA256"], {path: sha256_file(self.source_root / path) for path in LOCK_FILES})
            self.assertEqual(record["build"]["command"], normalized_release_build_command())
            self.assertEqual(record["build"]["workingDirectoryRelativePath"], "source")
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
            *(f"--build-command-arg={argument}" for argument in command),
        ]
        with patch.object(packager, "record_build_provenance", return_value=build_root / BUILD_PROVENANCE_FILE) as recorder:
            with redirect_stdout(StringIO()):
                result = packager.main(argv)
        self.assertEqual(result, 0)
        self.assertEqual(recorder.call_args.args[4], working_directory)
        self.assertEqual(recorder.call_args.args[5], command)

    def test_build_provenance_rejects_wrong_builder_argv_paths_and_working_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            build_root = base / "isolated-build"
            copy_root, _ = copy_source_inputs(
                self.source_root,
                self.source_commit,
                self.source_tree,
                build_root,
            )
            product = build_root / "products/imrse.app"
            (product / "Contents/MacOS").mkdir(parents=True)
            (product / "Contents/MacOS/imrse").write_bytes(b"test product executable")
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
                )
            self.assertFalse((build_root / BUILD_PROVENANCE_FILE).exists())

            provenance_path = record_build_provenance(
                self.source_root,
                self.source_commit,
                self.source_tree,
                build_root,
                copy_root,
                expected,
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
                )
            self.assertFalse(provenance_path.exists())

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
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/build-app.sh")],
                cwd=ROOT,
                env={**os.environ, "IMRSE_DIST_DIR": str(output), "IMRSE_REQUIRE_EMPTY_APP_OUTPUT": "1"},
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
            environment.pop("SWIFTPM_CACHE_PATH", None)
            environment.update({
                "IMRSE_RELEASE_SOURCE_COMMIT": self.source_commit,
                "IMRSE_RELEASE_SOURCE_TREE": self.source_tree,
                "IMRSE_RELEASE_BUILD_ROOT": str(build_root),
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
            environment.update({
                "IMRSE_RELEASE_SOURCE_COMMIT": self.source_commit,
                "IMRSE_RELEASE_SOURCE_TREE": self.source_tree,
                "IMRSE_RELEASE_BUILD_ROOT": str(build_root),
                "SWIFTPM_CACHE_PATH": str(external_cache),
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
        for key in ("IMRSE_RELEASE_SOURCE_COMMIT", "IMRSE_RELEASE_SOURCE_TREE", "IMRSE_RELEASE_BUILD_ROOT"):
            environment.pop(key, None)
        environment.pop("SWIFTPM_CACHE_PATH", None)
        environment["IMRSE_RELEASE_SOURCE_COMMIT"] = self.source_commit
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
            build_record = {
                "build": {
                    "configuration": "release",
                    "workingDirectoryRelativePath": "source",
                    "command": normalized_release_build_command(),
                    "commandPathValuesRelativeToBuildRoot": True,
                    "provenanceScope": "local builder-supplied invocation metadata and product hashes; not an independent compiler attestation",
                }
            }
            manifest = candidate_manifest(
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
            )
        yyjson = next(item for item in manifest["runtimeDependencies"] if item["package"] == "yyjson")
        self.assertEqual(yyjson["version"], "0.12.0")
        self.assertEqual(yyjson["revision"], "8b4a38dc994a110abaec8a400615567bd996105f")
        self.assertEqual(yyjson["binarySymbols"], ["_yyjson_read_opts"])
        self.assertEqual(yyjson["licenseSHA256"], yyjson_hash)
        self.assertEqual(manifest["source"]["commitSHA"], self.source_commit)
        self.assertEqual(manifest["source"]["buildProvenance"]["fileName"], BUILD_PROVENANCE_FILE)
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
