import hashlib
import json


MLX_LICENSE = b"synthetic upstream MLX license\n"
MLX_PATCH = {
    "schemaVersion": 1,
    "identity": "mlx-swift",
    "version": "0.31.6",
    "url": "https://github.com/ml-explore/mlx-swift",
    "revision": "0bb916c67f4b9e5c682cbe02a42c701c93ab5021",
    "license": {"path": "LICENSE", "sha256": hashlib.sha256(MLX_LICENSE).hexdigest()},
    "files": [{
        "path": "Source/MLX/MLXArray+maskFill.swift",
        "originalSHA256": "e" * 64,
        "patchedSHA256": "f" * 64,
        "originalSize": 495,
        "patchedSize": 491,
        "oldText": "guard let info = dtype.finfo else {",
        "newText": "guard dtype.finfo != nil else {",
    }],
}
MLX_PATCH_BYTES = (json.dumps(MLX_PATCH, sort_keys=True, separators=(",", ":")) + "\n").encode()

PARSER_LICENSE = b"synthetic upstream swift-argument-parser license\n"
PARSER_PATCH = {
    "schemaVersion": 1,
    "identity": "swift-argument-parser",
    "version": "1.8.2",
    "url": "https://github.com/apple/swift-argument-parser",
    "revision": "6a52f3251125d74daf04fcbd5e6f08a75d074382",
    "license": {"path": "LICENSE.txt", "sha256": hashlib.sha256(PARSER_LICENSE).hexdigest()},
    "files": [
        {"path": "Sources/ArgumentParser/Parsable Types/ParsableArguments.swift",
         "originalSHA256": "a" * 64, "patchedSHA256": "b" * 64, "originalSize": 120,
         "patchedSize": 80, "removedAnnotation": '@available(*, deprecated, message: "Use _errorPrefix instead.")'},
        {"path": "Sources/ArgumentParserToolInfo/ToolInfo.swift",
         "originalSHA256": "c" * 64, "patchedSHA256": "d" * 64, "originalSize": 121,
         "patchedSize": 81, "removedAnnotation": '@available(*, deprecated, message: "Use custom instead.")'},
    ],
}
PARSER_BYTES = (json.dumps(PARSER_PATCH, sort_keys=True, separators=(",", ":")) + "\n").encode()
