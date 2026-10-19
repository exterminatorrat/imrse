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
from dataclasses import dataclass
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
PRIVATE_SIGNING_RECEIPT_SCHEMA = 1
PRIVATE_SIGNING_RECEIPT_FIELDS = frozenset({
    "schemaVersion", "evidenceRepresentation", "producer", "privateEvidence",
    "publicRedactedRepresentation", "signatureReceipt", "privateReceiptStorage",
})
PRIVATE_SIGNING_EVIDENCE_FIELDS = frozenset({"vector", "vectorSHA256"})
PRIVATE_SIGNING_VECTOR_FIELDS = frozenset({
    "signedBundlePath", "signedBundleFilesystemIdentity", "codesignExecutablePath",
    "codesignExecutablePathSHA256", "codesignExecutableSHA256", "codesignExecutableFilesystemIdentity",
    "identityKeychainPath", "identityKeychainPathSHA256", "certificateSHA1", "appBundleTreeSHA256", "calls",
})
PRIVATE_SIGNING_CALL_FIELDS = frozenset({"sequence", "argv", "context", "codesignExecutableFilesystemIdentity"})
PRIVATE_SIGNING_CONTEXT_FIELDS = frozenset({"workingDirectory", "home", "temporaryDirectory"})
PUBLIC_SIGNING_EXECUTION_RECEIPT_FIELDS = frozenset({
    "representation", "producer", "certificateSHA1", "identityKeychainPathSHA256",
    "codesignExecutablePathSHA256", "codesignExecutableSHA256", "codesignExecutableFilesystemIdentity",
    "signedBundlePathSHA256", "signedBundleFilesystemIdentity", "appBundleTreeSHA256", "calls", "redactedVectorSHA256",
})
PUBLIC_SIGNING_CALL_FIELDS = frozenset({"sequence", "argv", "executionContext", "codesignExecutableFilesystemIdentity"})
PUBLIC_SIGNING_CONTEXT_FIELDS = frozenset({
    "workingDirectoryPathSHA256", "homePathSHA256", "temporaryDirectoryPathSHA256",
})
SIGNATURE_RECEIPT_FIELDS = frozenset({
    "certificateSHA1", "identityKeychainPathSHA256", "codesignExecutableSHA256", "signatureType", "bundle", "codeItems",
})
SIGNATURE_COMPONENT_FIELDS = frozenset({
    "certificateSHA1", "signatureType", "identifier", "defaultDesignatedRequirement",
})
SIGNATURE_CODE_ITEM_FIELDS = SIGNATURE_COMPONENT_FIELDS | frozenset({"relativePath"})
BUILD_PROVENANCE_FIELDS = frozenset({
    "schemaVersion", "repository", "sourceCommitSHA", "sourceTreeSHA", "sourceInputManifest",
    "inputCopyRelativePath", "buildInputs", "build", "product",
})
BUILD_PROVENANCE_SOURCE_INPUT_FIELDS = frozenset({"fileName", "sha256"})
BUILD_PROVENANCE_BUILD_INPUT_FIELDS = frozenset({"lockFilesSHA256", "resolvedDependencyPins"})
BUILD_PROVENANCE_BUILD_FIELDS = frozenset({
    "configuration", "workingDirectoryRelativePath", "command", "commandPathValuesRelativeToBuildRoot",
    "signingCertificateSHA1", "identityKeychainPathSHA256", "codesignExecutableSHA256", "provenanceScope",
})
BUILD_PROVENANCE_PRODUCT_FIELDS = frozenset({
    "relativePath", "bundleTreeSHA256", "executableSHA256", "infoPlistSHA256", "signatureReceipt", "signingExecutionReceipt",
})
SOURCE_INPUT_MANIFEST_FIELDS = frozenset({"schemaVersion", "repository", "sourceCommitSHA", "sourceTreeSHA", "files"})
SOURCE_INPUT_FILE_FIELDS = frozenset({"path", "kind", "gitMode", "gitBlobSHA", "mode", "size", "sha256"})
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
BUILD_PROVENANCE_SCOPE = "local builder-supplied signing identity selectors; pinned codesign executable SHA-256, SHA-256 path selector, and named filesystem identity; private observed unredacted argv/context in an owner-private out-of-app receipt plus a public redacted ordered-vector projection; SHA-256 of the canonical identity-keychain path string; and verified public signature metadata; not an independent compiler or Keychain-state attestation"


class PackageError(Exception):
    pass


@dataclass(frozen=True)
class CodesignExecutablePin:
    path: Path
    sha256: str
    filesystem_identity: tuple


@dataclass
class PrivateSigningReceiptReservation:
    path: Path
    name: str
    parent_fd: int
    file_fd: int
    parent_identity: tuple
    file_identity: tuple
    written: bool = False


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


def codesign_file_identity(info):
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_nlink,
        info.st_uid,
        info.st_gid,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
        getattr(info, "st_flags", None),
    )


def canonical_json_sha256(value):
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def strict_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("JSON object contains duplicate keys")
        result[key] = value
    return result


def reject_nonstandard_json_constant(_):
    raise ValueError("JSON contains a nonstandard numeric constant")


def strict_json_loads(payload):
    return json.loads(payload, object_pairs_hook=strict_json_object, parse_constant=reject_nonstandard_json_constant)


def codesign_executable_identity_record(pin):
    return {
        "device": pin.filesystem_identity[0],
        "inode": pin.filesystem_identity[1],
        "mode": pin.filesystem_identity[2],
        "linkCount": pin.filesystem_identity[3],
        "ownerUID": pin.filesystem_identity[4],
        "ownerGID": pin.filesystem_identity[5],
        "size": pin.filesystem_identity[6],
        "modifiedTimeNS": pin.filesystem_identity[7],
        "changedTimeNS": pin.filesystem_identity[8],
        "flags": pin.filesystem_identity[9],
    }


def codesign_executable_path_sha256(pin):
    return hashlib.sha256(str(pin.path).encode("utf-8")).hexdigest()


def private_receipt_parent_identity(info):
    return (info.st_dev, info.st_ino, info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode))


def private_receipt_file_identity(info):
    return (info.st_dev, info.st_ino, info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), info.st_nlink)


def private_receipt_storage_record(file_info, parent_info):
    return {
        "file": {
            "device": file_info.st_dev,
            "inode": file_info.st_ino,
            "ownerUID": file_info.st_uid,
            "ownerGID": file_info.st_gid,
            "mode": stat.S_IMODE(file_info.st_mode),
            "linkCount": file_info.st_nlink,
        },
        "directory": {
            "device": parent_info.st_dev,
            "inode": parent_info.st_ino,
            "ownerUID": parent_info.st_uid,
            "ownerGID": parent_info.st_gid,
            "mode": stat.S_IMODE(parent_info.st_mode),
        },
    }


def bundle_filesystem_identity(bundle):
    info = Path(bundle).stat()
    return {
        "device": info.st_dev,
        "inode": info.st_ino,
        "ownerUID": info.st_uid,
        "ownerGID": info.st_gid,
        "mode": stat.S_IMODE(info.st_mode),
    }


