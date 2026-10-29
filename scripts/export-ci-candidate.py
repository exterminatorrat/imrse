#!/usr/bin/env python3
import argparse
import json
import os
import platform
import stat
import sys
import tarfile
from pathlib import Path

import package_local_candidate as package
import ci_approval
approved_patch = ci_approval.approved_patch
approved_mlx_patch = ci_approval.approved_mlx_patch

TESTS = {
    "callbackDeliveryAndOrder": "URLSession.AsyncBytes delivers public callbacks in order",
    "closeFromFirstMessageStopsStream": "Closing in the first message callback stops later data and reconnection",
    "closeFromOpenPreventsLateCallbacks": "Closing from open before byte consumption suppresses late callbacks",
}
RECEIPT = "CI-PACKAGE-VALIDATION.json"
PATCH_SIDECAR = "argument-parser-compatibility.json"
PATCH_APP_RECEIPT = "ThirdPartyLicenses/swift-argument-parser-COMPATIBILITY.json"
PATCH_APP_LICENSE = "ThirdPartyLicenses/swift-argument-parser-LICENSE.txt"
PATCH_TEST_LOG = "argument-parser-compatibility-tests.log"
PATCH_DUMP = "argument-parser-dump-help.json"
PATCH_BUILD_INPUTS = "argument-parser-build-inputs.json"
MLX_SIDECAR = "mlx-mask-fill-compatibility.json"
MLX_APP_RECEIPT = "ThirdPartyLicenses/mlx-swift-COMPATIBILITY.json"
MLX_APP_LICENSE = "ThirdPartyLicenses/mlx-swift-LICENSE"
MLX_CONTROL_FLOW_LOG = "mlx-mask-fill-control-flow-tests.log"
MLX_BUILD_INPUTS = "mlx-mask-fill-build-inputs.json"
MLX_CONTROL_FLOW_MARKER = "MLX mask-fill control-flow checks passed."
MAX_PATCH_PROOF = 1024 * 1024


class ExportError(Exception):
    pass


def need(value, message):
    if not value:
        raise ExportError(message)


def git(root, *args):
    return package.run(["git", "-C", str(root), *args]).strip()


def read_regular(path, limit=MAX_PATCH_PROOF):
    try:
        path = Path(path)
        info = path.lstat()
        need(stat.S_ISREG(info.st_mode) and info.st_size <= limit, "proof is not a bounded regular file")
        return path.read_bytes()
    except OSError as error:
        raise ExportError("required patch proof is missing") from error


def approved_license(root, patch):
    license_record = patch.get("license")
    need(isinstance(license_record, dict), "patch approval lacks its upstream license")
    path, digest = license_record.get("path"), license_record.get("sha256")
    need(
        isinstance(path, str)
        and path
        and not path.startswith("/")
        and "\\" not in path
        and all(part not in {"", ".", ".."} for part in path.split("/"))
        and isinstance(digest, str)
        and len(digest) == 64
        and all(char in "0123456789abcdef" for char in digest),
        "patch approval has an invalid upstream license pin",
    )
    source = root / ".build/checkouts/swift-argument-parser"
    for index, part in enumerate(path.split("/")):
        source /= part
        info = source.lstat()
        need(
            not stat.S_ISLNK(info.st_mode)
            and (stat.S_ISREG(info.st_mode) if index == len(path.split("/")) - 1 else stat.S_ISDIR(info.st_mode)),
            "upstream license path is not a regular source file",
        )
    need(source.resolve(strict=True) == source, "upstream license path traverses a symlink")
    data = read_regular(source)
    need(package.sha256_file(source) == digest, "upstream swift-argument-parser license differs from approval")
    return data


