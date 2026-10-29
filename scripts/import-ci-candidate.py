#!/usr/bin/env python3
import ast
import hashlib
import json
import os
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

import package_local_candidate as pkg
load = pkg.strict_json_loads
A, M, R, MAX, COUNT = (
    "imrse-ci-candidate-arm64.tar.gz",
    "candidate-provenance.json",
    "CI-PACKAGE-VALIDATION.json",
    2 * 1024**3,
    100_000,
)


class CandidateError(Exception):
    pass


def need(ok):
    if not ok:
        raise CandidateError("invalid")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def sha_ok(value, size=64):
    return isinstance(value, str) and re.fullmatch(rf"[0-9a-fA-F]{{{size}}}", value) is not None


def safe(name, directory=False):
    if directory and name.endswith("/"):
        name = name[:-1]
    need(
        name
        and "\\" not in name
        and "\0" not in name
        and not name.startswith("/")
        and not re.match(r"^[A-Za-z]:", name)
        and all(x not in {"", ".", ".."} for x in name.split("/"))
    )
    return name


def link(path, target):
    need(
        isinstance(target, str)
        and target
        and "\\" not in target
        and not target.startswith("/")
        and not re.match(r"^[A-Za-z]:", target)
    )
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
    need(resolved not in {".", ".."} and not resolved.startswith(("../", "/")))


def members(z):
    found, total = {}, 0
    infos = z.infolist()
    need(0 < len(infos) <= COUNT)
    for info in infos:
        directory, name = info.is_dir(), safe(info.filename, info.is_dir())
        kind = stat.S_IFMT(info.external_attr >> 16)
        need(kind in (0, stat.S_IFDIR if directory else stat.S_IFREG))
        need(name not in found and (not directory or not info.file_size))
        total += info.file_size
        need(total <= MAX)
        found[name] = info
    return found


def read_zip(z, info, limit=MAX, sink=None, raw=False):
    need(not info.is_dir() and info.file_size <= limit)
    digest, size, data = hashlib.sha256(), 0, bytearray()
    with z.open(info) as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            size += len(block)
            need(size <= limit)
            digest.update(block)
            if sink:
                sink.write(block)
            elif raw:
                data.extend(block)
    need(size == info.file_size)
    return bytes(data) if raw else digest.hexdigest()


def git_id(root):
    return tuple(
        subprocess.check_output(["git", "-C", str(root), "rev-parse", rev], text=True).strip().lower()
        for rev in ("HEAD^{commit}", "HEAD^{tree}")
    )


def approved_extensions(root, commit):
    source = subprocess.check_output(
        ["git", "-C", str(root), "show", f"{commit}:scripts/enable-ci-extensions.py"], text=True
    )
    tree = ast.parse(source)
    assignment = next(
        node
        for node in tree.body
        if isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == "PACKAGES" for target in node.targets)
    )
    packages = ast.literal_eval(assignment.value)
    need(tuple(packages) == ("mlx-swift", "mlx-swift-lm"))
    records = []
    for identity, spec in packages.items():
        entry = {"fingerprint": spec["revision"], "packageIdentity": identity, "targetName": spec["target"]}
        records.append(
            {
                "identity": identity,
                "url": spec["url"],
                "version": spec["version"],
                "revision": spec["revision"],
                "sourceSHA256": spec["sources"],
                "registryEntry": entry,
            }
        )
    return {"schemaVersion": 1, "packages": records}


