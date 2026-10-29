#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import platform
import stat
import subprocess
import sys
from pathlib import Path

PACKAGES = {
    "mlx-swift": {
        "url": "https://github.com/ml-explore/mlx-swift", "version": "0.31.6",
        "revision": "0bb916c67f4b9e5c682cbe02a42c701c93ab5021", "target": "CudaBuild",
        "registry": "plugins.json",
        "sources": {"Plugins/CudaBuild/plugin.swift": "a4bc7bf7c4c68125b8ac83fb8a609a628a1d23398cb627542ce193f3c012da17"},
    },
    "mlx-swift-lm": {
        "url": "https://github.com/ml-explore/mlx-swift-lm.git", "version": "3.31.4",
        "revision": "bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57", "target": "MLXHuggingFaceMacros",
        "registry": "macros.json",
        "sources": {
            "Package.swift": "f03c532f6e128c04cc76fa5d92d05fd3bc1408ab9a883f86605bb9866725ffa2",
            "Libraries/MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift": "babb5b059ec3734c778a783bbb10106ded8b6c442b9059702d3cd32abcf82353",
        },
    },
}
NOFOLLOW, DIRECTORY = getattr(os, "O_NOFOLLOW", 0), getattr(os, "O_DIRECTORY", 0)


class EnableError(ValueError):
    pass


def need(value, message):
    if not value:
        raise EnableError(message)


def read_file(path):
    with os.fdopen(os.open(path, os.O_RDONLY | NOFOLLOW), "rb") as file:
        info = os.fstat(file.fileno())
        need(stat.S_ISREG(info.st_mode) and info.st_size <= 4 * 1024 * 1024, "required source is unsafe")
        return file.read()


def git_output(checkout, *args):
    return subprocess.check_output(["git", "-C", str(checkout), *args], stderr=subprocess.DEVNULL,
                                   text=True, timeout=20).strip()


def source_hash(checkout, relative):
    path, parts = checkout, Path(relative).parts
    for part in parts[:-1]:
        path /= part
        need(path.is_dir() and not path.is_symlink(), "approved source path is unsafe")
    return hashlib.sha256(read_file(path / parts[-1])).hexdigest()


def validate_source(root):
    pins = json.loads(read_file(root / "Package.resolved"))
    pins = pins.get("pins") if isinstance(pins, dict) else None
    need(isinstance(pins, list), "missing root pins")
    checkouts = root / ".build" / "checkouts"
    for path in (root / ".build", checkouts):
        need(path.is_dir() and not path.is_symlink(), "unsafe root checkouts")
    registries, packages = {}, []
    for identity, spec in PACKAGES.items():
        matches = [p for p in pins if isinstance(p, dict) and p.get("identity") == identity]
        need(len(matches) == 1, "root Package.resolved has an unexpected approved-package count")
        pin = matches[0]
        state = pin.get("state")
        need(isinstance(state, dict) and
             (pin.get("kind"), pin.get("location"), state.get("version"), state.get("revision")) ==
             ("remoteSourceControl", spec["url"], spec["version"], spec["revision"]),
             "root Package.resolved differs from approved pins")
        checkout = checkouts / identity
        need(checkout.is_dir() and not checkout.is_symlink(), "unsafe package checkout")
        need(git_output(checkout, "rev-parse", "HEAD") == spec["revision"],
             "package checkout revision differs from the approved pin")
        need(not git_output(checkout, "status", "--porcelain", "--untracked-files=all"),
             "package checkout is not clean")
        hashes = {source: source_hash(checkout, source) for source in spec["sources"]}
        need(hashes == spec["sources"], "approved extension source hash changed")
        entry = {"fingerprint": spec["revision"], "packageIdentity": identity, "targetName": spec["target"]}
        registries[spec["registry"]] = [entry]
        packages.append({"identity": identity, "url": spec["url"], "version": spec["version"], "revision": spec["revision"],
                         "sourceSHA256": hashes, "registryEntry": entry})
    return registries, {"schemaVersion": 1, "packages": packages}


def open_directory(path, create=False):
    fd = os.open("/", os.O_RDONLY | DIRECTORY | NOFOLLOW)
    try:
        for part in Path(os.path.abspath(path)).parts[1:]:
            try:
                next_fd = os.open(part, os.O_RDONLY | DIRECTORY | NOFOLLOW, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise
                os.mkdir(part, 0o700, dir_fd=fd)
                next_fd = os.open(part, os.O_RDONLY | DIRECTORY | NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def require_absent(directory, name):
    try:
        os.stat(name, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        return
    raise EnableError("refusing to overwrite an existing destination")


def put_file(directory, name, data):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600, dir_fd=directory)
    try:
        with os.fdopen(fd, "wb") as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
    except BaseException:
        try:
            os.unlink(name, dir_fd=directory)
        except FileNotFoundError:
            pass
        raise


def read_named(directory, name):
    with os.fdopen(os.open(name, os.O_RDONLY | NOFOLLOW, dir_fd=directory), "rb") as file:
        return file.read()


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def enable(source_root, receipt_path):
    need((os.environ.get("GITHUB_ACTIONS"), os.environ.get("RUNNER_ENVIRONMENT"), os.environ.get("RUNNER_OS"),
          os.environ.get("RUNNER_ARCH"), platform.system(), platform.machine().lower()) ==
         ("true", "github-hosted", "macOS", "ARM64", "Darwin", "arm64"), "requires GitHub-hosted macOS ARM64")
    root = Path(source_root).expanduser().resolve(strict=True)
    registries, receipt = validate_source(root)
    receipt_path = Path(os.path.abspath(Path(receipt_path).expanduser()))
    need(receipt_path.name not in ("", ".", "..") and
         os.path.commonpath((str(root), str(receipt_path))) != str(root), "receipt must be outside source checkout")
    security = Path.home() / "Library/org.swift.swiftpm/security"
    need(os.path.commonpath((str(security), str(receipt_path.parent))) != str(security),
         "receipt must be outside SwiftPM trust directory")
    receipt_dir = open_directory(receipt_path.parent)
    fds = [receipt_dir]
    try:
        require_absent(receipt_dir, receipt_path.name)
        library_fd = open_directory(Path.home() / "Library")
        fds.append(library_fd)
        try:
            security_fd = open_directory(security)
        except FileNotFoundError:
            security_fd = None
        if security_fd is not None:
            for name in registries:
                require_absent(security_fd, name)
        if security_fd is None:
            security_fd = open_directory(security, create=True)
        fds.append(security_fd)
        payloads = {name: json_bytes(value) for name, value in registries.items()}
        receipt_bytes = json_bytes(receipt)
        for name, payload in payloads.items():
            put_file(security_fd, name, payload)
        put_file(receipt_dir, receipt_path.name, receipt_bytes)
        for name, payload in payloads.items():
            need(read_named(security_fd, name) == payload, "SwiftPM registry readback did not match")
        need(read_named(receipt_dir, receipt_path.name) == receipt_bytes, "receipt readback did not match")
    finally:
        for fd in reversed(fds):
            os.close(fd)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    try:
        args = parser.parse_args()
        enable(args.source_root, args.receipt)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr); return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
