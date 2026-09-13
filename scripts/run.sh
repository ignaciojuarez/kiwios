#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd)
developer_dir=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
derived_data=${KIWIOS_DERIVED_DATA:-"$project_root/.build/xcode"}
build_settings=(CODE_SIGNING_ALLOWED=NO)

if [ -n "${KIWIOS_DEVELOPMENT_TEAM:-}" ]; then
  build_settings=(DEVELOPMENT_TEAM="$KIWIOS_DEVELOPMENT_TEAM" CODE_SIGNING_ALLOWED=YES)
fi

if [ ! -x "$developer_dir/usr/bin/xcodebuild" ]; then
  echo "Xcode 27 was not found at $developer_dir. Set DEVELOPER_DIR to its Developer directory." >&2
  exit 1
fi

DEVELOPER_DIR="$developer_dir" "$developer_dir/usr/bin/xcodebuild" \
  -project "$project_root/KiwiOS.xcodeproj" \
  -scheme KiwiOS \
  -configuration Debug \
  -derivedDataPath "$derived_data" \
  "${build_settings[@]}" \
  build

open "$derived_data/Build/Products/Debug/KiwiOS.app"