def verify(m, expected, root, z, files):
    need(git_id(root) == expected[:2])
    need(isinstance(m, dict) and m.get("schemaVersion") == 1)
    source, ci, build, dependencies = (m[key] for key in ("source", "ci", "build", "dependencies"))
    need(
        source["commitSHA"].lower() == expected[0] == source["selectedCommitSHA"].lower()
        and source["treeSHA"].lower() == expected[1]
        and ci["runID"] == expected[2]
        and ci["runAttempt"] == expected[3]
    )
    for digest, name in (
        (build.get("buildLogSHA256"), "build.log"),
        (build.get("eventsourceTestLogSHA256"), "eventsource-tests.log"),
        (dependencies.get("rootGraphSHA256"), "root-effective-dependency-graph.json"),
    ):
        need(sha_ok(digest) and name in files and read_zip(z, files[name]) == digest)
    extension = load(read_zip(z, files["extension-enablement.json"], 16 * 1024**2, raw=True))
    need(
        isinstance(extension, dict)
        and type(extension.get("schemaVersion")) is int
        and extension == approved_extensions(root, expected[0])
    )
    lock = root / "Package.resolved"
    need(not lock.is_symlink() and pkg.sha256_file(lock) == dependencies["packageResolvedSHA256"])
    app, entries = m["app"], m["app"]["inventory"]
    need(isinstance(entries, list) and 0 < len(entries) <= COUNT)
    inventory = {}
    for entry in entries:
        need(isinstance(entry, dict) and isinstance(entry.get("path"), str))
        path, kind, mode = entry["path"], entry["type"], entry["mode"]
        if path != ".":
            safe(path)
        need(kind in {"directory", "file", "symlink"} and path not in inventory and type(mode) is int)
        need(0 <= mode <= 0o777)
        if kind == "file":
            need(type(entry["size"]) is int and 0 <= entry["size"] <= MAX and sha_ok(entry["sha256"]))
        elif kind == "directory":
            need(mode & 0o500 == 0o500)
        else:
            link(path, entry["target"])
        inventory[path] = entry
    need(inventory.get(".", {}).get("type") == "directory")
    for path in inventory:
        parts = path.split("/")
        need(
            all(
                inventory.get("/".join(parts[:index]), {}).get("type") == "directory"
                for index in range(1, len(parts))
            )
        )
    receipt_path = "Contents/Resources/" + R
    need(inventory[receipt_path]["type"] == "file" and inventory[receipt_path]["size"] <= 16 * 1024**2)
    tree_hash = sha(json.dumps(entries, sort_keys=True, separators=(",", ":")).encode())
    need(tree_hash == app["bundleTreeSHA256"])
    archive = m["archive"]
    need(archive["file"] == A and archive["format"] == "tar.gz; Unix modes preserved" and sha_ok(archive["sha256"]))
    return inventory, tree_hash, archive["sha256"], dependencies["packageResolvedSHA256"]


def extract_file(tar, member, path, mode):
    source = tar.extractfile(member)
    need(source is not None)
    with source, path.open("xb") as output:
        shutil.copyfileobj(source, output, 1024 * 1024)
    os.chmod(path, mode)


def scan(tar, inventory, out):
    seen, total = set(), 0
    app = out / "imrse.app"
    directories = sorted(
        ((path, entry) for path, entry in inventory.items() if entry["type"] == "directory"),
        key=lambda item: item[0].count("/"),
    )
    for path, _ in directories:
        (app if path == "." else app / path).mkdir(mode=0o700)
    for member in tar:
        need(len(seen) < COUNT)
        name = safe(member.name, member.isdir())
        need(name == "imrse.app" or name.startswith("imrse.app/"))
        path = "." if name == "imrse.app" else name[10:]
        need(path not in seen and path in inventory)
        seen.add(path)
        entry = inventory[path]
        kind = "directory" if member.isdir() else "file" if member.isreg() else "symlink" if member.issym() else None
        need(
            kind == entry["type"]
            and stat.S_IMODE(member.mode) == entry["mode"]
            and not getattr(member, "sparse", None)
        )
        target = app if path == "." else app / path
        if kind == "directory":
            need(member.size == 0)
        elif kind == "symlink":
            link(path, member.linkname)
            need(member.size == 0 and member.linkname == entry["target"])
            os.symlink(member.linkname, target)
        else:
            total += member.size
            need(member.size == entry["size"] and total <= MAX)
            extract_file(tar, member, target, entry["mode"])
    need(seen == set(inventory))
    for path, entry in reversed(directories):
        os.chmod(app if path == "." else app / path, entry["mode"])


