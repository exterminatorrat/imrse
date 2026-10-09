#!/bin/bash
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$SOURCE_ROOT"
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'The native app requires macOS. Run swift test for the portable modules.\n' >&2
  exit 1
fi
CONFIGURATION="${CONFIGURATION:-release}"
CI_PACKAGE_VALIDATION="${IMRSE_CI_PACKAGE_VALIDATION:-0}"
CI_BUILD_TRIPLE=""
if [[ "$CI_PACKAGE_VALIDATION" != "0" && "$CI_PACKAGE_VALIDATION" != "1" ]]; then
  printf 'IMRSE_CI_PACKAGE_VALIDATION must be 0 or 1.\n' >&2
  exit 1
fi
RELEASE_COMMIT="${IMRSE_RELEASE_SOURCE_COMMIT:-}"
RELEASE_TREE="${IMRSE_RELEASE_SOURCE_TREE:-}"
RELEASE_BUILD_ROOT="${IMRSE_RELEASE_BUILD_ROOT:-}"
SIGNING_CERTIFICATE_SHA1="${IMRSE_SIGNING_CERTIFICATE_SHA1:-}"
if [[ "$CI_PACKAGE_VALIDATION" == "1" ]]; then
  if [[ -n "$SIGNING_CERTIFICATE_SHA1" || -n "$RELEASE_COMMIT$RELEASE_TREE$RELEASE_BUILD_ROOT" ]]; then
    printf 'CI package validation cannot use a signing selector or Release provenance inputs.\n' >&2
    exit 1
  fi
  if [[ "$CONFIGURATION" != "release" ]]; then
    printf 'CI package validation requires CONFIGURATION=release.\n' >&2
    exit 1
  fi
  CI_HOST_ARCHITECTURE="$(uname -m)"
  case "$CI_HOST_ARCHITECTURE" in
    arm64|aarch64) CI_BUILD_TRIPLE="arm64-apple-macosx14.0" ;;
    x86_64|amd64) CI_BUILD_TRIPLE="x86_64-apple-macosx14.0" ;;
    *)
      printf 'CI package validation does not support host architecture %s.\n' "$CI_HOST_ARCHITECTURE" >&2
      exit 1
      ;;
  esac
  CI_DIST_DIR="${IMRSE_DIST_DIR:-}"
  if [[ -z "$CI_DIST_DIR" || "$CI_DIST_DIR" != /* || -e "$CI_DIST_DIR" || -L "$CI_DIST_DIR" ]]; then
    printf 'CI package validation requires a new absolute IMRSE_DIST_DIR outside the source checkout.\n' >&2
    exit 1
  fi
  CI_DIST_PARENT="$(cd "$(dirname "$CI_DIST_DIR")" && pwd -P)"
  CI_DIST_NAME="$(basename "$CI_DIST_DIR")"
  if [[ "$CI_DIST_NAME" == "." || "$CI_DIST_NAME" == ".." || "$CI_DIST_PARENT" == "$SOURCE_ROOT" || "$CI_DIST_PARENT" == "$SOURCE_ROOT/"* ]]; then
    printf 'CI package validation output must be outside the source checkout.\n' >&2
    exit 1
  fi
  IMRSE_DIST_DIR="$CI_DIST_PARENT/$CI_DIST_NAME"
  IMRSE_REQUIRE_EMPTY_APP_OUTPUT=1
else
  if [[ ! "$SIGNING_CERTIFICATE_SHA1" =~ ^[[:xdigit:]]{40}$ ]]; then
    printf 'Set IMRSE_SIGNING_CERTIFICATE_SHA1 to the caller-selected 40-hex certificate SHA-1; ad-hoc signing is not supported.\n' >&2
    exit 1
  fi
  SIGNING_CERTIFICATE_SHA1="$(printf '%s' "$SIGNING_CERTIFICATE_SHA1" | tr '[:upper:]' '[:lower:]')"
fi
if [[ -n "$RELEASE_COMMIT$RELEASE_TREE$RELEASE_BUILD_ROOT" ]]; then
  if [[ -z "$RELEASE_COMMIT" || -z "$RELEASE_TREE" || -z "$RELEASE_BUILD_ROOT" ]]; then
    printf 'Release mode requires IMRSE_RELEASE_SOURCE_COMMIT, IMRSE_RELEASE_SOURCE_TREE, and IMRSE_RELEASE_BUILD_ROOT.\n' >&2
    exit 1
  fi
  if [[ "$CONFIGURATION" != "release" ]]; then
    printf 'Release mode requires CONFIGURATION=release.\n' >&2
    exit 1
  fi
  if [[ -n "${SWIFTPM_CACHE_PATH:-}" && "$SWIFTPM_CACHE_PATH" != "$RELEASE_BUILD_ROOT/cache" ]]; then
    printf 'Release mode requires its isolated SwiftPM cache path.\n' >&2
    exit 1
  fi
  if [[ "$RELEASE_BUILD_ROOT" != /* ]]; then
    printf 'IMRSE_RELEASE_BUILD_ROOT must be an absolute path.\n' >&2
    exit 1
  fi
  for path in \
    "$RELEASE_BUILD_ROOT/source" \
    "$RELEASE_BUILD_ROOT/SOURCE-INPUT-MANIFEST.json" \
    "$RELEASE_BUILD_ROOT/BUILD-PROVENANCE.json" \
    "$RELEASE_BUILD_ROOT/cache" \
    "$RELEASE_BUILD_ROOT/products" \
    "$RELEASE_BUILD_ROOT/scratch" \
    "$RELEASE_BUILD_ROOT/configuration" \
    "$RELEASE_BUILD_ROOT/security" \
    "$RELEASE_BUILD_ROOT/home" \
    "$RELEASE_BUILD_ROOT/tmp"; do
    if [[ -e "$path" || -L "$path" ]]; then
      printf 'Release build output already exists: %s\n' "$path" >&2
      exit 1
    fi
  done
  python3 "$SOURCE_ROOT/scripts/package_local_candidate.py" prepare-source \
    --source-root "$SOURCE_ROOT" \
    --source-commit "$RELEASE_COMMIT" \
    --source-tree "$RELEASE_TREE" \
    --build-root "$RELEASE_BUILD_ROOT"
  RELEASE_BUILD_ROOT="$(cd "$RELEASE_BUILD_ROOT" && pwd -P)"
  ROOT="$RELEASE_BUILD_ROOT/source"
  SCRATCH_PATH="$RELEASE_BUILD_ROOT/scratch"
  CACHE_PATH="$RELEASE_BUILD_ROOT/cache"
  CONFIG_PATH="$RELEASE_BUILD_ROOT/configuration"
  SECURITY_PATH="$RELEASE_BUILD_ROOT/security"
  HOME="$RELEASE_BUILD_ROOT/home"
  TMPDIR="$RELEASE_BUILD_ROOT/tmp"
  mkdir -m 700 "$HOME" "$TMPDIR"
  export HOME TMPDIR
  DIST_DIR="$RELEASE_BUILD_ROOT/products"
  IMRSE_REQUIRE_EMPTY_APP_OUTPUT=1
else
  SCRATCH_PATH="${SCRATCH_PATH:-$ROOT/.build}"
  CACHE_PATH="${SWIFTPM_CACHE_PATH:-$ROOT/.build/cache}"
  CONFIG_PATH="${SWIFTPM_CONFIG_PATH:-$ROOT/.build/configuration}"
  SECURITY_PATH="${SWIFTPM_SECURITY_PATH:-$ROOT/.build/security}"
  DIST_DIR="${IMRSE_DIST_DIR:-$ROOT/dist}"
fi
cd "$ROOT"
BUILD_WORKING_DIRECTORY="$(pwd -P)"
if [[ "${IMRSE_REQUIRE_EMPTY_APP_OUTPUT:-0}" == "1" && ( -e "$DIST_DIR" || -L "$DIST_DIR" ) ]]; then
  printf 'The required fresh app output directory already exists: %s\n' "$DIST_DIR" >&2
  exit 1
fi
mkdir -p "$DIST_DIR"
APP="$DIST_DIR/imrse.app"
if [[ "${IMRSE_REQUIRE_EMPTY_APP_OUTPUT:-0}" == "1" && ( -e "$APP" || -L "$APP" ) ]]; then
  printf 'The required fresh app output already exists: %s\n' "$APP" >&2
  exit 1
fi
SWIFT_FLAGS=(
  --build-system swiftbuild
  --configuration "$CONFIGURATION"
  --scratch-path "$SCRATCH_PATH"
  --cache-path "$CACHE_PATH"
  --config-path "$CONFIG_PATH"
  --security-path "$SECURITY_PATH"
  --only-use-versions-from-resolved-file
)
if [[ -n "$CI_BUILD_TRIPLE" ]]; then
  SWIFT_FLAGS+=(--triple "$CI_BUILD_TRIPLE")
fi
BUILD_COMMAND=(swift build "${SWIFT_FLAGS[@]}" --product imrse)
"${BUILD_COMMAND[@]}"
BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"
STAGING="$(mktemp -d "$DIST_DIR/.imrse-package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/imrse.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN/imrse" "$STAGED_APP/Contents/MacOS/imrse"
cp "$ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
for bundle in "$BIN"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  cp -R "$bundle" "$STAGED_APP/Contents/Resources/"
done
if ! find "$STAGED_APP/Contents/Resources" -type f -path '*/Brand/imrse-menubar-template.pdf' -print -quit | grep -q .; then
  printf 'The packaged menu-bar template is missing.\n' >&2
  exit 1
fi
if [[ "$(uname -m)" == "arm64" ]] && ! find "$STAGED_APP/Contents/Resources" -type f -name 'default.metallib' -print -quit | grep -q .; then
  printf 'The packaged MLX shader resource is missing.\n' >&2
  exit 1
fi
cp "$ROOT/LICENSE" "$STAGED_APP/Contents/Resources/IMRSE-LICENSE.txt"
cp "$ROOT/Resources/THIRD_PARTY_NOTICES.md" "$STAGED_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$ROOT/pill-kit/THIRD_PARTY_NOTICES.md" "$STAGED_APP/Contents/Resources/PillKit-Source-Dependency-Notice.md"
cp "$ROOT/pill-kit/upstream/LICENSE" "$STAGED_APP/Contents/Resources/AgentElements-LICENSE"
THIRD_PARTY_LICENSES="$STAGED_APP/Contents/Resources/ThirdPartyLicenses"
mkdir -p "$THIRD_PARTY_LICENSES"
while IFS= read -r -d '' license; do
  package="$(basename "$(dirname "$license")")"
  name="$(basename "$license")"
  cp "$license" "$THIRD_PARTY_LICENSES/$package-$name"
done < <(
  find "$SCRATCH_PATH/checkouts" -mindepth 2 -maxdepth 2 -type f \
    \( -iname 'LICENSE' -o -iname 'LICENSE.*' -o -iname 'COPYING' -o -iname 'COPYING.*' \) -print0
)
if [[ -f "$SCRATCH_PATH/checkouts/mlx-swift/Source/Cmlx/mlx/LICENSE" ]]; then
  cp "$SCRATCH_PATH/checkouts/mlx-swift/Source/Cmlx/mlx/LICENSE" "$THIRD_PARTY_LICENSES/mlx-core-LICENSE"
fi
if ! find "$STAGED_APP/Contents/Resources" -type f -name 'Qwen3-APACHE-LICENSE.txt' -print -quit | grep -q .; then
  printf 'The packaged local-model license resource is missing.\n' >&2
  exit 1
fi
swift "$ROOT/Resources/GenerateIcon.swift" "$STAGING/imrse.iconset"
iconutil --convert icns "$STAGING/imrse.iconset" --output "$STAGED_APP/Contents/Resources/imrse.icns"
plutil -lint "$STAGED_APP/Contents/Info.plist"
if [[ "$CI_PACKAGE_VALIDATION" == "1" ]]; then
  python3 "$ROOT/scripts/package_local_candidate.py" validate-ci-app \
    --app "$STAGED_APP" \
    --source-root "$SOURCE_ROOT" \
    --configuration "$CONFIGURATION"
else
  python3 "$ROOT/scripts/package_local_candidate.py" sign-app \
    --app "$STAGED_APP" \
    --signing-certificate-sha1 "$SIGNING_CERTIFICATE_SHA1"
fi
if [[ "${IMRSE_REQUIRE_EMPTY_APP_OUTPUT:-0}" == "1" ]]; then
  if [[ -e "$APP" || -L "$APP" ]]; then
    printf 'The required fresh app output appeared during the build: %s\n' "$APP" >&2
    exit 1
  fi
  mv -n "$STAGED_APP" "$APP"
  if [[ -e "$STAGED_APP" || ! -f "$APP/Contents/MacOS/imrse" ]]; then
    printf 'Could not publish the fresh app without replacing an existing path: %s\n' "$APP" >&2
    exit 1
  fi
else
  if [[ -e "$APP" || -L "$APP" ]]; then mv "$APP" "$STAGING/previous-imrse.app"; fi
  if ! mv "$STAGED_APP" "$APP"; then
    if [[ -e "$STAGING/previous-imrse.app" ]]; then mv "$STAGING/previous-imrse.app" "$APP"; fi
    exit 1
  fi
fi
if [[ "$CI_PACKAGE_VALIDATION" == "1" ]]; then
  printf '\nCI package validation only: unsigned non-distribution app at %s\n' "$APP"
else
  printf '\nBuilt %s\nThis local bundle is not notarized.\n' "$APP"
fi
if [[ -n "$RELEASE_COMMIT" ]]; then
  BUILD_COMMAND_ARGS=()
  for argument in "${BUILD_COMMAND[@]}"; do
    BUILD_COMMAND_ARGS+=("--build-command-arg=$argument")
  done
  python3 "$SOURCE_ROOT/scripts/package_local_candidate.py" record-build \
    --source-root "$SOURCE_ROOT" \
    --source-commit "$RELEASE_COMMIT" \
    --source-tree "$RELEASE_TREE" \
    --build-root "$RELEASE_BUILD_ROOT" \
    --working-directory "$BUILD_WORKING_DIRECTORY" \
    --signing-certificate-sha1 "$SIGNING_CERTIFICATE_SHA1" \
    "${BUILD_COMMAND_ARGS[@]}"
fi