def open_private_receipt_parent(path, bundle):
    path = Path(path)
    if not path.is_absolute() or path.name in {"", ".", ".."}:
        raise PackageError("private signing receipt path must be an absolute file path")
    try:
        parent = path.parent.resolve(strict=True)
        bundle = Path(bundle).resolve(strict=True)
        parent_fd = os.open(str(parent), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except (OSError, AttributeError, RuntimeError) as error:
        raise PackageError("private signing receipt directory is unavailable") from error
    parent_info = os.fstat(parent_fd)
    parent_mode = stat.S_IMODE(parent_info.st_mode)
    receipt_path = parent / path.name
    if (
        not stat.S_ISDIR(parent_info.st_mode)
        or parent_info.st_uid != os.getuid()
        or parent_mode != 0o700
        or receipt_path == bundle
        or receipt_path.is_relative_to(bundle)
    ):
        os.close(parent_fd)
        raise PackageError("private signing receipt must be outside the app in an owner-private directory")
    return receipt_path, parent_fd, parent_info


def reserve_private_signing_receipt(path, bundle):
    receipt_path, parent_fd, parent_info = open_private_receipt_parent(path, bundle)
    file_fd = None
    try:
        file_fd = os.open(
            receipt_path.name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=parent_fd,
        )
        os.fchmod(file_fd, 0o600)
        file_info = os.fstat(file_fd)
        if (
            not stat.S_ISREG(file_info.st_mode)
            or file_info.st_uid != os.getuid()
            or stat.S_IMODE(file_info.st_mode) != 0o600
            or file_info.st_nlink != 1
        ):
            raise PackageError("private signing receipt file is not exclusive and owner-only")
        return PrivateSigningReceiptReservation(
            receipt_path,
            receipt_path.name,
            parent_fd,
            file_fd,
            private_receipt_parent_identity(parent_info),
            private_receipt_file_identity(file_info),
        )
    except (OSError, PackageError) as error:
        if file_fd is not None:
            try:
                file_info = os.fstat(file_fd)
                named_info = os.stat(receipt_path.name, dir_fd=parent_fd, follow_symlinks=False)
                if private_receipt_file_identity(named_info) == private_receipt_file_identity(file_info):
                    os.unlink(receipt_path.name, dir_fd=parent_fd)
            except OSError:
                pass
            os.close(file_fd)
        os.close(parent_fd)
        if isinstance(error, PackageError):
            raise
        raise PackageError("private signing receipt could not be created exclusively") from error


def close_private_signing_receipt_reservation(reservation, remove=False):
    if remove:
        try:
            current = os.stat(reservation.name, dir_fd=reservation.parent_fd, follow_symlinks=False)
            if private_receipt_file_identity(current) == reservation.file_identity:
                os.unlink(reservation.name, dir_fd=reservation.parent_fd)
        except FileNotFoundError:
            pass
    os.close(reservation.file_fd)
    os.close(reservation.parent_fd)


def write_private_signing_receipt(reservation, receipt):
    if reservation.written:
        raise PackageError("private signing receipt reservation has already been written")
    parent_info = os.fstat(reservation.parent_fd)
    file_info = os.fstat(reservation.file_fd)
    try:
        named_file_info = os.stat(reservation.name, dir_fd=reservation.parent_fd, follow_symlinks=False)
        named_parent_info = reservation.path.parent.stat()
    except OSError as error:
        raise PackageError("private signing receipt identity changed before writing") from error
    if (
        private_receipt_parent_identity(parent_info) != reservation.parent_identity
        or private_receipt_parent_identity(named_parent_info) != reservation.parent_identity
        or private_receipt_file_identity(file_info) != reservation.file_identity
        or private_receipt_file_identity(named_file_info) != reservation.file_identity
        or file_info.st_size != 0
        or named_file_info.st_size != 0
    ):
        raise PackageError("private signing receipt identity changed before writing")
    private_receipt = {
        **receipt,
        "privateReceiptStorage": private_receipt_storage_record(file_info, parent_info),
    }
    payload = (json.dumps(private_receipt, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
    try:
        os.ftruncate(reservation.file_fd, 0)
        os.lseek(reservation.file_fd, 0, os.SEEK_SET)
        view = memoryview(payload)
        while view:
            view = view[os.write(reservation.file_fd, view):]
        os.fsync(reservation.file_fd)
        file_info = os.fstat(reservation.file_fd)
        named_file_info = os.stat(reservation.name, dir_fd=reservation.parent_fd, follow_symlinks=False)
        parent_info = os.fstat(reservation.parent_fd)
        named_parent_info = reservation.path.parent.stat()
    except OSError as error:
        raise PackageError("private signing receipt could not be written") from error
    if (
        not stat.S_ISREG(file_info.st_mode)
        or file_info.st_uid != os.getuid()
        or stat.S_IMODE(file_info.st_mode) != 0o600
        or file_info.st_nlink != 1
        or private_receipt_file_identity(named_file_info) != private_receipt_file_identity(file_info)
        or private_receipt_parent_identity(parent_info) != reservation.parent_identity
        or private_receipt_parent_identity(named_parent_info) != reservation.parent_identity
    ):
        raise PackageError("private signing receipt identity changed while writing")
    reservation.written = True


def read_private_signing_receipt(path, bundle):
    receipt_path, parent_fd, parent_info = open_private_receipt_parent(path, bundle)
    try:
        file_fd = os.open(receipt_path.name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=parent_fd)
    except OSError as error:
        os.close(parent_fd)
        raise PackageError("private signing receipt is missing or not a regular private file") from error
    try:
        try:
            file_info = os.fstat(file_fd)
            named_info = os.stat(receipt_path.name, dir_fd=parent_fd, follow_symlinks=False)
            named_parent_info = receipt_path.parent.stat()
        except OSError as error:
            raise PackageError("private signing receipt identity changed while reading") from error
        if (
            codesign_file_identity(file_info) != codesign_file_identity(named_info)
            or private_receipt_parent_identity(named_parent_info) != private_receipt_parent_identity(parent_info)
        ):
            raise PackageError("private signing receipt identity changed while reading")
        if (
            not stat.S_ISREG(file_info.st_mode)
            or file_info.st_uid != os.getuid()
            or stat.S_IMODE(file_info.st_mode) != 0o600
            or file_info.st_nlink != 1
            or file_info.st_size <= 0
            or file_info.st_size > 16 * 1024 * 1024
        ):
            raise PackageError("private signing receipt is not an owner-only exclusive regular file")
        chunks = []
        payload_size = 0
        while True:
            block = os.read(file_fd, 1024 * 1024)
            if not block:
                break
            payload_size += len(block)
            if payload_size > 16 * 1024 * 1024:
                raise PackageError("private signing receipt exceeds the allowed size")
            chunks.append(block)
        payload = b"".join(chunks)
        try:
            final_info = os.fstat(file_fd)
            named_info = os.stat(receipt_path.name, dir_fd=parent_fd, follow_symlinks=False)
            named_parent_info = receipt_path.parent.stat()
        except OSError as error:
            raise PackageError("private signing receipt identity changed while reading") from error
        if (
            codesign_file_identity(file_info) != codesign_file_identity(final_info)
            or codesign_file_identity(final_info) != codesign_file_identity(named_info)
            or private_receipt_parent_identity(named_parent_info) != private_receipt_parent_identity(parent_info)
        ):
            raise PackageError("private signing receipt identity changed while reading")
        try:
            receipt = strict_json_loads(payload)
        except (ValueError, UnicodeDecodeError) as error:
            raise PackageError("private signing receipt is invalid JSON") from error
        expected_storage = private_receipt_storage_record(final_info, parent_info)
        if (
            not isinstance(receipt, dict)
            or canonical_json_sha256(receipt.get("privateReceiptStorage")) != canonical_json_sha256(expected_storage)
        ):
            raise PackageError("private signing receipt storage identity does not match")
        return receipt
    finally:
        os.close(file_fd)
        os.close(parent_fd)


def pin_codesign_executable(path, expected_sha256):
    if not isinstance(path, (str, os.PathLike)) or not os.fspath(path).strip():
        raise PackageError("an explicit codesign executable path is required")
    path = Path(path)
    if not path.is_absolute():
        raise PackageError("codesign executable path must be absolute")
    if not isinstance(expected_sha256, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", expected_sha256):
        raise PackageError("a caller-selected 64-hex codesign executable SHA-256 is required")
    expected_sha256 = expected_sha256.lower()
    try:
        resolved = path.resolve(strict=True)
        before = path.stat()
        actual_sha256 = sha256_file(path)
        after = path.stat()
    except (OSError, RuntimeError) as error:
        raise PackageError("codesign executable must be a stable, existing executable file") from error
    if (
        path != resolved
        or not stat.S_ISREG(before.st_mode)
        or not before.st_mode & 0o111
        or not os.access(path, os.X_OK)
        or codesign_file_identity(before) != codesign_file_identity(after)
        or actual_sha256 != expected_sha256
    ):
        raise PackageError("codesign executable does not match the selected SHA-256 or is not physically stable")
    return CodesignExecutablePin(resolved, expected_sha256, codesign_file_identity(after))


def validate_codesign_executable_pin(pin):
    try:
        resolved = pin.path.resolve(strict=True)
        before = pin.path.stat()
        actual_sha256 = sha256_file(pin.path)
        after = pin.path.stat()
    except (OSError, RuntimeError) as error:
        raise PackageError("pinned codesign executable is missing or unreadable") from error
    if (
        resolved != pin.path
        or not stat.S_ISREG(before.st_mode)
        or not before.st_mode & 0o111
        or not os.access(pin.path, os.X_OK)
        or codesign_file_identity(before) != codesign_file_identity(after)
        or codesign_file_identity(after) != pin.filesystem_identity
        or actual_sha256 != pin.sha256
    ):
        raise PackageError("pinned codesign executable changed identity or SHA-256")


def run_codesign(pin, arguments, *, signing_calls=None, signed_bundle=None):
    is_signing = "--sign" in arguments
    if is_signing != (signing_calls is not None and signed_bundle is not None):
        raise PackageError("codesign signing calls require private execution capture")
    validate_codesign_executable_pin(pin)
    command = [str(pin.path), *arguments]
    context = {
        "workingDirectory": os.getcwd(),
        "home": os.environ.get("HOME"),
        "temporaryDirectory": os.environ.get("TMPDIR"),
    } if is_signing else None
    executable_identity = codesign_executable_identity_record(pin) if is_signing else None
    try:
        output = run(command)
    except PackageError as error:
        if "does not satisfy the selected certificate" in str(error):
            raise PackageError("code signature does not satisfy the selected certificate") from None
        if "no matching signing identity" in str(error).lower():
            raise PackageError("no matching signing identity") from None
        raise PackageError("pinned codesign invocation failed") from None
    except (OSError, subprocess.SubprocessError):
        raise PackageError("pinned codesign invocation failed") from None
    finally:
        validate_codesign_executable_pin(pin)
    if is_signing:
        signing_calls.append({
            "sequence": len(signing_calls) + 1,
            "argv": command,
            "context": context,
            "codesignExecutableFilesystemIdentity": executable_identity,
        })
    return output


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
            raise PackageError("cannot verify quarantine metadata for an app bundle item")


def read_plist(path):
    try:
        with path.open("rb") as source:
            return plistlib.load(source)
    except (OSError, plistlib.InvalidFileException) as error:
        raise PackageError("cannot read bundle metadata") from error


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
        raise PackageError("built app does not exist") from error
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
        data = strict_json_loads((root / "Package.resolved").read_text())
        pins = {pin["identity"]: {"version": pin["state"]["version"], "revision": pin["state"]["revision"]} for pin in data["pins"]}
    except (OSError, ValueError, KeyError, TypeError) as error:
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
            raise PackageError(
                f"built Mach-O architecture does not match the {host_architecture} CI host; "
                f"found {sorted(actual_architectures)}: {binary.relative_to(bundle)}"
            )
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


def normalize_signing_keychain_path(value):
    if not isinstance(value, (str, os.PathLike)) or not os.fspath(value).strip():
        raise PackageError("an explicit signing keychain path is required")
    path = Path(value)
    if not path.is_absolute():
        raise PackageError("signing keychain path must be absolute")
    try:
        resolved = path.resolve(strict=True)
        mode = resolved.stat().st_mode
    except (OSError, RuntimeError) as error:
        raise PackageError("signing keychain path must resolve to an existing regular file") from error
    if not stat.S_ISREG(mode):
        raise PackageError("signing keychain path must resolve to an existing regular file")
    return resolved


def identity_keychain_path_sha256(path):
    return hashlib.sha256(str(path).encode("utf-8")).hexdigest()


def code_signature_metadata(path, certificate_sha1, codesign_pin, *, deep=False, expected_identifier=None):
    certificate_sha1 = normalize_certificate_sha1(certificate_sha1)
    requirement = f'certificate leaf H"{certificate_sha1}"'
    verification = ["--verify", "--strict"]
    if deep:
        verification.append("--deep")
    verification.extend((f"-R={requirement}", str(path)))
    run_codesign(codesign_pin, verification)
    details = run_codesign(codesign_pin, ["-dv", "--verbose=4", str(path)])
    if any(line.strip() == "Signature=adhoc" for line in details.splitlines()):
        raise PackageError("code signature is ad-hoc")
    identifiers = [line.partition("=")[2].strip() for line in details.splitlines() if line.startswith("Identifier=")]
    if len(identifiers) != 1 or not identifiers[0]:
        raise PackageError("code signature identifier is missing or ambiguous")
    identifier = identifiers[0]
    if expected_identifier is not None and identifier != expected_identifier:
        raise PackageError("code signature identifier does not match the expected bundle identity")
    requirement_output = run_codesign(codesign_pin, ["-d", "-r-", str(path)])
    designated_requirements = re.findall(r"(?m)^[ \t]*#?[ \t]*designated =>[ \t]*(.+?)[ \t]*$", requirement_output)
    if len(designated_requirements) != 1 or not designated_requirements[0].strip():
        raise PackageError("code signature default designated requirement is missing or ambiguous")
    return {
        "certificateSHA1": certificate_sha1,
        "signatureType": "certificate-signed",
        "identifier": identifier,
        "defaultDesignatedRequirement": designated_requirements[0].strip(),
    }


def verify_bundle_signature_receipt(bundle, certificate_sha1, signing_keychain_path, codesign_pin, binaries=None):
    bundle_path = Path(bundle)
    if bundle_path.is_symlink() or not bundle_path.is_dir():
        raise PackageError("signed app bundle must be a real directory")
    bundle = bundle_path.resolve(strict=True)
    certificate_sha1 = normalize_certificate_sha1(certificate_sha1)
    signing_keychain_path = normalize_signing_keychain_path(signing_keychain_path)
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
        try:
            resolved = path.resolve(strict=True)
        except OSError as error:
            raise PackageError("signed code item must be a real file inside the app bundle") from error
        if path.is_symlink() or not path.is_file() or not resolved.is_relative_to(bundle):
            raise PackageError("signed code item must be a real file inside the app bundle")
    bundle_receipt = code_signature_metadata(
        bundle,
        certificate_sha1,
        codesign_pin,
        deep=True,
        expected_identifier=EXPECTED_BUNDLE_ID,
    )
    code_receipts = [
        {
            "relativePath": path.relative_to(bundle).as_posix(),
            **code_signature_metadata(path, certificate_sha1, codesign_pin),
        }
        for path in code_paths
    ]
    return {
        "certificateSHA1": certificate_sha1,
        "identityKeychainPathSHA256": identity_keychain_path_sha256(signing_keychain_path),
        "codesignExecutableSHA256": codesign_pin.sha256,
        "signatureType": "certificate-signed",
        "bundle": bundle_receipt,
        "codeItems": code_receipts,
    }


def validate_signature_receipt_schema(receipt):
    if (
        not isinstance(receipt, dict)
        or set(receipt) != SIGNATURE_RECEIPT_FIELDS
        or not isinstance(receipt.get("certificateSHA1"), str)
        or not re.fullmatch(r"[0-9a-f]{40}", receipt["certificateSHA1"])
        or not isinstance(receipt.get("identityKeychainPathSHA256"), str)
        or not re.fullmatch(r"[0-9a-f]{64}", receipt["identityKeychainPathSHA256"])
        or not isinstance(receipt.get("codesignExecutableSHA256"), str)
        or not re.fullmatch(r"[0-9a-f]{64}", receipt["codesignExecutableSHA256"])
        or receipt.get("signatureType") != "certificate-signed"
    ):
        raise PackageError("signature receipt has unknown, missing, or invalid fields")
    bundle = receipt.get("bundle")
    code_items = receipt.get("codeItems")
    if not isinstance(bundle, dict) or set(bundle) != SIGNATURE_COMPONENT_FIELDS or not isinstance(code_items, list) or not code_items:
        raise PackageError("signature receipt has unknown, missing, or invalid code metadata")
    components = [(bundle, SIGNATURE_COMPONENT_FIELDS), *((item, SIGNATURE_CODE_ITEM_FIELDS) for item in code_items)]
    for component, expected_fields in components:
        if (
            not isinstance(component, dict)
            or set(component) != expected_fields
            or component.get("certificateSHA1") != receipt["certificateSHA1"]
            or component.get("signatureType") != "certificate-signed"
            or not isinstance(component.get("identifier"), str)
            or not component["identifier"]
            or not isinstance(component.get("defaultDesignatedRequirement"), str)
            or not component["defaultDesignatedRequirement"]
        ):
            raise PackageError("signature receipt has unknown, missing, or invalid code metadata")
        if "relativePath" in expected_fields:
            relative = component.get("relativePath")
            relative_path = PurePosixPath(relative) if isinstance(relative, str) else None
            if relative_path is None or relative_path.is_absolute() or ".." in relative_path.parts or relative_path == PurePosixPath("."):
                raise PackageError("signature receipt has an invalid bundle-relative code path")
    return receipt


def public_signing_execution_receipt(producer, private_vector, bundle, binaries):
    if not isinstance(private_vector, dict) or set(private_vector) != PRIVATE_SIGNING_VECTOR_FIELDS:
        raise PackageError("private signing evidence has invalid identity selectors")
    bundle = Path(bundle).resolve(strict=True)
    signed_bundle_path = private_vector.get("signedBundlePath")
    pin_path = private_vector.get("codesignExecutablePath")
    keychain_path = private_vector.get("identityKeychainPath")
    certificate_sha1 = private_vector.get("certificateSHA1")
    if (
        producer not in {"builder", "candidate"}
        or not isinstance(signed_bundle_path, str)
        or not Path(signed_bundle_path).is_absolute()
        or not isinstance(pin_path, str)
        or not Path(pin_path).is_absolute()
        or not isinstance(keychain_path, str)
        or not Path(keychain_path).is_absolute()
        or not re.fullmatch(r"[0-9a-f]{40}", certificate_sha1 or "")
    ):
        raise PackageError("private signing evidence has invalid identity selectors")
    pin = pin_codesign_executable(pin_path, private_vector.get("codesignExecutableSHA256"))
    pin_identity = codesign_executable_identity_record(pin)
    if canonical_json_sha256(private_vector.get("codesignExecutableFilesystemIdentity")) != canonical_json_sha256(pin_identity):
        raise PackageError("private signing evidence does not match the pinned codesign executable identity")
    signed_bundle_identity = private_vector.get("signedBundleFilesystemIdentity")
    if canonical_json_sha256(signed_bundle_identity) != canonical_json_sha256(bundle_filesystem_identity(bundle)):
        raise PackageError("private signing evidence does not match the signed app filesystem identity")
    keychain_path = normalize_signing_keychain_path(keychain_path)
    if private_vector.get("identityKeychainPathSHA256") != identity_keychain_path_sha256(keychain_path):
        raise PackageError("private signing evidence does not match the selected keychain path")
    expected_binaries = [Path(binary).resolve(strict=True) for binary in binaries]
    if (
        len(set(expected_binaries)) != len(expected_binaries)
        or set(expected_binaries) != set(macho_files(bundle))
        or bundle / "Contents/MacOS/imrse" not in expected_binaries
    ):
        raise PackageError("private signing evidence does not cover every app code item")
    signed_bundle_path = Path(signed_bundle_path)
    expected_targets = [str(signed_bundle_path / binary.relative_to(bundle)) for binary in expected_binaries] + [str(signed_bundle_path)]
    calls = private_vector.get("calls")
    if not isinstance(calls, list) or len(calls) != len(expected_targets):
        raise PackageError("private signing evidence does not contain every actual signing call")
    redacted_calls = []
    for sequence, (call, expected_target) in enumerate(zip(calls, expected_targets), start=1):
        if (
            not isinstance(call, dict)
            or set(call) != PRIVATE_SIGNING_CALL_FIELDS
            or type(call.get("sequence")) is not int
            or call.get("sequence") != sequence
        ):
            raise PackageError("private signing evidence has an invalid signing-call sequence")
        argv = call.get("argv")
        context = call.get("context")
        if (
            not isinstance(argv, list)
            or any(not isinstance(value, str) for value in argv)
            or argv != [
                pin_path,
                "--force",
                "--keychain",
                str(keychain_path),
                "--sign",
                certificate_sha1,
                "--timestamp=none",
                expected_target,
            ]
            or not isinstance(context, dict)
            or set(context) != PRIVATE_SIGNING_CONTEXT_FIELDS
            or not isinstance(context["workingDirectory"], str)
            or any(value is not None and not isinstance(value, str) for value in context.values())
            or canonical_json_sha256(call.get("codesignExecutableFilesystemIdentity")) != canonical_json_sha256(pin_identity)
        ):
            raise PackageError("private signing evidence does not match the observed ordered signing invocation")
        redacted_calls.append({
            "sequence": sequence,
            "argv": [
                {"selector": "codesign-executable-path-sha256", "sha256": codesign_executable_path_sha256(pin)},
                "--force",
                "--keychain",
                {"selector": "identity-keychain-path-sha256", "sha256": identity_keychain_path_sha256(keychain_path)},
                "--sign",
                certificate_sha1,
                "--timestamp=none",
                {"selector": "bundle-relative-target", "path": Path(expected_target).relative_to(signed_bundle_path).as_posix()},
            ],
            "executionContext": {
                "workingDirectoryPathSHA256": hashlib.sha256(context["workingDirectory"].encode("utf-8")).hexdigest(),
                "homePathSHA256": hashlib.sha256(context["home"].encode("utf-8")).hexdigest() if context["home"] is not None else None,
                "temporaryDirectoryPathSHA256": hashlib.sha256(context["temporaryDirectory"].encode("utf-8")).hexdigest() if context["temporaryDirectory"] is not None else None,
            },
            "codesignExecutableFilesystemIdentity": pin_identity,
        })
    return {
        "representation": "PUBLIC-REDACTED-OBSERVED-ORDERED-ARGV",
        "producer": producer,
        "certificateSHA1": certificate_sha1,
        "identityKeychainPathSHA256": identity_keychain_path_sha256(keychain_path),
        "codesignExecutablePathSHA256": codesign_executable_path_sha256(pin),
        "codesignExecutableSHA256": pin.sha256,
        "codesignExecutableFilesystemIdentity": pin_identity,
        "signedBundlePathSHA256": hashlib.sha256(signed_bundle_path.as_posix().encode("utf-8")).hexdigest(),
        "signedBundleFilesystemIdentity": signed_bundle_identity,
        "appBundleTreeSHA256": bundle_tree_sha256(bundle),
        "calls": redacted_calls,
        "redactedVectorSHA256": canonical_json_sha256(redacted_calls),
    }


def private_signing_receipt_payload(signing_result, producer, bundle, certificate_sha1, signing_keychain_path, codesign_pin):
    if not isinstance(signing_result, dict):
        raise PackageError("private signing evidence changed before receipt creation")
    private_vector = signing_result.get("privateSigningVector")
    public_receipt = signing_result.get("signingExecutionReceipt")
    signature_receipt = signing_result.get("signatureReceipt")
    if (
        not isinstance(private_vector, dict)
        or set(private_vector) != PRIVATE_SIGNING_VECTOR_FIELDS
        or producer not in {"builder", "candidate"}
        or private_vector.get("certificateSHA1") != normalize_certificate_sha1(certificate_sha1)
        or private_vector.get("identityKeychainPath") != str(normalize_signing_keychain_path(signing_keychain_path))
        or private_vector.get("codesignExecutablePath") != str(codesign_pin.path)
        or private_vector.get("codesignExecutableSHA256") != codesign_pin.sha256
        or canonical_json_sha256(private_vector.get("signedBundleFilesystemIdentity")) != canonical_json_sha256(bundle_filesystem_identity(bundle))
        or private_vector.get("appBundleTreeSHA256") != bundle_tree_sha256(bundle)
    ):
        raise PackageError("private signing evidence changed before receipt creation")
    validate_signature_receipt_schema(signature_receipt)
    expected_public = public_signing_execution_receipt(producer, private_vector, bundle, macho_files(bundle))
    if public_receipt != expected_public:
        raise PackageError("private signing evidence changed before receipt creation")
    return {
        "schemaVersion": PRIVATE_SIGNING_RECEIPT_SCHEMA,
        "evidenceRepresentation": "PRIVATE-OBSERVED-UNREDACTED-ARGV-AND-CONTEXT",
        "producer": producer,
        "privateEvidence": {
            "vector": private_vector,
            "vectorSHA256": canonical_json_sha256(private_vector),
        },
        "publicRedactedRepresentation": expected_public,
        "signatureReceipt": signature_receipt,
    }


def validate_public_signing_execution_receipt(receipt, producer, bundle, certificate_sha1, signing_keychain_path, codesign_pin):
    bundle = Path(bundle).resolve(strict=True)
    signing_keychain_path = normalize_signing_keychain_path(signing_keychain_path)
    certificate_sha1 = normalize_certificate_sha1(certificate_sha1)
    expected_identity = codesign_executable_identity_record(codesign_pin)
    if (
        not isinstance(receipt, dict)
        or set(receipt) != PUBLIC_SIGNING_EXECUTION_RECEIPT_FIELDS
        or receipt.get("representation") != "PUBLIC-REDACTED-OBSERVED-ORDERED-ARGV"
        or receipt.get("producer") != producer
        or receipt.get("certificateSHA1") != certificate_sha1
        or receipt.get("identityKeychainPathSHA256") != identity_keychain_path_sha256(signing_keychain_path)
        or receipt.get("codesignExecutablePathSHA256") != codesign_executable_path_sha256(codesign_pin)
        or receipt.get("codesignExecutableSHA256") != codesign_pin.sha256
        or canonical_json_sha256(receipt.get("codesignExecutableFilesystemIdentity")) != canonical_json_sha256(expected_identity)
        or not isinstance(receipt.get("signedBundlePathSHA256"), str)
        or not re.fullmatch(r"[0-9a-f]{64}", receipt["signedBundlePathSHA256"])
        or canonical_json_sha256(receipt.get("signedBundleFilesystemIdentity")) != canonical_json_sha256(bundle_filesystem_identity(bundle))
        or receipt.get("appBundleTreeSHA256") != bundle_tree_sha256(bundle)
    ):
        raise PackageError("public signing execution receipt does not match its selected identity or signed app")
    binaries = macho_files(bundle)
    expected_targets = [path.relative_to(bundle).as_posix() for path in binaries] + ["."]
    expected_calls = receipt.get("calls")
    if not isinstance(expected_calls, list) or len(expected_calls) != len(expected_targets):
        raise PackageError("public signing execution receipt does not cover every app code item")
    executable_selector = {"selector": "codesign-executable-path-sha256", "sha256": codesign_executable_path_sha256(codesign_pin)}
    keychain_selector = {"selector": "identity-keychain-path-sha256", "sha256": identity_keychain_path_sha256(signing_keychain_path)}
    for sequence, (call, relative_target) in enumerate(zip(expected_calls, expected_targets), start=1):
        expected_argv = [
            executable_selector,
            "--force",
            "--keychain",
            keychain_selector,
            "--sign",
            certificate_sha1,
            "--timestamp=none",
            {"selector": "bundle-relative-target", "path": relative_target},
        ]
        context = call.get("executionContext") if isinstance(call, dict) else None
        if (
            not isinstance(call, dict)
            or set(call) != PUBLIC_SIGNING_CALL_FIELDS
            or type(call.get("sequence")) is not int
            or call.get("sequence") != sequence
            or call.get("argv") != expected_argv
            or canonical_json_sha256(call.get("codesignExecutableFilesystemIdentity")) != canonical_json_sha256(expected_identity)
            or not isinstance(context, dict)
            or set(context) != PUBLIC_SIGNING_CONTEXT_FIELDS
            or any(value is not None and (not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value)) for value in context.values())
        ):
            raise PackageError("public signing execution receipt has an invalid redacted call")
    if receipt.get("redactedVectorSHA256") != canonical_json_sha256(expected_calls):
        raise PackageError("public signing execution receipt vector digest does not match")
    return receipt


def validate_private_signing_receipt(receipt, producer, bundle, binaries, certificate_sha1, signing_keychain_path, codesign_pin):
    if (
        not isinstance(receipt, dict)
        or set(receipt) != PRIVATE_SIGNING_RECEIPT_FIELDS
        or type(receipt.get("schemaVersion")) is not int
        or receipt.get("schemaVersion") != PRIVATE_SIGNING_RECEIPT_SCHEMA
        or receipt.get("evidenceRepresentation") != "PRIVATE-OBSERVED-UNREDACTED-ARGV-AND-CONTEXT"
        or receipt.get("producer") != producer
        or not isinstance(receipt.get("privateEvidence"), dict)
    ):
        raise PackageError("private signing receipt has the wrong producer or schema")
    private_evidence = receipt["privateEvidence"]
    private_vector = private_evidence.get("vector")
    if (
        set(private_evidence) != PRIVATE_SIGNING_EVIDENCE_FIELDS
        or not isinstance(private_vector, dict)
        or set(private_vector) != PRIVATE_SIGNING_VECTOR_FIELDS
        or private_evidence.get("vectorSHA256") != canonical_json_sha256(private_vector)
        or private_vector.get("codesignExecutablePath") != str(codesign_pin.path)
        or private_vector.get("codesignExecutablePathSHA256") != codesign_executable_path_sha256(codesign_pin)
        or private_vector.get("codesignExecutableSHA256") != codesign_pin.sha256
        or canonical_json_sha256(private_vector.get("codesignExecutableFilesystemIdentity"))
        != canonical_json_sha256(codesign_executable_identity_record(codesign_pin))
        or not isinstance(private_vector.get("signedBundlePath"), str)
        or not Path(private_vector["signedBundlePath"]).is_absolute()
        or canonical_json_sha256(private_vector.get("signedBundleFilesystemIdentity"))
        != canonical_json_sha256(bundle_filesystem_identity(bundle))
        or private_vector.get("identityKeychainPath") != str(normalize_signing_keychain_path(signing_keychain_path))
        or private_vector.get("identityKeychainPathSHA256") != identity_keychain_path_sha256(normalize_signing_keychain_path(signing_keychain_path))
        or private_vector.get("certificateSHA1") != normalize_certificate_sha1(certificate_sha1)
        or private_vector.get("appBundleTreeSHA256") != bundle_tree_sha256(bundle)
    ):
        raise PackageError("private signing receipt does not match the selected identity or signed app")
    expected_public = public_signing_execution_receipt(producer, private_vector, bundle, binaries)
    if receipt.get("publicRedactedRepresentation") != expected_public:
        raise PackageError("private signing receipt public representation does not match its observed vector")
    validate_public_signing_execution_receipt(
        expected_public,
        producer,
        bundle,
        certificate_sha1,
        signing_keychain_path,
        codesign_pin,
    )
    signature_receipt = validate_signature_receipt_schema(receipt.get("signatureReceipt"))
    actual_signature_receipt = verify_bundle_signature_receipt(
        bundle,
        certificate_sha1,
        signing_keychain_path,
        codesign_pin,
        binaries,
    )
    if signature_receipt != actual_signature_receipt:
        raise PackageError("private signing receipt signature metadata does not match the verified signed app")
    return {
        "signatureReceipt": actual_signature_receipt,
        "signingExecutionReceipt": expected_public,
    }


def sign_and_verify(bundle, binaries, certificate_sha1, signing_keychain_path, codesign_pin, *, producer="candidate"):
    bundle_path = Path(bundle)
    if bundle_path.is_symlink() or not bundle_path.is_dir():
        raise PackageError("signed app bundle must be a real directory")
    bundle = bundle_path.resolve(strict=True)
    certificate_sha1 = normalize_certificate_sha1(certificate_sha1)
    signing_keychain_path = normalize_signing_keychain_path(signing_keychain_path)
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
    signing_calls = []
    for binary in binaries:
        run_codesign(
            codesign_pin,
            ["--force", "--keychain", str(signing_keychain_path), "--sign", certificate_sha1, "--timestamp=none", str(binary)],
            signing_calls=signing_calls,
            signed_bundle=bundle,
        )
    run_codesign(
        codesign_pin,
        ["--force", "--keychain", str(signing_keychain_path), "--sign", certificate_sha1, "--timestamp=none", str(bundle)],
        signing_calls=signing_calls,
        signed_bundle=bundle,
    )
    signature_receipt = verify_bundle_signature_receipt(bundle, certificate_sha1, signing_keychain_path, codesign_pin, binaries)
    private_vector = {
        "signedBundlePath": str(bundle),
        "signedBundleFilesystemIdentity": bundle_filesystem_identity(bundle),
        "codesignExecutablePath": str(codesign_pin.path),
        "codesignExecutablePathSHA256": codesign_executable_path_sha256(codesign_pin),
        "codesignExecutableSHA256": codesign_pin.sha256,
        "codesignExecutableFilesystemIdentity": codesign_executable_identity_record(codesign_pin),
        "identityKeychainPath": str(signing_keychain_path),
        "identityKeychainPathSHA256": identity_keychain_path_sha256(signing_keychain_path),
        "certificateSHA1": certificate_sha1,
        "appBundleTreeSHA256": bundle_tree_sha256(bundle),
        "calls": signing_calls,
    }
    return {
        "signatureReceipt": signature_receipt,
        "signingExecutionReceipt": public_signing_execution_receipt(producer, private_vector, bundle, binaries),
        "privateSigningVector": private_vector,
    }


def sign_app_bundle(bundle, certificate_sha1, signing_keychain_path, codesign_pin):
    reject_ci_validation_app(bundle)
    validate_symlinks(bundle)
    return sign_and_verify(bundle, macho_files(bundle), certificate_sha1, signing_keychain_path, codesign_pin, producer="builder")


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
    candidate = parent / path.name
    if candidate.is_symlink():
        raise PackageError("build root must be an absolute, non-symlink path")
    resolved = candidate.resolve(strict=False)
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
        manifest = strict_json_loads(path.read_text())
    except (OSError, ValueError) as error:
        raise PackageError("cannot read source input manifest") from error
    if (
        not isinstance(manifest, dict)
        or set(manifest) != SOURCE_INPUT_MANIFEST_FIELDS
        or type(manifest.get("schemaVersion")) is not int
        or manifest.get("schemaVersion") != 1
        or manifest.get("repository") != "exterminatorrat/imrse"
        or not isinstance(manifest.get("sourceCommitSHA"), str)
        or not re.fullmatch(r"[0-9a-f]{40}", manifest["sourceCommitSHA"])
        or not isinstance(manifest.get("sourceTreeSHA"), str)
        or not re.fullmatch(r"[0-9a-f]{40}", manifest["sourceTreeSHA"])
        or not isinstance(manifest.get("files"), list)
    ):
        raise PackageError("unsupported source input manifest schema")
    for entry in manifest["files"]:
        relative_path = PurePosixPath(entry["path"]) if isinstance(entry, dict) and isinstance(entry.get("path"), str) else None
        if (
            not isinstance(entry, dict)
            or set(entry) != SOURCE_INPUT_FILE_FIELDS
            or not isinstance(entry.get("path"), str)
            or not entry["path"]
            or relative_path is None
            or relative_path.is_absolute()
            or not relative_path.parts
            or any(part in ("", ".", "..") for part in relative_path.parts)
            or not isinstance(entry.get("kind"), str)
            or entry["kind"] not in {"file", "symlink"}
            or not isinstance(entry.get("gitMode"), str)
            or entry["gitMode"] not in {"100644", "100755", "120000"}
            or (entry["kind"] == "symlink") != (entry["gitMode"] == "120000")
            or not isinstance(entry.get("gitBlobSHA"), str)
            or not re.fullmatch(r"[0-9a-f]{40}", entry["gitBlobSHA"])
            or type(entry.get("mode")) is not int
            or not 0 <= entry["mode"] <= 0o7777
            or type(entry.get("size")) is not int
            or entry["size"] < 0
            or not isinstance(entry.get("sha256"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])
        ):
            raise PackageError("source input manifest has unknown, missing, or invalid file fields")
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


def record_build_provenance(root, source_commit, source_tree, build_root, working_directory, build_command, signing_certificate_sha1, signing_keychain_path, codesign_pin, private_signing_receipt_path):
    signing_certificate_sha1 = normalize_certificate_sha1(signing_certificate_sha1)
    signing_keychain_path = normalize_signing_keychain_path(signing_keychain_path)
    signing_keychain_path_sha256 = identity_keychain_path_sha256(signing_keychain_path)
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
    private_receipt = read_private_signing_receipt(private_signing_receipt_path, product)
    signing_execution = validate_private_signing_receipt(
        private_receipt,
        "builder",
        product,
        macho_files(product),
        signing_certificate_sha1,
        signing_keychain_path,
        codesign_pin,
    )
    signature_receipt = signing_execution["signatureReceipt"]
    record = {
        "schemaVersion": 6,
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
            "identityKeychainPathSHA256": signing_keychain_path_sha256,
            "codesignExecutableSHA256": codesign_pin.sha256,
            "provenanceScope": BUILD_PROVENANCE_SCOPE,
        },
        "product": {
            "relativePath": "products/imrse.app",
            "bundleTreeSHA256": bundle_tree_sha256(product),
            "executableSHA256": sha256_file(product / "Contents/MacOS/imrse"),
            "infoPlistSHA256": sha256_file(product / "Contents/Info.plist"),
            "signatureReceipt": signature_receipt,
            "signingExecutionReceipt": signing_execution["signingExecutionReceipt"],
        },
    }
    provenance_path = build_root / BUILD_PROVENANCE_FILE
    if os.path.lexists(provenance_path):
        raise PackageError("build provenance already exists; refusing to overwrite")
    with provenance_path.open("x") as destination:
        destination.write(json.dumps(record, indent=2, sort_keys=True) + "\n")
    return provenance_path


def validate_build_provenance(provenance_path, root, product, expected_build_root, source_commit, source_tree, signing_certificate_sha1, signing_keychain_path, codesign_pin):
    signing_certificate_sha1 = normalize_certificate_sha1(signing_certificate_sha1)
    signing_keychain_path = normalize_signing_keychain_path(signing_keychain_path)
    signing_keychain_path_sha256 = identity_keychain_path_sha256(signing_keychain_path)
    source_root = validate_source_checkout(root, source_commit, source_tree)
    build_root = canonical_build_root(expected_build_root, source_root)
    if provenance_path.is_symlink() or not provenance_path.is_file():
        raise PackageError("build provenance must be a regular file")
    try:
        record = strict_json_loads(provenance_path.read_text())
    except (OSError, ValueError) as error:
        raise PackageError("cannot read clean-source build provenance") from error
    if (
        not isinstance(record, dict)
        or set(record) != BUILD_PROVENANCE_FIELDS
        or type(record.get("schemaVersion")) is not int
        or record.get("schemaVersion") != 6
        or record.get("repository") != "exterminatorrat/imrse"
    ):
        raise PackageError("unsupported clean-source build provenance schema")
    source_manifest_record = record.get("sourceInputManifest")
    build_inputs = record.get("buildInputs")
    build = record.get("build")
    product_record = record.get("product")
    if (
        not isinstance(source_manifest_record, dict)
        or set(source_manifest_record) != BUILD_PROVENANCE_SOURCE_INPUT_FIELDS
        or not isinstance(build_inputs, dict)
        or set(build_inputs) != BUILD_PROVENANCE_BUILD_INPUT_FIELDS
        or not isinstance(build, dict)
        or set(build) != BUILD_PROVENANCE_BUILD_FIELDS
        or not isinstance(product_record, dict)
        or set(product_record) != BUILD_PROVENANCE_PRODUCT_FIELDS
    ):
        raise PackageError("clean-source build provenance has unknown, missing, or invalid fields")
    try:
        validate_signature_receipt_schema(product_record.get("signatureReceipt"))
    except PackageError as error:
        raise PackageError("built product signature receipt does not match the verified signer and public metadata") from error
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
    if build_inputs.get("lockFilesSHA256") != expected_locks or build_inputs.get("resolvedDependencyPins") != read_pins(source_root):
        raise PackageError("build provenance dependency locks or pins do not match clean source")
    if (
        build.get("configuration") != "release"
        or build.get("workingDirectoryRelativePath") != "source"
        or build.get("command") != normalized_release_build_command()
        or build.get("commandPathValuesRelativeToBuildRoot") is not True
        or build.get("signingCertificateSHA1") != signing_certificate_sha1
        or build.get("identityKeychainPathSHA256") != signing_keychain_path_sha256
        or build.get("codesignExecutableSHA256") != codesign_pin.sha256
        or build.get("provenanceScope")
        != BUILD_PROVENANCE_SCOPE
    ):
        raise PackageError("build provenance does not match the isolated Release builder record")
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
    actual_signature_receipt = verify_bundle_signature_receipt(product_path, signing_certificate_sha1, signing_keychain_path, codesign_pin)
    if product_record.get("signatureReceipt") != actual_signature_receipt:
        raise PackageError("built product signature receipt does not match the verified signer and public signature metadata")
    validate_public_signing_execution_receipt(
        product_record.get("signingExecutionReceipt"),
        "builder",
        product_path,
        signing_certificate_sha1,
        signing_keychain_path,
        codesign_pin,
    )
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


def candidate_manifest(root, source, source_tree_hash, bundle, archive_hash, archive_size, runtime_modules, runtime_symbols, regression_output, build_record, build_record_hash, source_commit, source_tree, input_manifest_hash, candidate_signature_receipt, candidate_signing_execution_receipt, signing_keychain_path, codesign_pin):
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
    signing_keychain_path_sha256 = build.get("identityKeychainPathSHA256")
    codesign_executable_sha256 = build.get("codesignExecutableSHA256")
    product_record = build_record.get("product")
    if not isinstance(product_record, dict):
        raise PackageError("build product signature receipt is missing")
    build_signature_receipt = product_record.get("signatureReceipt")
    build_signing_execution_receipt = product_record.get("signingExecutionReceipt")
    for receipt in (build_signature_receipt, candidate_signature_receipt):
        try:
            validate_signature_receipt_schema(receipt)
        except PackageError as error:
            raise PackageError("build and candidate signature receipts do not match the selected certificate") from error
        code_items = receipt.get("codeItems") if isinstance(receipt, dict) else None
        if (
            not isinstance(receipt, dict)
            or receipt.get("certificateSHA1") != signing_certificate_sha1
            or receipt.get("identityKeychainPathSHA256") != signing_keychain_path_sha256
            or receipt.get("codesignExecutableSHA256") != codesign_executable_sha256
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
    validate_public_signing_execution_receipt(
        build_signing_execution_receipt,
        "builder",
        source,
        signing_certificate_sha1,
        signing_keychain_path,
        codesign_pin,
    )
    validate_public_signing_execution_receipt(
        candidate_signing_execution_receipt,
        "candidate",
        bundle,
        signing_certificate_sha1,
        signing_keychain_path,
        codesign_pin,
    )
    return {
        "schemaVersion": 6,
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
                "signingExecutionReceipt": build_signing_execution_receipt,
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
            "identityKeychainPathSHA256": signing_keychain_path_sha256,
            "codesignExecutableSHA256": codesign_executable_sha256,
            "signatureType": CERTIFICATE_SIGNING_LABEL,
            "timestamp": "none",
            "developerID": False,
            "notarized": False,
            "hardenedRuntime": False,
            "publicTrustedRelease": False,
            "buildProductReceipt": build_record["product"]["signatureReceipt"],
            "candidateReceipt": candidate_signature_receipt,
            "buildSigningExecutionReceipt": build_signing_execution_receipt,
            "candidateSigningExecutionReceipt": candidate_signing_execution_receipt,
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
            "pinnedCodesignExecutableMatchedForBuildAndCandidateCode": "passed",
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


def create_candidate(input_app, source_commit, source_tree, build_root, output, signing_certificate_sha1, signing_keychain_path, codesign_pin):
    signing_certificate_sha1 = normalize_certificate_sha1(signing_certificate_sha1)
    signing_keychain_path = normalize_signing_keychain_path(signing_keychain_path)
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
    build_record = validate_build_provenance(provenance_path, root, source, build_root, source_commit, source_tree, signing_certificate_sha1, signing_keychain_path, codesign_pin)
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
            candidate_receipt_path = stage / "private-candidate-signing-receipt.json"
            receipt_reservation = reserve_private_signing_receipt(candidate_receipt_path, staged_bundle)
            try:
                candidate_signing_result = sign_and_verify(staged_bundle, binaries, signing_certificate_sha1, signing_keychain_path, codesign_pin)
                write_private_signing_receipt(
                    receipt_reservation,
                    private_signing_receipt_payload(
                        candidate_signing_result,
                        "candidate",
                        staged_bundle,
                        signing_certificate_sha1,
                        signing_keychain_path,
                        codesign_pin,
                    ),
                )
            except Exception:
                close_private_signing_receipt_reservation(receipt_reservation, remove=True)
                raise
            close_private_signing_receipt_reservation(receipt_reservation)
            candidate_signing_execution = validate_private_signing_receipt(
                read_private_signing_receipt(candidate_receipt_path, staged_bundle),
                "candidate",
                staged_bundle,
                binaries,
                signing_certificate_sha1,
                signing_keychain_path,
                codesign_pin,
            )
            candidate_signature_receipt = candidate_signing_execution["signatureReceipt"]
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
            validate_build_provenance(provenance_path, root, source, build_root, source_commit, source_tree, signing_certificate_sha1, signing_keychain_path, codesign_pin)
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
                candidate_signing_execution["signingExecutionReceipt"],
                signing_keychain_path,
                codesign_pin,
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
    validate_build_provenance(provenance_path, root, source, build_root, source_commit, source_tree, signing_certificate_sha1, signing_keychain_path, codesign_pin)
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
    keychain_parser = subparsers.add_parser("validate-signing-keychain", help="validate and print an explicit signing identity keychain path")
    keychain_parser.add_argument("--path", required=True, type=Path)
    codesign_parser = subparsers.add_parser("validate-codesign-executable", help="validate and print an explicitly pinned codesign executable path")
    codesign_parser.add_argument("--path", required=True, type=Path)
    codesign_parser.add_argument("--sha256", required=True)
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
    record_parser.add_argument("--signing-keychain-path", required=True, type=Path)
    record_parser.add_argument("--codesign-executable", required=True, type=Path)
    record_parser.add_argument("--codesign-sha256", required=True)
    record_parser.add_argument("--signing-execution-receipt", required=True, type=Path)
    ci_parser = subparsers.add_parser("validate-ci-app", help="validate an unsigned, non-distribution CI package build")
    ci_parser.add_argument("--app", required=True, type=Path)
    ci_parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent.parent)
    ci_parser.add_argument("--configuration", required=True)
    sign_parser = subparsers.add_parser("sign-app", help="explicitly sign each bundled Mach-O and the app bundle")
    sign_parser.add_argument("--app", required=True, type=Path)
    sign_parser.add_argument("--signing-certificate-sha1", required=True)
    sign_parser.add_argument("--signing-keychain-path", required=True, type=Path)
    sign_parser.add_argument("--codesign-executable", required=True, type=Path)
    sign_parser.add_argument("--codesign-sha256", required=True)
    sign_parser.add_argument("--signing-execution-receipt", required=True, type=Path)
    package_parser = subparsers.add_parser("package", help="validate and package an existing built app")
    package_parser.add_argument("--app", required=True, type=Path)
    package_parser.add_argument("--source-commit", required=True)
    package_parser.add_argument("--source-tree", required=True)
    package_parser.add_argument("--build-root", required=True, type=Path)
    package_parser.add_argument("--output", required=True, type=Path)
    package_parser.add_argument("--signing-certificate-sha1", required=True)
    package_parser.add_argument("--signing-keychain-path", required=True, type=Path)
    package_parser.add_argument("--codesign-executable", required=True, type=Path)
    package_parser.add_argument("--codesign-sha256", required=True)
    args = parser.parse_args(argv)
    try:
        if args.action == "validate-signing-keychain":
            print(normalize_signing_keychain_path(args.path))
        elif args.action == "validate-codesign-executable":
            pin = pin_codesign_executable(args.path, args.sha256)
            print(pin.path)
        elif args.action == "prepare-source":
            source_root = validate_source_checkout(args.source_root, args.source_commit, args.source_tree)
            source_info = read_source_info(source_root)
            validate_app_version_metadata(source_info, source_info)
            copy_root, manifest_path = copy_source_inputs(args.source_root, args.source_commit, args.source_tree, args.build_root)
            print(f"Source input copy: {copy_root}")
            print(f"Source input manifest: {manifest_path}")
        elif args.action == "record-build":
            codesign_pin = pin_codesign_executable(args.codesign_executable, args.codesign_sha256)
            print(record_build_provenance(args.source_root, args.source_commit, args.source_tree, args.build_root, args.working_directory, args.build_command_arg, args.signing_certificate_sha1, args.signing_keychain_path, codesign_pin, args.signing_execution_receipt))
        elif args.action == "validate-ci-app":
            receipt_path = validate_ci_package_app(args.app.expanduser(), args.source_root, args.configuration)
            print(f"CI validation-only receipt: {receipt_path}")
        elif args.action == "sign-app":
            codesign_pin = pin_codesign_executable(args.codesign_executable, args.codesign_sha256)
            app = args.app.expanduser()
            reservation = reserve_private_signing_receipt(args.signing_execution_receipt, app)
            try:
                signing_result = sign_app_bundle(app, args.signing_certificate_sha1, args.signing_keychain_path, codesign_pin)
                write_private_signing_receipt(
                    reservation,
                    private_signing_receipt_payload(
                        signing_result,
                        "builder",
                        app,
                        args.signing_certificate_sha1,
                        args.signing_keychain_path,
                        codesign_pin,
                    ),
                )
            except Exception:
                close_private_signing_receipt_reservation(reservation, remove=True)
                raise
            close_private_signing_receipt_reservation(reservation)
            print("Signed and verified certificate-selected app; private execution receipt saved outside the app.")
        else:
            codesign_pin = pin_codesign_executable(args.codesign_executable, args.codesign_sha256)
            create_candidate(args.app, args.source_commit, args.source_tree, args.build_root, args.output, args.signing_certificate_sha1, args.signing_keychain_path, codesign_pin)
    except (PackageError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(f"candidate packaging failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