def patch_proof(args, root, bundle, commit):
    patch = approved_patch(root, commit)
    external = read_regular(args.argument_parser_patch_receipt)
    try:
        canonical = (json.dumps(patch, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        need(external == canonical and package.strict_json_loads(external) == patch,
             "compatibility receipt differs from canonical committed approval")
    except (ValueError, TypeError) as error:
        raise ExportError("compatibility receipt is not strict JSON") from error
    original_license = approved_license(root, patch)
    resources = bundle / "Contents/Resources"
    need(read_regular(resources / PATCH_APP_RECEIPT) == external,
         "embedded compatibility receipt differs from external proof")
    need(read_regular(resources / PATCH_APP_LICENSE) == original_license,
         "embedded swift-argument-parser license differs from upstream")
    return patch, external


def approved_mlx_license(root, patch):
    license_record = patch.get("license")
    need(isinstance(license_record, dict) and set(license_record) == {"path", "sha256"}
         and license_record.get("path") == "LICENSE" and isinstance(license_record.get("sha256"), str)
         and len(license_record["sha256"]) == 64
         and all(char in "0123456789abcdef" for char in license_record["sha256"]),
         "MLX approval has an invalid upstream license pin")
    source = root
    for index, part in enumerate((".build", "checkouts", "mlx-swift", "LICENSE")):
        source /= part
        info = source.lstat()
        need(not stat.S_ISLNK(info.st_mode)
             and (stat.S_ISREG(info.st_mode) if index == 3 else stat.S_ISDIR(info.st_mode)),
             "upstream MLX license path is not a regular source file")
    data = read_regular(source)
    need(package.sha256_file(source) == license_record["sha256"], "upstream mlx-swift license differs from approval")
    return data


def mlx_patch_proof(args, root, bundle, commit, inventory):
    patch = approved_mlx_patch(root, commit)
    external = read_regular(args.mlx_mask_fill_patch_receipt)
    try:
        canonical = (json.dumps(patch, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        need(external == canonical and package.strict_json_loads(external) == patch,
             "MLX compatibility receipt differs from canonical committed approval")
    except (ValueError, TypeError) as error:
        raise ExportError("MLX compatibility receipt is not strict JSON") from error
    original_license = approved_mlx_license(root, patch)
    resources = bundle / "Contents/Resources"
    need(read_regular(resources / MLX_APP_RECEIPT) == external,
         "embedded MLX compatibility receipt differs from external proof")
    need(read_regular(resources / MLX_APP_LICENSE) == original_license,
         "embedded mlx-swift license differs from upstream")
    try:
        ci_approval.validate_mlx_inventory(patch, {entry["path"]: entry for entry in inventory}, external)
    except (ValueError, TypeError, KeyError) as error:
        raise ExportError("app MLX compatibility receipt or license inventory differs from approval") from error
    return patch, external


def qualification_logs(output):
    log = output / PATCH_TEST_LOG
    dump = output / PATCH_DUMP
    build_inputs = output / PATCH_BUILD_INPUTS
    text = read_regular(log, 16 * 1024**2).decode("utf-8")
    need(text.splitlines() and text.splitlines()[-1] == "ArgumentParser compatibility checks passed.",
         "ArgumentParser compatibility log lacks its completion marker")
    read_regular(dump, 16 * 1024**2)
    read_regular(build_inputs, 16 * 1024**2)
    return tuple(package.sha256_file(path) for path in (log, dump, build_inputs))


def mlx_qualification(output):
    control_flow_log = output / MLX_CONTROL_FLOW_LOG
    build_inputs = output / MLX_BUILD_INPUTS
    text = read_regular(control_flow_log, 16 * 1024**2).decode("utf-8")
    need(text.splitlines() and text.splitlines()[-1] == MLX_CONTROL_FLOW_MARKER,
         "MLX mask-fill control-flow log lacks its completion marker")
    need(read_regular(build_inputs, 16 * 1024**2), "MLX build inputs proof is empty")
    try:
        getter_hash = ci_approval.getter_log_digest(read_regular(output / ci_approval.GETTER_LOG, 16 * 1024**2))
    except ValueError as error:
        raise ExportError(str(error)) from error
    return package.sha256_file(control_flow_log), package.sha256_file(build_inputs), getter_hash


def source(root, expected):
    commit = git(root, "rev-parse", "HEAD")
    need(len(expected) == 40 and all(c in "0123456789abcdefABCDEF" for c in expected) and
         commit.lower() == expected.lower(), "checkout differs from selected workflow SHA")
    tree = git(root, "rev-parse", f"{commit}^{{tree}}")
    need(not git(root, "status", "--porcelain", "--untracked-files=all"),
         "source checkout changed during CI validation")
    return commit, tree


def test_count(path):
    lines = Path(path).read_text().splitlines()
    for function, title in TESTS.items():
        events = [line for line in lines if "Test " in line and (function in line or title in line)]
        need(len(events) == 2 and sum("started" in line for line in events) == 1 and
             sum("passed" in line for line in events) == 1, f"EventSource test did not run and pass: {function}")
    return len(TESTS)


def app_bundle(path, root, commit, tree):
    path = Path(path).expanduser()
    need(not path.is_symlink(), "app bundle must not be a symlink")
    bundle, info = package.validate_built_app_bundle(path, package.read_source_info(root))
    resources = bundle / "Contents/Resources"
    files = (
        next((p for p in resources.rglob("default.metallib") if p.is_file() and p.stat().st_size), None),
        next((p for p in resources.rglob("imrse-menubar-template.pdf") if p.is_file() and p.parent.name == "Brand" and p.stat().st_size), None),
        resources / "imrse_ImrseLocal.bundle/Contents/Resources/Qwen3-APACHE-LICENSE.txt",
        resources / "ThirdPartyLicenses/EventSource-LICENSE.md",
        resources / "ThirdPartyLicenses/EventSource-PROVENANCE.md",
    )
    for item, label in zip(files, ("default.metallib", "Brand menu PDF", "Qwen license", "EventSource license", "EventSource provenance")):
        need(item is not None and item.is_file() and item.stat().st_size, f"missing nonempty {label}")
    vendor = root / "Vendor/EventSource"
    need(files[3].read_bytes() == (vendor / "LICENSE.md").read_bytes(), "EventSource license differs from vendor source")
    need(files[4].read_bytes() == (vendor / "PROVENANCE.md").read_bytes(), "EventSource provenance differs from vendor source")
    try:
        receipt = json.loads((resources / RECEIPT).read_text())
    except (OSError, ValueError) as error:
        raise ExportError("app is missing its CI package validation receipt") from error
    need(receipt.get("validationMode") == "unsigned-ci-package-validation-only" and
         receipt.get("distributionEligible") is False and receipt.get("codeSigningPerformed") is False and
         receipt.get("releaseBuildProvenanceCreated") is False, "app is not marked unsigned CI-only")
    need(receipt.get("source") == {"commitSHA": commit, "treeSHA": tree}, "CI receipt is bound to different source")
    arch = receipt.get("product", {}).get("machoArchitectures")
    need(receipt.get("product", {}).get("hostArchitecture") == "arm64" and isinstance(arch, dict) and
         arch and set(arch.values()) == {"arm64"} and platform.machine().lower() in {"arm64", "aarch64"},
         "CI receipt does not prove an arm64-only candidate")
    return bundle, info


def export(args, root, commit, tree, tests):
    output = Path(args.output_dir).expanduser().resolve(strict=True)
    need(not output.is_relative_to(root), "candidate output must be outside source checkout")
    bundle, info = app_bundle(args.app, root, commit, tree)
    inventory = package.bundle_tree_entries(bundle)
    patch_bytes = patch_proof(args, root, bundle, commit)[1]
    mlx_patch_bytes = mlx_patch_proof(args, root, bundle, commit, inventory)[1]
    patch_test_hash, patch_dump_hash, patch_build_hash = qualification_logs(output)
    mlx_control_flow_hash, mlx_build_hash, mlx_getter_hash = mlx_qualification(output)
    archive, manifest = output / "imrse-ci-candidate-arm64.tar.gz", output / "candidate-provenance.json"
    patch_sidecar = output / PATCH_SIDECAR
    mlx_sidecar = output / MLX_SIDECAR
    need(not archive.exists() and not manifest.exists(), "candidate output already exists")
    if os.path.lexists(patch_sidecar):
        need(read_regular(patch_sidecar) == patch_bytes, "output compatibility sidecar differs from proof")
    else:
        patch_sidecar.write_bytes(patch_bytes)
    if os.path.lexists(mlx_sidecar):
        need(read_regular(mlx_sidecar) == mlx_patch_bytes, "output MLX compatibility sidecar differs from proof")
    else:
        mlx_sidecar.write_bytes(mlx_patch_bytes)
    with tarfile.open(archive, "x:gz") as tar:
        tar.add(bundle, arcname="imrse.app", recursive=True)
    archive_hash = package.sha256_file(archive)
    payload = {
        "schemaVersion": 1, "scope": "unsigned CI validation only; not distribution eligible or compiler attestation",
        "source": {"commitSHA": commit, "treeSHA": tree, "selectedCommitSHA": args.expected_commit,
                   "eventSHA": os.getenv("GITHUB_SHA")},
        "ci": {key: os.getenv(env) for key, env in (("workflow", "GITHUB_WORKFLOW"), ("job", "GITHUB_JOB"),
               ("runID", "GITHUB_RUN_ID"), ("runAttempt", "GITHUB_RUN_ATTEMPT"), ("eventName", "GITHUB_EVENT_NAME"))},
        "host": {"os": "macOS", "architecture": "arm64", "minimumMacOS": info["LSMinimumSystemVersion"]},
        "toolchain": {"xcode": Path(args.xcode_version_log).read_text().strip(),
                      "swift": Path(args.swift_version_log).read_text().strip()},
        "build": {"configuration": "release", "system": "xcodebuild", "jobs": 1, "warningsAsErrors": True,
                  "wholeModuleOptimization": True, "eventsourceTestsExecuted": tests,
                  "buildLogSHA256": package.sha256_file(args.build_log),
                  "eventsourceTestLogSHA256": package.sha256_file(args.eventsource_test_log)},
        "dependencies": {"rootGraphSHA256": package.sha256_file(args.graph_json),
                          "packageResolvedSHA256": package.sha256_file(root / "Package.resolved"),
                          "vendorEventSourceTreeSHA256": package.bundle_tree_sha256(root / "Vendor/EventSource"),
                          "argumentParserPatchReceiptSHA256": package.sha256_file(patch_sidecar),
                          "argumentParserCompatibilityTestLogSHA256": patch_test_hash,
                          "argumentParserDumpHelpSHA256": patch_dump_hash,
                          "argumentParserBuildInputsSHA256": patch_build_hash,
                          "mlxMaskFillPatchReceiptSHA256": package.sha256_file(mlx_sidecar),
                          "mlxMaskFillControlFlowTestLogSHA256": mlx_control_flow_hash,
                          "mlxGetterCompatibilityTestLogSHA256": mlx_getter_hash,
                          "mlxMaskFillBuildInputsSHA256": mlx_build_hash},
        "app": {"bundleTreeSHA256": package.bundle_tree_sha256(bundle), "inventory": inventory},
        "archive": {"file": archive.name, "sha256": archive_hash, "format": "tar.gz; Unix modes preserved"},
    }
    manifest.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    (output / f"{archive.name}.sha256").write_text(f"{archive_hash}  {archive.name}\n")
    (output / f"{manifest.name}.sha256").write_text(f"{package.sha256_file(manifest)}  {manifest.name}\n")
    print(f"Unsigned arm64 candidate: {archive}\nProvenance: {manifest}")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Validate and archive the unsigned macOS CI app candidate")
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--graph-json", required=True, type=Path)
    parser.add_argument("--eventsource-test-log", required=True, type=Path)
    parser.add_argument("--argument-parser-patch-receipt", required=True, type=Path)
    parser.add_argument("--mlx-mask-fill-patch-receipt", required=True, type=Path)
    for name in ("app", "output-dir", "swift-version-log", "xcode-version-log", "build-log"):
        parser.add_argument(f"--{name}", type=Path)
    args = parser.parse_args(argv)
    try:
        root = args.source_root.expanduser().resolve(strict=True)
        commit, tree = source(root, args.expected_commit)
        tests = test_count(args.eventsource_test_log)
        need(all((args.app, args.output_dir, args.swift_version_log, args.xcode_version_log, args.build_log)),
             "export needs app, output, toolchain logs, and build log")
        export(args, root, commit, tree, tests)
    except (ExportError, package.PackageError, OSError, ValueError, KeyError, tarfile.TarError) as error:
        print(f"CI candidate export failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
