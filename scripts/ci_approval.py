import ast
import hashlib
import json
import re
import subprocess
import tarfile


PATCH_HELPER = "scripts/patch-argument-parser.py"
PATCH_SCOPE = (
    ("Sources/ArgumentParser/Parsable Types/ParsableArguments.swift",
     '@available(*, deprecated, message: "Use _errorPrefix instead.")'),
    ("Sources/ArgumentParserToolInfo/ToolInfo.swift",
     '@available(*, deprecated, message: "Use custom instead.")'),
)
PATCH_FIELDS = {"path", "originalSHA256", "patchedSHA256", "originalSize", "patchedSize", "removedAnnotation"}
MLX_PATCH_HELPER = "scripts/patch-mlx-mask-fill.py"
MLX_PATCH = {
    "schemaVersion": 1,
    "identity": "mlx-swift",
    "version": "0.31.6",
    "url": "https://github.com/ml-explore/mlx-swift",
    "revision": "0bb916c67f4b9e5c682cbe02a42c701c93ab5021",
    "license": {"path": "LICENSE", "sha256": "44326a4ea062241ae6fc26ee2ec90bdc81af7eb7b9d3966181b733fa69d42057"},
    "files": [{
        "path": "Source/MLX/MLXArray+maskFill.swift",
        "originalSHA256": "5e6ae4e844cbd2ea61032a3c45e5281248072a350be012ae6409ade2250920fe",
        "patchedSHA256": "391cde3f3480fe9fd434b5ce4bcd4a55166e06db18a7c5a0e1577f43f06a4063",
        "originalSize": 495,
        "patchedSize": 491,
        "oldText": "guard let info = dtype.finfo else {",
        "newText": "guard dtype.finfo != nil else {",
    }],
}
MLX_APP_RECEIPT = "Contents/Resources/ThirdPartyLicenses/mlx-swift-COMPATIBILITY.json"
MLX_APP_LICENSE = "Contents/Resources/ThirdPartyLicenses/mlx-swift-LICENSE"
PATCH_APP_RECEIPT = "Contents/Resources/ThirdPartyLicenses/swift-argument-parser-COMPATIBILITY.json"


def _need(condition):
    if not condition:
        raise ValueError("invalid committed CI approval")


