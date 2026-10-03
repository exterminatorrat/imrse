#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'The native app requires macOS. Run swift test for the portable modules.\n' >&2
  exit 1
fi
CONFIGURATION="${CONFIGURATION:-release}"
SCRATCH_PATH="${SCRATCH_PATH:-$ROOT/.build}"
swift build --build-system swiftbuild --configuration "$CONFIGURATION" --scratch-path "$SCRATCH_PATH" --product imrse
BIN="$(swift build --build-system swiftbuild --configuration "$CONFIGURATION" --scratch-path "$SCRATCH_PATH" --show-bin-path)"
APP="$ROOT/dist/imrse.app"
mkdir -p "$ROOT/dist"
STAGING="$(mktemp -d "$ROOT/dist/.imrse-package.XXXXXX")"
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
cp "$ROOT/pill-kit/THIRD_PARTY_NOTICES.md" "$STAGED_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
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
swift "$ROOT/Resources/GenerateIcon.swift" "$ROOT/dist/imrse.iconset"
iconutil --convert icns "$ROOT/dist/imrse.iconset" --output "$STAGED_APP/Contents/Resources/imrse.icns"
plutil -lint "$STAGED_APP/Contents/Info.plist"
codesign --force --sign "${SIGNING_IDENTITY:--}" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
if [[ -e "$APP" ]]; then mv "$APP" "$STAGING/previous-imrse.app"; fi
if ! mv "$STAGED_APP" "$APP"; then
  if [[ -e "$STAGING/previous-imrse.app" ]]; then mv "$STAGING/previous-imrse.app" "$APP"; fi
  exit 1
fi
printf '\nBuilt %s\nThis local bundle is not notarized.\n' "$APP"
