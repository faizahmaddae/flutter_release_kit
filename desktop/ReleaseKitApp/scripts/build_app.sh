#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${PACKAGE_DIR}/dist/Flutter Release Kit.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
INFO_PLIST="${CONTENTS_DIR}/Info.plist"
SOURCE_ICON="${PACKAGE_DIR}/Resources/AppIcon/app-icon-1024.png"

swift build --configuration release --package-path "${PACKAGE_DIR}"

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
install -m 755 "${PACKAGE_DIR}/.build/release/ReleaseKitApp" "${MACOS_DIR}/ReleaseKitApp"

# Build every standard and Retina representation from one reviewed 1024px
# source. Keeping this here makes the .app reproducible without Xcode assets.
ICON_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/frk-app-icon.XXXXXX")"
trap 'rm -rf "${ICON_TEMP_DIR}"' EXIT
ICONSET_DIR="${ICON_TEMP_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"
sips -z 16 16 "${SOURCE_ICON}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
sips -z 32 32 "${SOURCE_ICON}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "${SOURCE_ICON}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
sips -z 64 64 "${SOURCE_ICON}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "${SOURCE_ICON}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
sips -z 256 256 "${SOURCE_ICON}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "${SOURCE_ICON}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
sips -z 512 512 "${SOURCE_ICON}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "${SOURCE_ICON}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
cp "${SOURCE_ICON}" "${ICONSET_DIR}/icon_512x512@2x.png"
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"

plutil -create xml1 "${INFO_PLIST}"
plutil -insert CFBundleExecutable -string "ReleaseKitApp" "${INFO_PLIST}"
plutil -insert CFBundleIdentifier -string "com.faizdae.flutter-release-kit" "${INFO_PLIST}"
plutil -insert CFBundleName -string "Flutter Release Kit" "${INFO_PLIST}"
plutil -insert CFBundleDisplayName -string "Flutter Release Kit" "${INFO_PLIST}"
plutil -insert CFBundleIconFile -string "AppIcon.icns" "${INFO_PLIST}"
plutil -insert CFBundlePackageType -string "APPL" "${INFO_PLIST}"
plutil -insert CFBundleShortVersionString -string "0.1.0" "${INFO_PLIST}"
plutil -insert CFBundleVersion -string "1" "${INFO_PLIST}"
plutil -insert LSMinimumSystemVersion -string "14.0" "${INFO_PLIST}"
plutil -insert LSApplicationCategoryType -string "public.app-category.developer-tools" "${INFO_PLIST}"
plutil -insert NSHighResolutionCapable -bool true "${INFO_PLIST}"

# Ad-hoc signing makes the local bundle internally consistent without requiring
# a Developer ID. Distribution outside this Mac should use a real Developer ID.
codesign --force --deep --sign - "${APP_DIR}"

# Finder and Launch Services cache bundle metadata aggressively, especially
# when a development build is replaced in-place without changing its version.
# Re-register the finished app so a newly added or updated icon appears at once.
touch "${APP_DIR}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "${LSREGISTER}" ]]; then
  "${LSREGISTER}" -f "${APP_DIR}"
fi

echo "Built: ${APP_DIR}"
