#!/usr/bin/env bash
# Archive the iOS app in Release and upload it to App Store Connect.
# Signs and uploads with the Apple account signed in to Xcode (Account Holder or Admin of
# PTC's team 72995T7U66): an App Manager API key may not use cloud-managed distribution
# certificates. The API key (~/.config/healthaccessmcp/asc.env) is for the API scripts.
set -euo pipefail
cd "$(dirname "$0")/../app"
AUTH=(-allowProvisioningUpdates)
xcodegen generate
ARCHIVE="build/HealthAccess-$(date +%Y%m%d-%H%M).xcarchive"
xcodebuild -project HealthAccess.xcodeproj -scheme HealthAccess -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" "${AUTH[@]}" archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist ../appstore/ExportOptions.plist \
  -exportPath build/export "${AUTH[@]}"
echo "Uploaded. Processing takes 5 to 30 minutes; then the build shows in TestFlight."
