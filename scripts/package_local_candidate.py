#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import plistlib
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath


CANDIDATE_VERSION = "0.2.0-beta.1"
EXPECTED_APP_VERSION = "0.2.0"
EXPECTED_BUILD_VERSION = "13"
EXPECTED_BUNDLE_ID = "org.imrse.app"
EXPECTED_MINIMUM_OS = "14.0"
OUTPUT_NAME = f"imrse-{CANDIDATE_VERSION}-macos-arm64.zip"
BUILD_PROVENANCE_FILE = "BUILD-PROVENANCE.json"
SOURCE_INPUT_MANIFEST_FILE = "SOURCE-INPUT-MANIFEST.json"
CI_VALIDATION_RECEIPT_FILE = "CI-PACKAGE-VALIDATION.json"
LOCK_FILES = (
    "Package.swift",
    "Package.resolved",
    "pill-kit/native/Package.swift",
    "pill-kit/native/Package.resolved",
)
RUNTIME_DEPENDENCIES = (
    ("eventsource", "1.5.1", "86b5096ac59ab46e66bd1f6377c604bc1dab0bc2", ("EventSource",), "EventSource-LICENSE.md"),
    ("lottie-ios", "4.6.1", "f4db77d7feacba0c2360b84a40c38a6ce8ff399d", ("Lottie",), "lottie-ios-LICENSE"),
    ("mlx-swift", "0.31.6", "0bb916c67f4b9e5c682cbe02a42c701c93ab5021", ("MLX", "MLXNN", "MLXOptimizers"), "mlx-swift-LICENSE"),
    ("mlx-swift-lm", "3.31.4", "bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57", ("MLXHuggingFace", "MLXLLM", "MLXLMCommon"), "mlx-swift-lm-LICENSE"),
    ("swift-argument-parser", "1.8.2", "6a52f3251125d74daf04fcbd5e6f08a75d074382", ("ArgumentParser", "ArgumentParserToolInfo"), "swift-argument-parser-LICENSE.txt"),
    ("swift-collections", "1.7.1", "98ef3c98609a1e31b7e157b5b619579001a789d6", ("InternalCollectionsUtilities", "OrderedCollections"), "swift-collections-LICENSE.txt"),
    ("swift-crypto", "4.5.2", "da9d28d69ebe3894b18376c8f2395c2f37b8448f", ("Crypto",), "swift-crypto-LICENSE.txt"),
    ("swift-huggingface", "0.9.0", "b721959445b617d0bf03910b2b4aced345fd93bf", ("HuggingFace",), "swift-huggingface-LICENSE"),
    ("swift-jinja", "2.5.1", "4588064a20f3fc093c95f2f7d3359999bf30cae5", ("Jinja",), "swift-jinja-LICENSE"),
    ("swift-numerics", "1.1.1", "0c0290ff6b24942dadb83a929ffaaa1481df04a2", ("ComplexModule", "RealModule"), "swift-numerics-LICENSE.txt"),
    ("swift-transformers", "1.3.0", "b38443e44d93eca770f2eb68e2a4d0fa100f9aa2", ("Hub", "Tokenizers"), "swift-transformers-LICENSE"),
)
C_RUNTIME_DEPENDENCIES = (
    ("yyjson", "0.12.0", "8b4a38dc994a110abaec8a400615567bd996105f", ("_yyjson_read_opts",), "yyjson-LICENSE"),
)
MLX_CORE_LICENSE = "mlx-core-LICENSE"
FORBIDDEN_SUFFIXES = {".bin", ".gguf", ".ggml", ".safetensors", ".onnx", ".pt", ".pth"}
FORBIDDEN_FILE_NAMES = {"config.json", "credentials.json", "provider-config.json"}
FORBIDDEN_PATH_COMPONENTS = {"presets", "keychain", "credentials", "userdata"}
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
CERTIFICATE_SIGNING_LABEL = "certificate-signed locally; unnotarized"


class PackageError(Exception):
    pass


def run(command, *, cwd=None, input_text=None, env=None):
    result = subprocess.run(command, cwd=cwd, input=input_text, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, check=False)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise PackageError(f"{command[0]} failed ({result.returncode}): {detail}")
    return result.stdout + result.stderr


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def bundle_paths(bundle):
    yield bundle
    for directory, names, files in os.walk(bundle, followlinks=False):
        names.sort()
        files.sort()
        parent = Path(directory)
        for name in list(names):
            path = parent / name
            yield path
            if path.is_symlink():
                names.remove(name)
        for name in files:
            yield parent / name


def validate_symlinks(bundle):
    resolved_root = bundle.resolve(strict=True)
    for path in bundle_paths(bundle):
        if not path.is_symlink():
            continue
        target = os.readlink(path)
        if os.path.isabs(target):
            raise PackageError(f"absolute symlink is not safe to package: {path.relative_to(bundle)}")
        try:
            resolved_target = (path.parent / target).resolve(strict=False)
        except (OSError, RuntimeError) as error:
            raise PackageError(f"invalid symlink in app bundle: {path.relative_to(bundle)}") from error
        if not resolved_target.is_relative_to(resolved_root):
            raise PackageError(f"symlink escapes app bundle: {path.relative_to(bundle)}")


def bundle_tree_entries(bundle):
    entries = []
    for path in bundle_paths(bundle):
        relative = "." if path == bundle else path.relative_to(bundle).as_posix()
        mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            entries.append({"path": relative, "type": "symlink", "mode": mode, "target": os.readlink(path)})
        elif path.is_dir():
            entries.append({"path": relative, "type": "directory", "mode": mode})
        elif path.is_file():
            entries.append({"path": relative, "type": "file", "mode": mode, "size": path.stat().st_size, "sha256": sha256_file(path)})
        else:
            raise PackageError(f"unsupported file type in app bundle: {relative}")
    return entries