def check_receipt(raw, inventory, expected):
    receipt = load(raw)
    need(isinstance(receipt, dict))
    source, product = receipt.get("source"), receipt.get("product")
    executable = inventory.get("Contents/MacOS/imrse")
    architectures = product.get("machoArchitectures") if isinstance(product, dict) else None
    claims = {
        "schemaVersion": 1,
        "validationMode": "unsigned-ci-package-validation-only",
        "distributionEligible": False,
        "codeSigningPerformed": False,
        "releaseBuildProvenanceCreated": False,
        "signingCertificateSHA1": None,
        "signatureReceipt": None,
    }
    need(
        isinstance(source, dict)
        and set(source) == {"commitSHA", "treeSHA"}
        and source == {"commitSHA": expected[0], "treeSHA": expected[1]}
        and executable
        and executable["type"] == "file"
        and all(receipt.get(key) == value for key, value in claims.items())
        and isinstance(product, dict)
        and product.get("executableSHA256") == executable["sha256"]
        and product.get("bundleIdentifier") == "org.imrse.app"
        and product.get("hostArchitecture") == "arm64"
        and isinstance(architectures, dict)
        and architectures.get("Contents/MacOS/imrse") == "arm64"
        and all(value == "arm64" for value in architectures.values())
    )


def import_candidate(zip_path, expected_sha, source_root, commit, tree, run_id, attempt, output_dir):
    need(
        sha_ok(expected_sha)
        and sha_ok(commit, 40)
        and sha_ok(tree, 40)
        and run_id.isdigit()
        and attempt.isdigit()
    )
    zip_path = Path(zip_path).expanduser()
    zinfo = zip_path.lstat()
    need(
        stat.S_ISREG(zinfo.st_mode)
        and zinfo.st_size <= MAX
        and pkg.sha256_file(zip_path).lower() == expected_sha.lower()
    )
    root = Path(source_root).expanduser().resolve(strict=True)
    e = (commit.lower(), tree.lower(), run_id, attempt)
    out = Path(output_dir).expanduser()
    if not out.is_absolute():
        out = Path.cwd() / out
    need(out.name not in {"", ".", ".."})
    out = out.parent.resolve(strict=True) / out.name
    need(not os.path.lexists(out) and out != root and not out.is_relative_to(root))
    with zipfile.ZipFile(zip_path) as z:
        files = members(z)
        required = (
            A,
            M,
            "build.log",
            "eventsource-tests.log",
            "root-effective-dependency-graph.json",
            "extension-enablement.json",
        )
        need(all(name in files and not files[name].is_dir() for name in required))
        raw = read_zip(z, files[M], 16 * 1024**2, raw=True)
        inventory, tree_hash, archive_hash, lock_hash = verify(load(raw), e, root, z, files)
        with tempfile.TemporaryFile() as inner:
            need(read_zip(z, files[A], MAX, inner) == archive_hash)
            inner.seek(0)
            with tarfile.open(fileobj=inner, mode="r|gz") as tar:
                evidence = {
                    "schemaVersion": 1,
                    "scope": "unsigned CI only; no signing, conversion, local build, or delivery",
                    "artifactSHA256": expected_sha.lower(),
                    "archiveSHA256": archive_hash,
                    "source": {"commitSHA": e[0], "treeSHA": e[1]},
                    "ci": {"runID": run_id, "runAttempt": attempt},
                    "checksums": [
                        {"file": "imrse.app", "bundleTreeSHA256": tree_hash},
                        {"file": M, "sha256": sha(raw)},
                    ],
                }
                out.mkdir(mode=0o700)
                identity = (out.stat().st_dev, out.stat().st_ino)
                try:
                    os.chmod(out, 0o700)
                    scan(tar, inventory, out)
                    app = out / "imrse.app"
                    pkg.validate_symlinks(app)
                    need(pkg.bundle_tree_sha256(app) == tree_hash)
                    check_receipt((app / "Contents/Resources" / R).read_bytes(), inventory, e)
                    need(
                        pkg.sha256_file(root / "Package.resolved") == lock_hash
                        and git_id(root) == e[:2]
                    )
                    (out / M).write_bytes(raw)
                    os.chmod(out / M, 0o600)
                    receipt_path = out / "candidate-import-receipt.json"
                    receipt_path.write_text(json.dumps(evidence, sort_keys=True, indent=2) + "\n")
                    os.chmod(receipt_path, 0o600)
                except Exception:
                    try:
                        current = out.lstat()
                        if (
                            (current.st_dev, current.st_ino) == identity
                            and stat.S_ISDIR(current.st_mode)
                        ):
                            shutil.rmtree(out)
                    finally:
                        raise
    return out


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 8:
        print("args: ZIP SHA ROOT COMMIT TREE RUN ATTEMPT OUT", file=sys.stderr)
        return 2
    try:
        print("Unsigned CI:", import_candidate(*argv))
    except Exception as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
