import hashlib


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
    }, {
        "path": "Source/MLXNN/Module.swift",
        "originalSHA256": "41949db53925fc89ad79459d4ca8f16b051ae9f1470c1a385d2728626c210de6",
        "patchedSHA256": "df2f9160fda6929ac38052da973a61a87532b0e31772bafb47f5d0ea6b1a4e3c",
        "originalSize": 61690,
        "patchedSize": 61628,
        "replacements": [{
            "oldText": "if let value = value as? T {\n                return value",
            "newText": "if let value = (value as Any) as? T {\n                return value",
        }, {
            "oldText": "if let module = module as? T {\n                return module",
            "newText": "if let module = (module as Any) as? T {\n                return module",
        }, {
            "oldText": "            default:\n                fatalError(\"Unexpected leaf \\(vk) = \\(v)\")\n",
            "newText": "",
        }],
    }],
}
GETTER_LOG = "mlx-getter-compatibility-tests.log"
GETTER_MARKER = "MLX getter compatibility checks passed."


def getter_log_digest(raw):
    try:
        lines = raw.decode("utf-8").splitlines()
    except (AttributeError, UnicodeDecodeError) as error:
        raise ValueError("invalid MLX getter compatibility log") from error
    if not lines or lines[-1] != GETTER_MARKER:
        raise ValueError("MLX getter compatibility log lacks its completion marker")
    return hashlib.sha256(raw).hexdigest()