def bundle_tree_sha256(bundle):
    payload = json.dumps(bundle_tree_entries(bundle), sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def check_quarantine_metadata(bundle):
    xattr = Path("/usr/bin/xattr")
    if not xattr.is_file():
        raise PackageError("cannot verify quarantine metadata because /usr/bin/xattr is unavailable")
    for path in bundle_paths(bundle):
        result = subprocess.run([str(xattr), "-p", "-s", "com.apple.quarantine", str(path)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if result.returncode == 0:
            raise PackageError("app bundle contains quarantine metadata; refusing to create an archive that cannot preserve it")
        if "No such xattr: com.apple.quarantine" not in result.stderr:
            raise PackageError(f"cannot verify quarantine metadata for {path}: {result.stderr.strip()}")


def read_plist(path):
    try:
        with path.open("rb") as source:
            return plistlib.load(source)
    except (OSError, plistlib.InvalidFileException) as error:
        raise PackageError(f"cannot read bundle metadata: {path}") from error


def read_source_info_bytes(root):
    try:
        return (root / "Resources/Info.plist").read_bytes()
    except OSError as error:
        raise PackageError("cannot read clean-source Resources/Info.plist") from error


def read_source_info(root):
    try:
        return plistlib.loads(read_source_info_bytes(root))
    except plistlib.InvalidFileException as error:
        raise PackageError("clean-source Resources/Info.plist is invalid") from error


def validate_built_app_bundle(app, source_info):
    try:
        bundle = app.expanduser().resolve(strict=True)
    except OSError as error:
        raise PackageError(f"built app does not exist: {app}") from error
    if not bundle.is_dir() or bundle.name != "imrse.app":
        raise PackageError("--app must name an existing imrse.app bundle")
    info_path = bundle / "Contents/Info.plist"
    executable_path = bundle / "Contents/MacOS/imrse"
    if not info_path.is_file() or not executable_path.is_file():
        raise PackageError("built app is missing Contents/Info.plist or Contents/MacOS/imrse")
    info = read_plist(info_path)
    if info.get("CFBundleIdentifier") != EXPECTED_BUNDLE_ID or info.get("CFBundleExecutable") != "imrse":
        raise PackageError("built app bundle identity does not match the expected imrse app")
    validate_app_version_metadata(info, source_info)
    validate_symlinks(bundle)
    return bundle, info


def read_pins(root):
    try:
        data = json.loads((root / "Package.resolved").read_text())
        pins = {pin["identity"]: {"version": pin["state"]["version"], "revision": pin["state"]["revision"]} for pin in data["pins"]}
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise PackageError("cannot read pinned dependency inventory from Package.resolved") from error
    for identity, version, revision, _, _ in (*RUNTIME_DEPENDENCIES, *C_RUNTIME_DEPENDENCIES):
        if pins.get(identity) != {"version": version, "revision": revision}:
            raise PackageError(f"runtime dependency pin changed: {identity}")
    return pins


def validate_app_version_metadata(candidate_info, source_info):
    if source_info.get("CFBundleShortVersionString") != EXPECTED_APP_VERSION or source_info.get("CFBundleVersion") != EXPECTED_BUILD_VERSION:
        raise PackageError("clean-source Resources/Info.plist must define app version 0.2.0 build 13")
    if source_info.get("CFBundleIdentifier") != EXPECTED_BUNDLE_ID:
        raise PackageError("clean-source Info.plist has an unexpected bundle identifier")
    if source_info.get("LSMinimumSystemVersion") != EXPECTED_MINIMUM_OS:
        raise PackageError("clean-source Info.plist must retain the declared macOS 14.0 minimum")
    if candidate_info != source_info:
        raise PackageError("built app Info.plist does not match the declared clean-source Info.plist")


def validate_no_bundled_user_data(bundle):
    for path in bundle_paths(bundle):
        if path == bundle:
            continue
        relative = path.relative_to(bundle)
        if any(part.lower() in FORBIDDEN_PATH_COMPONENTS for part in relative.parts):
            raise PackageError(f"user data or presets must not be bundled: {relative}")
        if path.suffix.lower() in FORBIDDEN_SUFFIXES or path.name.lower() in FORBIDDEN_FILE_NAMES:
            raise PackageError(f"model weight or configuration file must not be bundled: {relative}")


def validate_required_resources(bundle, root):
    resources = bundle / "Contents/Resources"
    required = [
        resources / "IMRSE-LICENSE.txt",
        resources / "THIRD_PARTY_NOTICES.md",
        resources / "PillKit-Source-Dependency-Notice.md",
        resources / "AgentElements-LICENSE",
        resources / "ThirdPartyLicenses" / MLX_CORE_LICENSE,
        resources / "imrse_ImrseLocal.bundle/Contents/Resources/Qwen3-APACHE-LICENSE.txt",
    ]
    required.extend(resources / "ThirdPartyLicenses" / dependency[4] for dependency in (*RUNTIME_DEPENDENCIES, *C_RUNTIME_DEPENDENCIES))
    for path in required:
        if not path.is_file() or path.stat().st_size == 0:
            raise PackageError(f"required license or notice is missing: {path.relative_to(bundle)}")
    checks = (
        (resources / "IMRSE-LICENSE.txt", root / "LICENSE", "project MIT license"),
        (resources / "PillKit-Source-Dependency-Notice.md", root / "pill-kit/THIRD_PARTY_NOTICES.md", "original pill-kit source notice"),
        (resources / "AgentElements-LICENSE", root / "pill-kit/upstream/LICENSE", "Agent Elements license"),
        (resources / "THIRD_PARTY_NOTICES.md", root / "Resources/THIRD_PARTY_NOTICES.md", "runtime notice"),
    )
    for packaged, source, label in checks:
        if packaged.read_bytes() != source.read_bytes():
            raise PackageError(f"packaged {label} differs from its source")
    notice = (resources / "THIRD_PARTY_NOTICES.md").read_text()
    for identity, _, _, modules, _ in RUNTIME_DEPENDENCIES:
        if identity not in notice or any(module not in notice for module in modules):
            raise PackageError(f"runtime notice omits module inventory for {identity}")
    for identity, version, revision, symbols, license_name in C_RUNTIME_DEPENDENCIES:
        evidence = (identity, version, revision, *symbols, license_name)
        if any(value not in notice for value in evidence):
            raise PackageError(f"runtime notice omits pinned C runtime inventory for {identity}")
    if MLX_CORE_LICENSE not in notice:
        raise PackageError("runtime notice omits the MLX core license")
    if not any(path.is_file() and path.stat().st_size for path in resources.rglob("default.metallib")):
        raise PackageError("the MLX default.metallib shader resource is missing")
    validate_no_bundled_user_data(bundle)


def reject_ci_validation_app(bundle):
    receipt = Path(bundle) / "Contents/Resources" / CI_VALIDATION_RECEIPT_FILE
    if os.path.lexists(receipt):
        raise PackageError("CI validation-only app cannot be signed, recorded as release provenance, or distributed")


def validate_ci_package_app(app, source_root, configuration):
    if configuration != "release":
        raise PackageError("CI package validation requires a Release build")
    source_root = Path(source_root)
    source_commit = run(["git", "rev-parse", "HEAD^{commit}"], cwd=source_root).strip()
    source_tree = run(["git", "rev-parse", "HEAD^{tree}"], cwd=source_root).strip()
    source_root = validate_source_checkout(source_root, source_commit, source_tree)
    source_info = read_source_info(source_root)
    bundle, info = validate_built_app_bundle(app, source_info)
    reject_ci_validation_app(bundle)
    validate_required_resources(bundle, source_root)
    resources = bundle / "Contents/Resources"
    if not any(path.is_file() and path.parent.name == "Brand" for path in resources.rglob("imrse-menubar-template.pdf")):
        raise PackageError("the packaged menu-bar template is missing")
    binaries = macho_files(bundle)
    main_binary = bundle / "Contents/MacOS/imrse"
    if not binaries or main_binary not in binaries:
        raise PackageError("CI package validation requires the main Mach-O executable")
    host_architecture = {
        "arm64": "arm64",
        "aarch64": "arm64",
        "x86_64": "x86_64",
        "amd64": "x86_64",
    }.get(platform.machine().lower())
    if host_architecture is None:
        raise PackageError(f"CI package validation does not support host architecture {platform.machine()}")
    architectures = {}
    for binary in binaries:
        actual_architectures = macho_architectures(binary)
        if actual_architectures != {host_architecture}:
            raise PackageError(f"built Mach-O architecture does not match the {host_architecture} CI host: {binary.relative_to(bundle)}")
        architectures[binary.relative_to(bundle).as_posix()] = host_architecture
    read_pins(source_root)
    runtime_modules = validate_runtime_modules(main_binary, host_architecture)
    runtime_symbols = validate_runtime_symbols(main_binary, host_architecture)
    receipt_path = resources / CI_VALIDATION_RECEIPT_FILE
    receipt = {
        "schemaVersion": 1,
        "validationMode": "unsigned-ci-package-validation-only",
        "distributionEligible": False,
        "codeSigningPerformed": False,
        "signingCertificateSHA1": None,
        "signatureReceipt": None,
        "releaseBuildProvenanceCreated": False,
        "provenanceScope": "CI validation receipt only; not a release record or compiler attestation",
        "source": {"commitSHA": source_commit, "treeSHA": source_tree},
        "product": {
            "bundleIdentifier": info["CFBundleIdentifier"],
            "version": info["CFBundleShortVersionString"],
            "build": info["CFBundleVersion"],
            "executableSHA256": sha256_file(main_binary),
            "infoPlistSHA256": sha256_file(bundle / "Contents/Info.plist"),
            "hostArchitecture": host_architecture,
            "machoArchitectures": architectures,
        },
        "checks": {
            "cleanCommittedSourceAndVersionMatch": "passed",
            "runtimeModulesMatchedToPackageResolved": sorted(runtime_modules),
            "runtimeCExportedSymbolsMatchedToPackageResolved": sorted(runtime_symbols),
            "requiredResourcesAndLegalNotices": "passed",
            "menuBarTemplateAndMetalShaderResources": "passed",
        },
        "limitations": [
            "No code signature, signer receipt, or Release build provenance was created.",
            "This validation-only output is not eligible for candidate packaging or distribution.",
        ],
    }
    with receipt_path.open("x") as destination:
        destination.write(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return receipt_path


def runtime_modules_from_binary(binary, architecture="arm64"):
    raw = run(["nm", "-arch", architecture, "-j", str(binary)])
    symbols = [line[1:] if line.startswith("_$s") else line for line in raw.splitlines() if line.startswith(("$s", "_$s"))]
    if not symbols:
        raise PackageError(f"could not read Swift symbol modules from the {architecture} executable")
    demangled = run(["xcrun", "swift-demangle"], input_text="\n".join(symbols))
    expected = {module for dependency in RUNTIME_DEPENDENCIES for module in dependency[3]}
    lines = demangled.splitlines()
    return {module for module in expected if any(re.search(rf"\b{re.escape(module)}\.", line) for line in lines)}


def validate_runtime_modules(binary, architecture="arm64"):
    observed = runtime_modules_from_binary(binary, architecture)
    expected = {module for dependency in RUNTIME_DEPENDENCIES for module in dependency[3]}
    missing = sorted(expected - observed)
    if missing:
        raise PackageError(f"{architecture} executable is missing expected runtime module symbols: {', '.join(missing)}")
    return expected


def validate_runtime_symbols(binary, architecture="arm64"):
    observed = set(run(["nm", "-arch", architecture, "-gU", "-j", str(binary)]).splitlines())
    expected = {symbol for dependency in C_RUNTIME_DEPENDENCIES for symbol in dependency[3]}
    missing = sorted(expected - observed)
    if missing:
        raise PackageError(f"{architecture} executable is missing expected C runtime symbols: {', '.join(missing)}")
    return expected


def is_macho(path):
    try:
        with path.open("rb") as source:
            return source.read(4) in MACHO_MAGICS
    except OSError:
        return False


def macho_files(bundle):
    return [
        path
        for path in bundle_paths(bundle)
        if not path.is_symlink() and path.is_file() and is_macho(path)
    ]


def architecture_set_is_arm64_only(architectures):
    if "arm64" not in architectures:
        raise PackageError("bundled Mach-O has no arm64 slice")
    return architectures == {"arm64"}


def macho_architectures(path):
    return set(run(["lipo", "-archs", str(path)]).strip().split())


def thin_bundle_to_arm64(bundle):
    binaries = macho_files(bundle)
    if not binaries:
        raise PackageError("app bundle contains no Mach-O executable")
    for binary in binaries:
        architectures = macho_architectures(binary)
        if architecture_set_is_arm64_only(architectures):
            continue
        temporary = binary.with_name(f".{binary.name}.arm64")
        run(["lipo", "-thin", "arm64", str(binary), "-output", str(temporary)])
        os.chmod(temporary, stat.S_IMODE(binary.stat().st_mode))
        os.replace(temporary, binary)
        if not architecture_set_is_arm64_only(macho_architectures(binary)):
            raise PackageError(f"failed to produce an arm64-only Mach-O: {binary.relative_to(bundle)}")
    return binaries


def normalize_certificate_sha1(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", value):
        raise PackageError("a caller-selected 40-hex certificate SHA-1 is required")
    return value.lower()


def code_signature_metadata(path, certificate_sha1, *, deep=False, expected_identifier=None):
    certificate_sha1 = normalize_certificate_sha1(certificate_sha1)
    requirement = f'certificate leaf H"{certificate_sha1}"'
    verification = ["codesign", "--verify", "--strict"]
    if deep:
        verification.append("--deep")
    verification.extend((f"-R={requirement}", str(path)))
    run(verification)
    details = run(["codesign", "-dv", "--verbose=4", str(path)])
    if any(line.strip() == "Signature=adhoc" for line in details.splitlines()):
        raise PackageError(f"code signature is ad-hoc: {path}")
    identifiers = [line.partition("=")[2].strip() for line in details.splitlines() if line.startswith("Identifier=")]
    if len(identifiers) != 1 or not identifiers[0]:
        raise PackageError(f"code signature identifier is missing or ambiguous: {path}")
    identifier = identifiers[0]
    if expected_identifier is not None and identifier != expected_identifier:
        raise PackageError(f"code signature identifier does not match {expected_identifier}: {path}")
    requirement_output = run(["codesign", "-d", "-r-", str(path)])
    designated_requirements = re.findall(r"(?m)^[ \t]*#?[ \t]*designated =>[ \t]*(.+?)[ \t]*$", requirement_output)
    if len(designated_requirements) != 1 or not designated_requirements[0].strip():
        raise PackageError(f"code signature default designated requirement is missing or ambiguous: {path}")
    return {
        "certificateSHA1": certificate_sha1,
        "signatureType": "certificate-signed",
        "identifier": identifier,
        "defaultDesignatedRequirement": designated_requirements[0].strip(),
    }


def verify_bundle_signature_receipt(bundle, certificate_sha1, binaries=None):
    bundle_path = Path(bundle)
    if bundle_path.is_symlink() or not bundle_path.is_dir():
        raise PackageError("signed app bundle must be a real directory")
    bundle = bundle_path.resolve(strict=True)
    certificate_sha1 = normalize_certificate_sha1(certificate_sha1)
    discovered_code_paths = set(macho_files(bundle))
    code_paths = list(discovered_code_paths if binaries is None else binaries)
    if binaries is not None and set(code_paths) != discovered_code_paths:
        raise PackageError("signature verification must include every bundled Mach-O")
    main_binary = bundle / "Contents/MacOS/imrse"
    if not main_binary.is_file() or not is_macho(main_binary) or main_binary not in code_paths:
        raise PackageError("signed app bundle must contain its main Mach-O executable")
    code_paths = sorted(set(code_paths), key=lambda path: path.relative_to(bundle).as_posix())
    if not code_paths or main_binary not in code_paths:
        raise PackageError("signed app bundle must contain its main executable and at least one code item")
    for path in code_paths:
        if path.is_symlink() or not path.is_file() or not path.resolve(strict=True).is_relative_to(bundle):
            raise PackageError(f"signed code item must be a real file inside the app bundle: {path}")
    bundle_receipt = code_signature_metadata(
        bundle,
        certificate_sha1,
        deep=True,
        expected_identifier=EXPECTED_BUNDLE_ID,
    )
    code_receipts = [
        {
            "relativePath": path.relative_to(bundle).as_posix(),
            **code_signature_metadata(path, certificate_sha1),
        }
        for path in code_paths
    ]
    return {
        "certificateSHA1": certificate_sha1,
        "signatureType": "certificate-signed",
        "bundle": bundle_receipt,
        "codeItems": code_receipts,
    }


def sign_and_verify(bundle, binaries, certificate_sha1):
    bundle_path = Path(bundle)
    if bundle_path.is_symlink() or not bundle_path.is_dir():
        raise PackageError("signed app bundle must be a real directory")
    bundle = bundle_path.resolve(strict=True)
    certificate_sha1 = normalize_certificate_sha1(certificate_sha1)
    binary_paths = [Path(binary) for binary in binaries]
    if any(binary.is_symlink() or not binary.is_file() for binary in binary_paths):
        raise PackageError("signing must cover every real Mach-O inside the staged app bundle")
    binaries = [binary.resolve(strict=True) for binary in binary_paths]
    if (
        len(set(binaries)) != len(binaries)
        or set(binaries) != set(macho_files(bundle))
        or (bundle / "Contents/MacOS/imrse") not in binaries
        or any(not binary.is_relative_to(bundle) for binary in binaries)
    ):
        raise PackageError("signing must cover every real Mach-O inside the staged app bundle")
    for binary in binaries:
        run(["codesign", "--force", "--sign", certificate_sha1, "--timestamp=none", str(binary)])
    run(["codesign", "--force", "--sign", certificate_sha1, "--timestamp=none", str(bundle)])
    return verify_bundle_signature_receipt(bundle, certificate_sha1, binaries)


def sign_app_bundle(bundle, certificate_sha1):
    reject_ci_validation_app(bundle)
    validate_symlinks(bundle)
    return sign_and_verify(bundle, macho_files(bundle), certificate_sha1)


def app_license_hashes(bundle):
    resources = bundle / "Contents/Resources"
    paths = [path for path in resources.rglob("*") if path.is_file() and ("LICENSE" in path.name.upper() or "NOTICE" in path.name.upper() or path.parent.name == "ThirdPartyLicenses")]
    return {path.relative_to(bundle).as_posix(): sha256_file(path) for path in sorted(paths)}


def validate_source_checkout(root, source_commit, source_tree):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise PackageError("source checkout must be a real directory")
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit) or not re.fullmatch(r"[0-9a-f]{40}", source_tree):
        raise PackageError("source commit and tree must be full lowercase Git object ids")
    root = root.resolve(strict=True)
    top = Path(run(["git", "rev-parse", "--show-toplevel"], cwd=root).strip()).resolve(strict=True)
    if top != root:
        raise PackageError("source root must be the Git worktree root")
    head = run(["git", "rev-parse", "--verify", "HEAD^{commit}"], cwd=root).strip()
    actual_tree = run(["git", "rev-parse", "--verify", f"{source_commit}^{{tree}}"], cwd=root).strip()
    if head != source_commit or actual_tree != source_tree:
        raise PackageError("source checkout does not match the declared commit and tree")
    if run(["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=root).strip():
        raise PackageError("source worktree must be clean before packaging")
    return root


def source_git_files(root, source_commit):
    result = subprocess.run(
        ["git", "ls-tree", "-rz", "--full-tree", source_commit],
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode:
        raise PackageError(f"git ls-tree failed ({result.returncode}): {result.stderr.decode(errors='replace').strip()}")
    records = []
    for record in result.stdout.split(b"\0"):
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, kind, object_id = metadata.decode("ascii").split()
        relative = PurePosixPath(os.fsdecode(raw_path))
        if relative.is_absolute() or not relative.parts or any(part in ("", ".", "..") for part in relative.parts):
            raise PackageError("Git tree contains an unsafe source path")
        if kind != "blob" or mode not in {"100644", "100755", "120000"}:
            raise PackageError(f"unsupported tracked source entry: {relative.as_posix()} ({mode} {kind})")
        if not re.fullmatch(r"[0-9a-f]{40}", object_id):
            raise PackageError(f"invalid Git blob id for tracked source entry: {relative.as_posix()}")
        records.append((relative, mode, object_id, root.joinpath(*relative.parts)))

    blob_contents = git_blob_contents(root, (object_id for _, _, object_id, _ in records))
    files = []
    for relative, mode, object_id, path in records:
        try:
            actual_mode = path.lstat().st_mode
            if mode == "120000":
                if not stat.S_ISLNK(actual_mode):
                    raise PackageError(f"tracked source symlink is missing: {relative.as_posix()}")
                entry_kind = "symlink"
            else:
                if not stat.S_ISREG(actual_mode):
                    raise PackageError(f"tracked source file is not a regular file: {relative.as_posix()}")
                executable = bool(stat.S_IMODE(actual_mode) & 0o111)
                if executable != (mode == "100755"):
                    raise PackageError(f"tracked source executable mode differs from Git: {relative.as_posix()}")
                entry_kind = "file"
            content = verify_source_blob(path, relative.as_posix(), mode, object_id, blob_contents[object_id])
            entry = {"path": relative.as_posix(), "kind": entry_kind, "gitMode": mode, "gitBlobSHA": object_id, "mode": stat.S_IMODE(actual_mode), "size": len(content), "sha256": hashlib.sha256(content).hexdigest()}
        except OSError as error:
            raise PackageError(f"cannot inspect tracked source input: {relative.as_posix()}") from error
        files.append(entry)
    return sorted(files, key=lambda entry: entry["path"])


def git_blob_contents(root, object_ids):
    object_ids = sorted(set(object_ids))
    if not object_ids:
        return {}
    result = subprocess.run(
        ["git", "cat-file", "--batch"],
        cwd=root,
        input=b"".join(object_id.encode("ascii") + b"\n" for object_id in object_ids),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode:
        raise PackageError(f"git cat-file failed ({result.returncode}): {result.stderr.decode(errors='replace').strip()}")
    contents = {}
    offset = 0
    for object_id in object_ids:
        header_end = result.stdout.find(b"\n", offset)
        if header_end < 0:
            raise PackageError("git cat-file returned a truncated blob stream")
        header = result.stdout[offset:header_end].split()
        if len(header) != 3 or header[0].decode("ascii", errors="replace") != object_id or header[1] != b"blob":
            raise PackageError(f"git cat-file did not return the expected source blob: {object_id}")
        try:
            size = int(header[2])
        except ValueError as error:
            raise PackageError(f"git cat-file returned an invalid blob size: {object_id}") from error
        start = header_end + 1
        end = start + size
        if end >= len(result.stdout) or result.stdout[end:end + 1] != b"\n":
            raise PackageError(f"git cat-file returned a truncated source blob: {object_id}")
        content = result.stdout[start:end]
        if git_blob_sha1(content) != object_id:
            raise PackageError(f"git blob content does not match its object id: {object_id}")
        contents[object_id] = content
        offset = end + 1
    if offset != len(result.stdout):
        raise PackageError("git cat-file returned unexpected trailing blob data")
    return contents


def git_blob_sha1(content):
    header = b"blob " + str(len(content)).encode("ascii") + b"\0"
    return hashlib.sha1(header + content).hexdigest()


def verify_source_blob(path, relative, git_mode, object_id, committed_blob):
    content = os.fsencode(os.readlink(path)) if git_mode == "120000" else path.read_bytes()
    if content != committed_blob or git_blob_sha1(content) != object_id:
        raise PackageError(f"tracked source content differs from committed Git blob: {relative}")
    return content


def source_input_manifest(root, source_commit, source_tree):
    root = validate_source_checkout(root, source_commit, source_tree)
    return {
        "schemaVersion": 1,
        "repository": "exterminatorrat/imrse",
        "sourceCommitSHA": source_commit,
        "sourceTreeSHA": source_tree,
        "files": source_git_files(root, source_commit),
    }


def canonical_build_root(path, source_root):
    path = Path(path).expanduser()
    if not path.is_absolute() or path.is_symlink():
        raise PackageError("build root must be an absolute, non-symlink path")
    parent = path.parent.resolve(strict=True)
    if not parent.is_dir():
        raise PackageError("build root parent must be an existing directory")
    resolved = parent / path.name
    if resolved == source_root or resolved.is_relative_to(source_root) or source_root.is_relative_to(resolved):
        raise PackageError("build root must be separate from the source checkout")
    return resolved


def copy_source_inputs(root, source_commit, source_tree, build_root):
    source_root = validate_source_checkout(root, source_commit, source_tree)
    build_root = canonical_build_root(build_root, source_root)
    build_root_exists = os.path.lexists(build_root)
    if build_root_exists:
        if build_root.is_symlink() or not build_root.is_dir():
            raise PackageError("build root must be a real directory when it already exists")
    copy_root = build_root / "source"
    manifest_path = build_root / SOURCE_INPUT_MANIFEST_FILE
    if os.path.lexists(copy_root) or os.path.lexists(manifest_path):
        raise PackageError("build root already contains a source copy or manifest; refusing to overwrite")
    manifest = source_input_manifest(source_root, source_commit, source_tree)
    if not build_root_exists:
        build_root.mkdir(mode=0o700)
    copy_root.mkdir(mode=0o700)
    for entry in manifest["files"]:
        relative = PurePosixPath(entry["path"])
        source_path = source_root.joinpath(*relative.parts)
        destination = copy_root.joinpath(*relative.parts)
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if entry["kind"] == "symlink":
            os.symlink(os.readlink(source_path), destination)
        else:
            shutil.copy2(source_path, destination, follow_symlinks=False)
    validate_source_copy(source_root, copy_root, manifest, source_commit, source_tree)
    with manifest_path.open("x") as destination:
        destination.write(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return copy_root, manifest_path


def validate_source_copy(root, copy_root, manifest, source_commit, source_tree):
    source_root = validate_source_checkout(root, source_commit, source_tree)
    copy_root = Path(copy_root)
    if copy_root.is_symlink() or not copy_root.is_dir():
        raise PackageError("source input copy must be a real directory")
    copy_root = copy_root.resolve(strict=True)
    if copy_root == source_root or copy_root.is_relative_to(source_root) or source_root.is_relative_to(copy_root):
        raise PackageError("source input copy must be separate from the source checkout")
    expected = source_input_manifest(source_root, source_commit, source_tree)
    if manifest != expected:
        raise PackageError("source input manifest does not match the clean committed source tree")
    expected_by_path = {entry["path"]: entry for entry in manifest["files"]}
    actual_files = set()
    actual_directories = set()
    for directory, names, files in os.walk(copy_root, followlinks=False):
        names.sort()
        files.sort()
        parent = Path(directory)
        for name in list(names):
            path = parent / name
            relative = path.relative_to(copy_root).as_posix()
            if path.is_symlink():
                actual_files.add(relative)
                names.remove(name)
            else:
                actual_directories.add(relative)
        actual_files.update((parent / name).relative_to(copy_root).as_posix() for name in files)
    expected_directories = {
        parent.as_posix()
        for entry in manifest["files"]
        for parent in PurePosixPath(entry["path"]).parents
        if parent != PurePosixPath(".")
    }
    if actual_files != set(expected_by_path) or actual_directories != expected_directories:
        raise PackageError("source input copy contains missing or unexpected filesystem entries")
    validate_symlinks(copy_root)
    for relative, entry in expected_by_path.items():
        source_path = source_root.joinpath(*PurePosixPath(relative).parts)
        copied_path = copy_root.joinpath(*PurePosixPath(relative).parts)
        try:
            if os.path.samefile(source_path, copied_path):
                raise PackageError(f"source input copy reuses a source filesystem object: {relative}")
            mode = copied_path.lstat().st_mode
            if entry["kind"] == "symlink":
                if not stat.S_ISLNK(mode) or os.readlink(copied_path) != os.readlink(source_path):
                    raise PackageError(f"source input symlink differs from its manifest: {relative}")
                content = os.fsencode(os.readlink(copied_path))
            else:
                if not stat.S_ISREG(mode) or stat.S_IMODE(mode) != entry["mode"]:
                    raise PackageError(f"source input file type or mode differs from its manifest: {relative}")
                content = copied_path.read_bytes()
            if len(content) != entry["size"] or hashlib.sha256(content).hexdigest() != entry["sha256"]:
                raise PackageError(f"source input content differs from its manifest: {relative}")
        except OSError as error:
            raise PackageError(f"cannot verify copied source input: {relative}") from error
    return copy_root


def read_source_input_manifest(path):
    if path.is_symlink() or not path.is_file():
        raise PackageError("source input manifest must be a regular file")
    try:
        manifest = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise PackageError("cannot read source input manifest") from error
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 1:
        raise PackageError("unsupported source input manifest schema")
    return manifest


def expected_release_build_command(build_root):
    return [
        "swift",
        "build",
        "--build-system",
        "swiftbuild",
        "--configuration",
        "release",
        "--scratch-path",
        str(build_root / "scratch"),
        "--cache-path",
        str(build_root / "cache"),
        "--config-path",
        str(build_root / "configuration"),
        "--security-path",
        str(build_root / "security"),
        "--only-use-versions-from-resolved-file",
        "--product",
        "imrse",
    ]


def normalized_release_build_command():
    return [
        "swift",
        "build",
        "--build-system",
        "swiftbuild",
        "--configuration",
        "release",
        "--scratch-path",
        "scratch",
        "--cache-path",
        "cache",
        "--config-path",
        "configuration",
        "--security-path",
        "security",
        "--only-use-versions-from-resolved-file",
        "--product",
        "imrse",
    ]


def record_build_provenance(root, source_commit, source_tree, build_root, working_directory, build_command, signing_certificate_sha1):
    signing_certificate_sha1 = normalize_certificate_sha1(signing_certificate_sha1)
    source_root = validate_source_checkout(root, source_commit, source_tree)
    build_root = canonical_build_root(build_root, source_root)
    if build_root.is_symlink() or not build_root.is_dir():
        raise PackageError("build root must be an existing real directory")
    manifest_path = build_root / SOURCE_INPUT_MANIFEST_FILE
    manifest = read_source_input_manifest(manifest_path)
    copy_root = build_root / "source"
    validate_source_copy(source_root, copy_root, manifest, source_commit, source_tree)
    if build_command != expected_release_build_command(build_root):
        raise PackageError("builder command does not match the exact isolated Release invocation")
    try:
        actual_working_directory = Path(working_directory).resolve(strict=True)
        expected_working_directory = copy_root.resolve(strict=True)
    except OSError as error:
        raise PackageError("builder working directory or copied source is missing") from error
    if actual_working_directory != expected_working_directory:
        raise PackageError("builder working directory must be the isolated copied source")
    product = build_root / "products/imrse.app"
    if product.is_symlink() or not product.is_dir():
        raise PackageError("fresh Release product app is missing or is not a real directory")
    product = product.resolve(strict=True)
    if not product.is_relative_to(build_root):
        raise PackageError("built product must remain inside the isolated build root")
    reject_ci_validation_app(product)
    source_info = read_source_info(source_root)
    product_info = read_plist(product / "Contents/Info.plist")
    if product_info != source_info:
        raise PackageError("built app Info.plist does not match clean source")
    validate_symlinks(product)
    signature_receipt = verify_bundle_signature_receipt(product, signing_certificate_sha1)
    record = {
        "schemaVersion": 4,
        "repository": "exterminatorrat/imrse",
        "sourceCommitSHA": source_commit,
        "sourceTreeSHA": source_tree,
        "sourceInputManifest": {"fileName": SOURCE_INPUT_MANIFEST_FILE, "sha256": sha256_file(manifest_path)},
        "inputCopyRelativePath": "source",
        "buildInputs": {
            "lockFilesSHA256": {path: sha256_file(source_root / path) for path in LOCK_FILES},
            "resolvedDependencyPins": read_pins(source_root),
        },
        "build": {
            "configuration": "release",
            "workingDirectoryRelativePath": "source",
            "command": normalized_release_build_command(),
            "commandPathValuesRelativeToBuildRoot": True,
            "signingCertificateSHA1": signing_certificate_sha1,
            "provenanceScope": "local builder-supplied invocation metadata and product hashes; not an independent compiler attestation",
        },
        "product": {
            "relativePath": "products/imrse.app",
            "bundleTreeSHA256": bundle_tree_sha256(product),
            "executableSHA256": sha256_file(product / "Contents/MacOS/imrse"),
            "infoPlistSHA256": sha256_file(product / "Contents/Info.plist"),
            "signatureReceipt": signature_receipt,
        },
    }
    provenance_path = build_root / BUILD_PROVENANCE_FILE
    if os.path.lexists(provenance_path):
        raise PackageError("build provenance already exists; refusing to overwrite")
    with provenance_path.open("x") as destination:
        destination.write(json.dumps(record, indent=2, sort_keys=True) + "\n")
    return provenance_path


def validate_build_provenance(provenance_path, root, product, expected_build_root, source_commit, source_tree, signing_certificate_sha1):
    signing_certificate_sha1 = normalize_certificate_sha1(signing_certificate_sha1)
    source_root = validate_source_checkout(root, source_commit, source_tree)
    build_root = canonical_build_root(expected_build_root, source_root)
    if provenance_path.is_symlink() or not provenance_path.is_file():
        raise PackageError("build provenance must be a regular file")
    try:
        record = json.loads(provenance_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise PackageError("cannot read clean-source build provenance") from error
    if record.get("schemaVersion") != 4 or record.get("repository") != "exterminatorrat/imrse":
        raise PackageError("unsupported clean-source build provenance schema")
    manifest_path = build_root / SOURCE_INPUT_MANIFEST_FILE
    manifest = read_source_input_manifest(manifest_path)
    copy_root = build_root / "source"
    validate_source_copy(source_root, copy_root, manifest, source_commit, source_tree)
    if (
        record.get("sourceCommitSHA") != source_commit
        or record.get("sourceTreeSHA") != source_tree
        or record.get("inputCopyRelativePath") != "source"
        or record.get("sourceInputManifest") != {"fileName": SOURCE_INPUT_MANIFEST_FILE, "sha256": sha256_file(manifest_path)}
    ):
        raise PackageError("build provenance does not match the validated source input copy")
    expected_locks = {path: sha256_file(source_root / path) for path in LOCK_FILES}
    build_inputs = record.get("buildInputs", {})
    if build_inputs.get("lockFilesSHA256") != expected_locks or build_inputs.get("resolvedDependencyPins") != read_pins(source_root):
        raise PackageError("build provenance dependency locks or pins do not match clean source")
    build = record.get("build", {})
    if (
        build.get("configuration") != "release"
        or build.get("workingDirectoryRelativePath") != "source"
        or build.get("command") != normalized_release_build_command()
        or build.get("commandPathValuesRelativeToBuildRoot") is not True
        or build.get("signingCertificateSHA1") != signing_certificate_sha1
        or build.get("provenanceScope")
        != "local builder-supplied invocation metadata and product hashes; not an independent compiler attestation"
    ):
        raise PackageError("build provenance does not match the isolated Release builder record")
    product_record = record.get("product", {})
    expected_product = build_root / "products/imrse.app"
    try:
        product_path = Path(product).resolve(strict=True)
    except OSError as error:
        raise PackageError("fresh Release product app is missing") from error
    reject_ci_validation_app(product_path)
    if (
        product_path != expected_product.resolve(strict=True)
        or product_record.get("relativePath") != "products/imrse.app"
        or product_record.get("bundleTreeSHA256") != bundle_tree_sha256(product_path)
        or product_record.get("executableSHA256") != sha256_file(product_path / "Contents/MacOS/imrse")
        or product_record.get("infoPlistSHA256") != sha256_file(product_path / "Contents/Info.plist")
    ):
        raise PackageError("built product path or hashes do not match the recorded output")
    if read_plist(product_path / "Contents/Info.plist") != read_source_info(source_root):
        raise PackageError("built product metadata no longer matches clean source")
    actual_signature_receipt = verify_bundle_signature_receipt(product_path, signing_certificate_sha1)
    if product_record.get("signatureReceipt") != actual_signature_receipt:
        raise PackageError("built product signature receipt does not match the verified signer and public signature metadata")
    return record


def create_zip(bundle, destination):
    validate_symlinks(bundle)
    paths = sorted(bundle_paths(bundle), key=lambda item: item.relative_to(bundle.parent).as_posix())
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
        for path in paths:
            relative = path.relative_to(bundle.parent).as_posix()
            info = zipfile.ZipInfo(relative + ("/" if path.is_dir() and not path.is_symlink() else ""), ZIP_TIMESTAMP)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_STORED
            mode = path.lstat().st_mode
            if path.is_symlink():
                info.external_attr = ((stat.S_IFLNK | 0o777) << 16) | 0xA1FF0000
                archive.writestr(info, os.readlink(path).encode())
            elif path.is_dir():
                info.external_attr = ((stat.S_IFDIR | stat.S_IMODE(mode)) << 16) | 0x10
                archive.writestr(info, b"")
            else:
                info.external_attr = (stat.S_IFREG | stat.S_IMODE(mode)) << 16
                with path.open("rb") as source:
                    archive.writestr(info, source.read())


def candidate_manifest(root, source, source_tree_hash, bundle, archive_hash, archive_size, runtime_modules, runtime_symbols, regression_output, build_record, build_record_hash, source_commit, source_tree, input_manifest_hash, candidate_signature_receipt):
    source_info = read_source_info(root)
    candidate_info = read_plist(bundle / "Contents/Info.plist")
    validate_app_version_metadata(candidate_info, source_info)
    pins = read_pins(root)
    runtime = []
    for identity, _, _, modules, license_name in RUNTIME_DEPENDENCIES:
        license_path = bundle / "Contents/Resources/ThirdPartyLicenses" / license_name
        runtime.append({
            "package": identity,
            "version": pins[identity]["version"],
            "revision": pins[identity]["revision"],
            "modules": list(modules),
            "licenseResource": f"Contents/Resources/ThirdPartyLicenses/{license_name}",
            "licenseSHA256": sha256_file(license_path),
        })
    for identity, _, _, symbols, license_name in C_RUNTIME_DEPENDENCIES:
        license_path = bundle / "Contents/Resources/ThirdPartyLicenses" / license_name
        runtime.append({
            "package": identity,
            "version": pins[identity]["version"],
            "revision": pins[identity]["revision"],
            "modules": [],
            "binarySymbols": list(symbols),
            "licenseResource": f"Contents/Resources/ThirdPartyLicenses/{license_name}",
            "licenseSHA256": sha256_file(license_path),
        })
    build = build_record["build"]
    signing_certificate_sha1 = normalize_certificate_sha1(build.get("signingCertificateSHA1"))
    product_record = build_record.get("product")
    if not isinstance(product_record, dict):
        raise PackageError("build product signature receipt is missing")
    build_signature_receipt = product_record.get("signatureReceipt")
    for receipt in (build_signature_receipt, candidate_signature_receipt):
        code_items = receipt.get("codeItems") if isinstance(receipt, dict) else None
        if (
            not isinstance(receipt, dict)
            or receipt.get("certificateSHA1") != signing_certificate_sha1
            or receipt.get("signatureType") != "certificate-signed"
            or not isinstance(receipt.get("bundle"), dict)
            or receipt["bundle"].get("identifier") != EXPECTED_BUNDLE_ID
            or not isinstance(code_items, list)
            or not code_items
            or any(
                not isinstance(item, dict)
                or item.get("certificateSHA1") != signing_certificate_sha1
                or item.get("signatureType") != "certificate-signed"
                for item in code_items
            )
        ):
            raise PackageError("build and candidate signature receipts do not match the selected certificate")
    return {
        "schemaVersion": 4,
        "candidate": {
            "version": CANDIDATE_VERSION,
            "bundleVersion": candidate_info["CFBundleShortVersionString"],
            "build": candidate_info["CFBundleVersion"],
            "bundleIdentifier": candidate_info["CFBundleIdentifier"],
            "architecture": "arm64",
            "minimumMacOSDeclared": candidate_info["LSMinimumSystemVersion"],
            "runtimeTestedOS": None,
            "runtimeTestStatus": "not run; candidate was not launched or installed",
        },
        "source": {
            "repository": "exterminatorrat/imrse",
            "commitSHA": source_commit,
            "treeSHA": source_tree,
            "tag": None,
            "checkoutRequirement": "clean committed source whose HEAD and tree match these identifiers",
            "sourceInputCopy": {"buildRootRelativePath": "source", "manifestFile": SOURCE_INPUT_MANIFEST_FILE, "manifestSHA256": input_manifest_hash},
            "buildProduct": {
                "path": "products/imrse.app",
                "configuration": build["configuration"],
                "workingDirectoryRelativePath": build["workingDirectoryRelativePath"],
                "bundleTreeSHA256": source_tree_hash,
                "executableSHA256": sha256_file(source / "Contents/MacOS/imrse"),
                "version": source_info["CFBundleShortVersionString"],
                "build": source_info["CFBundleVersion"],
                "command": build["command"],
                "commandPathValuesRelativeToBuildRoot": build["commandPathValuesRelativeToBuildRoot"],
                "provenanceScope": build["provenanceScope"],
                "signatureReceipt": build_record["product"]["signatureReceipt"],
            },
            "buildProvenance": {"fileName": BUILD_PROVENANCE_FILE, "sha256": build_record_hash},
        },
        "artifact": {
            "archive": OUTPUT_NAME,
            "archiveSHA256": archive_hash,
            "archiveSizeBytes": archive_size,
            "archiveEncoding": "ZIP_STORED; sorted paths; fixed 1980-01-01 timestamps; Unix type/mode bits; symlinks are Unix symlink entries",
            "archiveRepeatHashMatched": "verified by a second archive pass",
            "appBundleTreeSHA256": bundle_tree_sha256(bundle),
            "appExecutableSHA256": sha256_file(bundle / "Contents/MacOS/imrse"),
        },
        "signing": {
            "certificateSHA1": build["signingCertificateSHA1"],
            "signatureType": CERTIFICATE_SIGNING_LABEL,
            "timestamp": "none",
            "developerID": False,
            "notarized": False,
            "hardenedRuntime": False,
            "publicTrustedRelease": False,
            "buildProductReceipt": build_record["product"]["signatureReceipt"],
            "candidateReceipt": candidate_signature_receipt,
        },
        "packagingHost": {
            "architecture": platform.machine(),
            "macOSVersion": platform.mac_ver()[0],
            "runtimeCompatibilityTest": "not performed",
        },
        "verification": {
            "cleanCommittedSourceAndTreeMatch": "verified before and after packaging",
            "sourceInputCopyMatchesGitTree": "verified by per-path file type, mode, size, content hashes, and filesystem identity",
            "buildProductMatchesRecordedHashes": "passed",
            "buildProductUnmodifiedDuringPackaging": "verified",
            "versionAndBuildMatchCleanSource": "passed",
            "arm64OnlyForAllBundledMachO": "passed",
            "runtimeModulesMatchedToPackageResolved": sorted(runtime_modules),
            "runtimeCExportedSymbolsMatchedToPackageResolved": sorted(runtime_symbols),
            "requiredResourcesAndLicenseHashes": "passed",
            "certificateSignatureSelectorMatchedForBuildAndCandidateCode": "passed",
            "deterministicArchiveRepeatedTwice": "passed",
            "packagingRegressionTests": regression_output.strip().splitlines()[-1] if regression_output.strip() else "passed",
            "intelRuntimeValidation": "not performed",
            "declaredMinimumOSRuntimeValidation": "not performed",
        },
        "licenseResourceSHA256": app_license_hashes(bundle),
        "runtimeDependencies": runtime,
        "limitations": [
            "This local beta candidate is certificate-signed and not notarized; no Developer ID, notarization, or trusted public distribution claim is made.",
            "Certificate presence alone does not establish persistence of Accessibility or Input Monitoring authorization after changed code; no TCC reuse claim is made without compatible designated-requirement and imrse-owned authorization evidence.",
            "The declared macOS minimum is 14.0; the candidate was not runtime-tested on that minimum.",
            "No live provider authentication, inference, physical selection/Undo smoke, clean-user install, or Intel validation was performed.",
            "Same-artifact ZIP repeatability does not establish reproducible compilation across toolchains.",
            "This manifest is packaging provenance, not a legal certification or public-distribution authorization.",
            "No application was launched or installed as part of packaging.",
        ],
    }


def publish_candidate_files(stage, output, names):
    linked = []
    output.mkdir(mode=0o700)
    try:
        for name in names:
            destination = output / name
            os.link(stage / name, destination)
            linked.append(name)
    except OSError as error:
        for name in linked:
            destination = output / name
            try:
                if os.path.samefile(destination, stage / name):
                    destination.unlink()
            except OSError:
                pass
        try:
            output.rmdir()
        except OSError:
            pass
        if isinstance(error, FileExistsError):
            raise PackageError("candidate output appeared during packaging; refusing to overwrite it") from error
        raise


def validate_independent_bundle_copy(source, copied):
    if bundle_tree_sha256(source) != bundle_tree_sha256(copied):
        raise PackageError("staged app does not match the built product before packaging changes")
    for path in bundle_paths(source):
        if path == source or not (path.is_file() or path.is_symlink()):
            continue
        relative = path.relative_to(source)
        if os.path.samefile(path, copied / relative):
            raise PackageError(f"staged app reuses a built-product filesystem object: {relative}")


def create_candidate(input_app, source_commit, source_tree, build_root, output, signing_certificate_sha1):
    signing_certificate_sha1 = normalize_certificate_sha1(signing_certificate_sha1)
    root = Path(__file__).resolve().parent.parent
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise PackageError("candidate packaging requires a macOS arm64 device")
    root = validate_source_checkout(root, source_commit, source_tree)
    build_root = canonical_build_root(build_root, root)
    output = Path(output).expanduser()
    if not output.is_absolute() or output.is_symlink() or os.path.lexists(output):
        raise PackageError("candidate output must be a new, absent absolute directory")
    output_parent = output.parent.resolve(strict=True)
    if not output_parent.is_dir():
        raise PackageError("candidate output parent must be an existing directory")
    output = output_parent / output.name
    if output == root or output.is_relative_to(root) or root.is_relative_to(output) or output == build_root or output.is_relative_to(build_root) or build_root.is_relative_to(output):
        raise PackageError("candidate output must be separate from source and build roots")
    if build_root.is_symlink() or not build_root.is_dir():
        raise PackageError("build root must be an existing real directory")
    expected_product = build_root / "products/imrse.app"
    if input_app.is_symlink() or input_app.expanduser().resolve(strict=True) != expected_product.resolve(strict=True):
        raise PackageError("--app must name the product inside the declared build root")
    provenance_path = build_root / BUILD_PROVENANCE_FILE
    manifest_path = build_root / SOURCE_INPUT_MANIFEST_FILE
    manifest = read_source_input_manifest(manifest_path)
    copy_root = build_root / "source"
    validate_source_copy(root, copy_root, manifest, source_commit, source_tree)
    source_info = read_source_info(root)
    validate_app_version_metadata(source_info, source_info)
    source, _ = validate_built_app_bundle(input_app, source_info)
    reject_ci_validation_app(source)
    source_tree_hash = bundle_tree_sha256(source)
    build_record = validate_build_provenance(provenance_path, root, source, build_root, source_commit, source_tree, signing_certificate_sha1)
    build_record_hash = sha256_file(provenance_path)
    input_manifest_hash = sha256_file(manifest_path)
    check_quarantine_metadata(source)
    read_pins(root)
    regression_output = run(
        [sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests", "-v"],
        cwd=root,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )
    try:
        with tempfile.TemporaryDirectory(prefix=".candidate-package-", dir=build_root) as temp_name:
            stage = Path(temp_name)
            staged_bundle = stage / "imrse.app"
            shutil.copytree(source, staged_bundle, symlinks=True, copy_function=shutil.copy2)
            validate_independent_bundle_copy(source, staged_bundle)
            check_quarantine_metadata(staged_bundle)
            validate_required_resources(staged_bundle, root)
            run(["plutil", "-lint", str(staged_bundle / "Contents/Info.plist")])
            binaries = thin_bundle_to_arm64(staged_bundle)
            runtime_modules = validate_runtime_modules(staged_bundle / "Contents/MacOS/imrse")
            runtime_symbols = validate_runtime_symbols(staged_bundle / "Contents/MacOS/imrse")
            candidate_signature_receipt = sign_and_verify(staged_bundle, binaries, signing_certificate_sha1)
            run(["plutil", "-lint", str(staged_bundle / "Contents/Info.plist")])
            first_zip = stage / "first.zip"
            second_zip = stage / "second.zip"
            create_zip(staged_bundle, first_zip)
            create_zip(staged_bundle, second_zip)
            archive_hash = sha256_file(first_zip)
            if archive_hash != sha256_file(second_zip):
                raise PackageError("repeat archive SHA-256 did not match")
            if bundle_tree_sha256(source) != source_tree_hash:
                raise PackageError("built product changed while candidate packaging was running")
            validate_source_checkout(root, source_commit, source_tree)
            validate_source_copy(root, copy_root, read_source_input_manifest(manifest_path), source_commit, source_tree)
            validate_build_provenance(provenance_path, root, source, build_root, source_commit, source_tree, signing_certificate_sha1)
            if sha256_file(provenance_path) != build_record_hash or sha256_file(manifest_path) != input_manifest_hash:
                raise PackageError("source input or build provenance changed during packaging")
            manifest_data = candidate_manifest(
                root,
                source,
                source_tree_hash,
                staged_bundle,
                archive_hash,
                first_zip.stat().st_size,
                runtime_modules,
                runtime_symbols,
                regression_output,
                build_record,
                build_record_hash,
                source_commit,
                source_tree,
                input_manifest_hash,
                candidate_signature_receipt,
            )
            os.link(first_zip, stage / OUTPUT_NAME)
            shutil.copy2(provenance_path, stage / BUILD_PROVENANCE_FILE)
            shutil.copy2(manifest_path, stage / SOURCE_INPUT_MANIFEST_FILE)
            manifest_path_out = stage / "MANIFEST.json"
            manifest_path_out.write_text(json.dumps(manifest_data, indent=2, sort_keys=True) + "\n")
            manifest_hash = sha256_file(manifest_path_out)
            sums_path = stage / "SHA256SUMS"
            sidecar_hashes = {
                OUTPUT_NAME: archive_hash,
                BUILD_PROVENANCE_FILE: build_record_hash,
                SOURCE_INPUT_MANIFEST_FILE: input_manifest_hash,
                "MANIFEST.json": manifest_hash,
            }
            sums_path.write_text("".join(f"{sidecar_hashes[name]}  {name}\n" for name in sorted(sidecar_hashes)))
            publish_candidate_files(stage, output, [*sorted(sidecar_hashes), "SHA256SUMS"])
    except FileExistsError as error:
        raise PackageError("candidate output appeared during packaging; refusing to overwrite it") from error
    validate_source_checkout(root, source_commit, source_tree)
    validate_source_copy(root, copy_root, read_source_input_manifest(manifest_path), source_commit, source_tree)
    validate_build_provenance(provenance_path, root, source, build_root, source_commit, source_tree, signing_certificate_sha1)
    if bundle_tree_sha256(source) != source_tree_hash or sha256_file(provenance_path) != build_record_hash or sha256_file(manifest_path) != input_manifest_hash:
        raise PackageError("built product or provenance inputs changed during packaging")
    final_archive = output / OUTPUT_NAME
    final_manifest = output / "MANIFEST.json"
    final_sums = output / "SHA256SUMS"
    print(f"Candidate archive: {final_archive}")
    print(f"Manifest: {final_manifest}")
    print(f"Checksums: {final_sums}")
    print(f"SHA-256: {sha256_file(final_archive)}")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Validate clean source inputs and package a local certificate-signed arm64 candidate")
    subparsers = parser.add_subparsers(dest="action", required=True)
    prepare_parser = subparsers.add_parser("prepare-source", help="copy a clean committed tree into an isolated build root")
    prepare_parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent.parent)
    prepare_parser.add_argument("--source-commit", required=True)
    prepare_parser.add_argument("--source-tree", required=True)
    prepare_parser.add_argument("--build-root", required=True, type=Path)
    record_parser = subparsers.add_parser("record-build", help="record builder-supplied argv and product hashes")
    record_parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent.parent)
    record_parser.add_argument("--source-commit", required=True)
    record_parser.add_argument("--source-tree", required=True)
    record_parser.add_argument("--build-root", required=True, type=Path)
    record_parser.add_argument("--working-directory", required=True, type=Path)
    record_parser.add_argument("--build-command-arg", action="append", required=True)
    record_parser.add_argument("--signing-certificate-sha1", required=True)
    ci_parser = subparsers.add_parser("validate-ci-app", help="validate an unsigned, non-distribution CI package build")
    ci_parser.add_argument("--app", required=True, type=Path)
    ci_parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent.parent)
    ci_parser.add_argument("--configuration", required=True)
    sign_parser = subparsers.add_parser("sign-app", help="explicitly sign each bundled Mach-O and the app bundle")
    sign_parser.add_argument("--app", required=True, type=Path)
    sign_parser.add_argument("--signing-certificate-sha1", required=True)
    package_parser = subparsers.add_parser("package", help="validate and package an existing built app")
    package_parser.add_argument("--app", required=True, type=Path)
    package_parser.add_argument("--source-commit", required=True)
    package_parser.add_argument("--source-tree", required=True)
    package_parser.add_argument("--build-root", required=True, type=Path)
    package_parser.add_argument("--output", required=True, type=Path)
    package_parser.add_argument("--signing-certificate-sha1", required=True)
    args = parser.parse_args(argv)
    try:
        if args.action == "prepare-source":
            source_root = validate_source_checkout(args.source_root, args.source_commit, args.source_tree)
            source_info = read_source_info(source_root)
            validate_app_version_metadata(source_info, source_info)
            copy_root, manifest_path = copy_source_inputs(args.source_root, args.source_commit, args.source_tree, args.build_root)
            print(f"Source input copy: {copy_root}")
            print(f"Source input manifest: {manifest_path}")
        elif args.action == "record-build":
            print(record_build_provenance(args.source_root, args.source_commit, args.source_tree, args.build_root, args.working_directory, args.build_command_arg, args.signing_certificate_sha1))
        elif args.action == "validate-ci-app":
            receipt_path = validate_ci_package_app(args.app.expanduser(), args.source_root, args.configuration)
            print(f"CI validation-only receipt: {receipt_path}")
        elif args.action == "sign-app":
            sign_app_bundle(args.app.expanduser(), args.signing_certificate_sha1)
            print(f"Signed and verified certificate-selected app: {args.app}")
        else:
            create_candidate(args.app, args.source_commit, args.source_tree, args.build_root, args.output, args.signing_certificate_sha1)
    except (PackageError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(f"candidate packaging failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
