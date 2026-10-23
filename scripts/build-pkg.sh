#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="${1:-$PROJECT_DIR/dist/HS Shot.app}"
APP_DIR="${APP_DIR:A}"
INFO_PLIST="$APP_DIR/Contents/Info.plist"

if [[ ! -f "$INFO_PLIST" ]]; then
    print -u2 "App not found: $APP_DIR"
    print -u2 "Build it first with ./scripts/build-app.sh"
    exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
if [[ "$APP_IDENTIFIER" != "jp.huntersite.hsshot" ]]; then
    print -u2 "Unexpected app identifier: $APP_IDENTIFIER"
    exit 1
fi

PACKAGE_PATH="${2:-$PROJECT_DIR/dist/HS-Shot-$APP_VERSION.pkg}"
PACKAGE_PATH="${PACKAGE_PATH:A}"
mkdir -p "${PACKAGE_PATH:h}" "$PROJECT_DIR/.build"
WORK_DIR="$(mktemp -d "$PROJECT_DIR/.build/hs-shot-pkg.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# Copy the exact tested app; packaging never rebuilds or changes its signature.
codesign --verify --deep --strict "$APP_DIR"
mkdir -p "$WORK_DIR/root/Applications"
# Host-specific access and quarantine metadata must not enter a public installer.
ditto --norsrc --noextattr --noqtn --noacl "$APP_DIR" "$WORK_DIR/root/Applications/HS Shot.app"
pkgbuild --analyze --root "$WORK_DIR/root" "$WORK_DIR/components.plist"
# Always install to /Applications, even if another copy is in a build folder.
plutil -replace 0.BundleIsRelocatable -bool false "$WORK_DIR/components.plist"
plutil -replace 0.BundleHasStrictIdentifier -bool true "$WORK_DIR/components.plist"
pkgbuild \
    --root "$WORK_DIR/root" \
    --component-plist "$WORK_DIR/components.plist" \
    --identifier "$APP_IDENTIFIER.pkg" \
    --version "$APP_VERSION" \
    --install-location / \
    --ownership recommended \
    "$WORK_DIR/HS-Shot.pkg"

# Verify the archive and payload without installing it or requiring admin access.
pkgutil --expand-full "$WORK_DIR/HS-Shot.pkg" "$WORK_DIR/expanded"
PACKAGED_APP="$WORK_DIR/expanded/Payload/Applications/HS Shot.app"
codesign --verify --deep --strict "$PACKAGED_APP"
cmp "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE" "$PACKAGED_APP/Contents/MacOS/$APP_EXECUTABLE"
diff -qr "$APP_DIR" "$PACKAGED_APP"
if [[ -e "$WORK_DIR/expanded/Scripts" ]]; then
    print -u2 "Unexpected installer scripts in package"
    exit 1
fi
mv "$WORK_DIR/HS-Shot.pkg" "$PACKAGE_PATH"
(
    cd "${PACKAGE_PATH:h}"
    shasum -a 256 "${PACKAGE_PATH:t}" > "${PACKAGE_PATH:t}.sha256"
)
print "Built unsigned installer: $PACKAGE_PATH"
print "Installs: /Applications/HS Shot.app"
print "SHA-256: $PACKAGE_PATH.sha256"