def _sha256(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def committed_literal(root, commit, path, name):
    try:
        source = subprocess.check_output(["git", "-C", str(root), "show", f"{commit}:{path}"], text=True)
        tree = ast.parse(source)
    except (OSError, subprocess.SubprocessError, SyntaxError) as error:
        raise ValueError("committed CI approval is unavailable") from error
    values = [node.value for node in tree.body if isinstance(node, ast.Assign) and len(node.targets) == 1
              and isinstance(node.targets[0], ast.Name) and node.targets[0].id == name]
    _need(len(values) == 1)
    try:
        return ast.literal_eval(values[0])
    except (ValueError, TypeError, SyntaxError) as error:
        raise ValueError("committed CI approval is not literal data") from error


def approved_patch(root, commit):
    value = committed_literal(root, commit, PATCH_HELPER, "APPROVED_PATCH")
    _need(
        isinstance(value, dict)
        and set(value) == {"schemaVersion", "identity", "version", "url", "revision", "license", "files"}
        and type(value.get("schemaVersion")) is int and value["schemaVersion"] == 1
        and (value.get("identity"), value.get("version"), value.get("url"), value.get("revision")) ==
        ("swift-argument-parser", "1.8.2", "https://github.com/apple/swift-argument-parser",
         "6a52f3251125d74daf04fcbd5e6f08a75d074382")
    )
    license_record, files = value["license"], value["files"]
    _need(isinstance(license_record, dict) and set(license_record) == {"path", "sha256"}
          and license_record.get("path") == "LICENSE.txt" and _sha256(license_record.get("sha256"))
          and isinstance(files, list) and len(files) == len(PATCH_SCOPE))
    _need(all(
        isinstance(item, dict) and set(item) == PATCH_FIELDS and item["path"] == path
        and item["removedAnnotation"] == annotation and _sha256(item["originalSHA256"])
        and _sha256(item["patchedSHA256"]) and type(item["originalSize"]) is int and item["originalSize"] >= 0
        and type(item["patchedSize"]) is int and item["patchedSize"] >= 0
        for item, (path, annotation) in zip(files, PATCH_SCOPE)
    ))
    return value


def approved_mlx_patch(root, commit):
    value = committed_literal(root, commit, MLX_PATCH_HELPER, "APPROVED_MLX_PATCH")
    _need(isinstance(value, dict) and type(value.get("schemaVersion")) is int and value == MLX_PATCH)
    return value


def approved_extensions(root, commit):
    packages = committed_literal(root, commit, "scripts/enable-ci-extensions.py", "PACKAGES")
    _need(tuple(packages) == ("mlx-swift", "mlx-swift-lm"))
    records = []
    for identity, spec in packages.items():
        entry = {"fingerprint": spec["revision"], "packageIdentity": identity, "targetName": spec["target"]}
        records.append({"identity": identity, "url": spec["url"], "version": spec["version"],
                        "revision": spec["revision"], "sourceSHA256": spec["sources"], "registryEntry": entry})
    return {"schemaVersion": 1, "packages": records}


def validate_mlx_inventory(patch, inventory, receipt):
    _need(isinstance(inventory, dict) and isinstance(patch, dict))
    canonical = (json.dumps(patch, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
    _need(receipt == canonical)
    receipt_entry, license_entry = inventory.get(MLX_APP_RECEIPT), inventory.get(MLX_APP_LICENSE)
    license_record = patch.get("license")
    _need(isinstance(license_record, dict) and set(license_record) == {"path", "sha256"}
          and license_record.get("path") == "LICENSE" and _sha256(license_record.get("sha256")))
    _need(isinstance(receipt_entry, dict) and receipt_entry.get("type") == "file"
          and type(receipt_entry.get("size")) is int and receipt_entry["size"] == len(canonical)
          and receipt_entry.get("sha256") == hashlib.sha256(canonical).hexdigest())
    _need(isinstance(license_entry, dict) and license_entry.get("type") == "file"
          and type(license_entry.get("size")) is int and license_entry["size"] >= 0
          and license_entry.get("sha256") == license_record["sha256"])


def validate_mlx_receipt(patch, receipt, dependencies, inventory):
    _need(isinstance(dependencies, dict) and _sha256(dependencies.get("mlxMaskFillPatchReceiptSHA256"))
          and dependencies["mlxMaskFillPatchReceiptSHA256"] == hashlib.sha256(receipt).hexdigest())
    validate_mlx_inventory(patch, inventory, receipt)
    return patch["license"]["sha256"]


def preflight_candidate_archive(inner, patch_receipt, mlx_receipt, mlx_license_hash, max_members, max_bytes):
    inner.seek(0)
    receipts = {
        "imrse.app/" + PATCH_APP_RECEIPT: patch_receipt,
        "imrse.app/" + MLX_APP_RECEIPT: mlx_receipt,
    }
    found, count, total = set(), 0, 0
    with tarfile.open(fileobj=inner, mode="r|gz") as archive:
        for member in archive:
            count, total = count + 1, total + member.size
            _need(count <= max_members and 0 <= member.size and total <= max_bytes)
            if member.name in receipts:
                expected = receipts[member.name]
                _need(member.name not in found and member.isfile() and member.size == len(expected))
                source = archive.extractfile(member)
                _need(source is not None)
                with source:
                    _need(source.read(len(expected) + 1) == expected)
                found.add(member.name)
            elif member.name == "imrse.app/" + MLX_APP_LICENSE:
                _need(MLX_APP_LICENSE not in found and member.isfile() and member.size <= 16 * 1024**2)
                source = archive.extractfile(member)
                _need(source is not None)
                with source:
                    digest, size = hashlib.sha256(), 0
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        size += len(block)
                        _need(size <= 16 * 1024**2)
                        digest.update(block)
                _need(digest.hexdigest() == mlx_license_hash)
                found.add(MLX_APP_LICENSE)
    _need(found == {"imrse.app/" + PATCH_APP_RECEIPT, "imrse.app/" + MLX_APP_RECEIPT, MLX_APP_LICENSE})
    inner.seek(0)
