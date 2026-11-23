#!/usr/bin/env bash
set -euo pipefail

# Builds an installable unsigned External-mode IPA (compatible with Shadowrocket) from upstream Poki
# with PokiSitesBridge + PokiAppIntegration compiled into Poki.app.
#
# Never touches any physical iPhone device.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM_REPO="${POKI_UPSTREAM_REPO:-https://github.com/JosssphZhou/poki.git}"
UPSTREAM_COMMIT="${POKI_UPSTREAM_COMMIT:-9184aca5b9368a81f37f4e611827072a94105fcb}"
BUILD_WORKDIR="${POKI_BUILD_WORKDIR:-/tmp/poki-ios-build}"
RUST_WORKDIR="${POKI_RUST_WORKDIR:-/tmp/poki-rust}"
OUT_DIR="$ROOT_DIR/dist/ios"
IPA_NAME="${POKI_IPA_NAME:-Poki-external-sites-bridge.ipa}"
VERSION="${POKI_VERSION:-0.5.0}"
BUILD_NUMBER="${POKI_BUILD_NUMBER:-9977}"
REUSE_BUILD="${POKI_REUSE_BUILD:-0}"

mkdir -p "$OUT_DIR"

if [ "$REUSE_BUILD" = "1" ] && [ -f "$BUILD_WORKDIR/native/launcher/target/aarch64-apple-ios/release/libpoki_launcher.a" ]; then
  echo "==> Reusing existing Rust launcher & DerivedData at $BUILD_WORKDIR"
  git -C "$BUILD_WORKDIR" checkout -- .
else
  echo "==> Preparing isolated upstream Poki checkout ($UPSTREAM_COMMIT) at $BUILD_WORKDIR"
  rm -rf "$BUILD_WORKDIR"
  mkdir -p "$BUILD_WORKDIR"
  git init -q "$BUILD_WORKDIR"
  git -C "$BUILD_WORKDIR" fetch --depth 1 "$UPSTREAM_REPO" "$UPSTREAM_COMMIT"
  git -C "$BUILD_WORKDIR" checkout -q --detach FETCH_HEAD

  echo "==> Ensuring Rust toolchain + aarch64-apple-ios target for PokiLauncher"
  if ! command -v cargo >/dev/null 2>&1 || ! command -v rustup >/dev/null 2>&1; then
    export RUSTUP_HOME="$RUST_WORKDIR/rustup"
    export CARGO_HOME="$RUST_WORKDIR/cargo"
    mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"
    if [ ! -x "$CARGO_HOME/bin/cargo" ]; then
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain stable
    fi
    export PATH="$CARGO_HOME/bin:$PATH"
  fi

  rustup target add aarch64-apple-ios

  echo "==> Fetching pinned idevice checkout and building libpoki_launcher.a (aarch64-apple-ios)"
  "$BUILD_WORKDIR/native/launcher/fetch-idevice.sh"
  cargo build --release --locked --target aarch64-apple-ios --manifest-path "$BUILD_WORKDIR/native/launcher/Cargo.toml"
  test -f "$BUILD_WORKDIR/native/launcher/target/aarch64-apple-ios/release/libpoki_launcher.a"
fi

echo "==> Applying PokiSitesBridge integration patch"
python3 -B "$ROOT_DIR/scripts/patch-poki-upstream.py" "$ROOT_DIR" "$BUILD_WORKDIR"

echo "==> Generating Poki assets and XcodeExternal project"
"$BUILD_WORKDIR/native/ios-app/scripts/make-assets.sh"
xcodegen generate --spec "$BUILD_WORKDIR/native/ios-app/project-external.yml"

echo "==> Building Release arm64 iOS binary (unsigned)"
set +e
xcodebuild build \
  -project "$BUILD_WORKDIR/native/ios-app/PokiExternal.xcodeproj" \
  -scheme Poki \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_WORKDIR/derived-external" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  ARCHS=arm64 \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  >"$BUILD_WORKDIR/xcodebuild-external.log" 2>&1
XCODE_STATUS=$?
set -e

grep -E "error:|BUILD (SUCCEEDED|FAILED)|\*\* " "$BUILD_WORKDIR/xcodebuild-external.log" | tail -n 60 || true
if [ "$XCODE_STATUS" -ne 0 ]; then
  echo "ERROR: xcodebuild failed (exit $XCODE_STATUS); inspect $BUILD_WORKDIR/xcodebuild-external.log" >&2
  exit "$XCODE_STATUS"
fi

APP_PATH="$BUILD_WORKDIR/derived-external/Build/Products/Release-iphoneos/Poki.app"
test -d "$APP_PATH"

echo "==> Packaging IPA with upstream package-app.sh"
IPA_PATH="$OUT_DIR/$IPA_NAME"
"$BUILD_WORKDIR/native/ios-app/scripts/package-app.sh" \
  "$APP_PATH" external "$IPA_PATH" "$VERSION" "$BUILD_NUMBER"

(cd "$OUT_DIR" && shasum -a 256 "$IPA_NAME" > "$IPA_NAME.sha256")
ls -lh "$IPA_PATH" "$IPA_PATH.sha256"
echo "IPA built successfully at: $IPA_PATH"
