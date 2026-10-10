# imrse macOS runtime third-party notices

This inventory lists third-party packages and pinned revisions from `Package.resolved`, with module names and symbols to verify against the final arm64 `imrse` executable. The module and symbol names are not evidence that a particular candidate contains those dependencies. Before any candidate is published, its exact executable must be checked with `nm -arch arm64 -j`, `swift-demangle`, and `nm -arch arm64 -gU -j`, then matched to the same source revision and dependency pins. The corresponding license texts are in `ThirdPartyLicenses/` within the app's resources.

| Package | Version | Resolved revision | Expected runtime module or symbol to verify | License text |
| --- | --- | --- | --- | --- |
| eventsource (`EventSource`) | 1.5.1 | `86b5096ac59ab46e66bd1f6377c604bc1dab0bc2` | `EventSource` | `ThirdPartyLicenses/EventSource-LICENSE.md` |
| lottie-ios | 4.6.1 | `f4db77d7feacba0c2360b84a40c38a6ce8ff399d` | `Lottie` | `ThirdPartyLicenses/lottie-ios-LICENSE` |
| mlx-swift | 0.31.6 | `0bb916c67f4b9e5c682cbe02a42c701c93ab5021` | `MLX`, `MLXNN`, `MLXOptimizers` | `ThirdPartyLicenses/mlx-swift-LICENSE`; `ThirdPartyLicenses/mlx-core-LICENSE` |
| mlx-swift-lm | 3.31.4 | `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57` | `MLXHuggingFace`, `MLXLLM`, `MLXLMCommon` | `ThirdPartyLicenses/mlx-swift-lm-LICENSE` |
| swift-argument-parser | 1.8.2 | `6a52f3251125d74daf04fcbd5e6f08a75d074382` | `ArgumentParser`, `ArgumentParserToolInfo` | `ThirdPartyLicenses/swift-argument-parser-LICENSE.txt` |
| swift-collections | 1.7.1 | `98ef3c98609a1e31b7e157b5b619579001a789d6` | `InternalCollectionsUtilities`, `OrderedCollections` | `ThirdPartyLicenses/swift-collections-LICENSE.txt` |
| swift-crypto | 4.5.2 | `da9d28d69ebe3894b18376c8f2395c2f37b8448f` | `Crypto` | `ThirdPartyLicenses/swift-crypto-LICENSE.txt` |
| swift-huggingface | 0.9.0 | `b721959445b617d0bf03910b2b4aced345fd93bf` | `HuggingFace` | `ThirdPartyLicenses/swift-huggingface-LICENSE` |
| swift-jinja | 2.5.1 | `4588064a20f3fc093c95f2f7d3359999bf30cae5` | `Jinja` | `ThirdPartyLicenses/swift-jinja-LICENSE` |
| swift-numerics | 1.1.1 | `0c0290ff6b24942dadb83a929ffaaa1481df04a2` | `ComplexModule`, `RealModule` | `ThirdPartyLicenses/swift-numerics-LICENSE.txt` |
| swift-transformers | 1.3.0 | `b38443e44d93eca770f2eb68e2a4d0fa100f9aa2` | `Hub`, `Tokenizers` | `ThirdPartyLicenses/swift-transformers-LICENSE` |
| yyjson | 0.12.0 | `8b4a38dc994a110abaec8a400615567bd996105f` | Exported C symbol `_yyjson_read_opts` | `ThirdPartyLicenses/yyjson-LICENSE` |

The pinned MLX Swift package includes MLX core code; its license is supplied separately as `ThirdPartyLicenses/mlx-core-LICENSE`. The app also contains artwork derived from 21st.dev Agent Elements; its original MIT license is `AgentElements-LICENSE`. `imrse`'s MIT license is `IMRSE-LICENSE.txt`.

`PillKit-Source-Dependency-Notice.md` preserves the original pill-kit source notice byte-for-byte. It describes that source kit, not this app's compiled runtime inventory. Additional license texts retained in `ThirdPartyLicenses/` are supplied verbatim; their presence alone does not claim that the corresponding package code is part of the runtime executable. The Qwen3 Apache license is included with the MLX resource bundle, but no model weights, model configuration, presets, credentials, or user data are bundled.

This notice is a packaging inventory, not a legal opinion or a certification that all upstream licensing obligations have been met.
