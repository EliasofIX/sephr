#!/usr/bin/env bash
# Builds Sephr.app. Uses swift build when no Xcode project is present;
# otherwise delegates to xcodebuild.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f sephr/Sephr.xcodeproj/project.pbxproj ]; then
    xcodebuild \
        -project sephr/Sephr.xcodeproj \
        -scheme Sephr \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -derivedDataPath build/DerivedData \
        archive -archivePath build/Sephr.xcarchive
    xcodebuild -exportArchive \
        -archivePath build/Sephr.xcarchive \
        -exportPath build/Sephr-app \
        -exportOptionsPlist sephr/Resources/ExportOptions.plist
    echo "[sephr] Sephr.app → $(pwd)/build/Sephr-app/Sephr.app"
else
    swift build -c release
    echo "[sephr] binary → $(pwd)/.build/release/Sephr"
fi
