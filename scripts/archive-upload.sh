#!/usr/bin/env bash
# Archive the iOS app in Release and upload it to App Store Connect.
# Needs PTC's team in app/project.yml and an App Store Connect API key:
#   ASC_KEY_ID, ASC_ISSUER_ID, and the .p8 at ~/.config/healthaccessmcp/AuthKey_<ASC_KEY_ID>.p8
set -euo pipefail
cd "$(dirname "$0")/../app"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"; : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY="$HOME/.config/healthaccessmcp/AuthKey_${ASC_KEY_ID}.p8"
[ -f "$KEY" ] || { echo "missing $KEY"; exit 1; }
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
xcodegen generate
ARCHIVE="build/HealthAccess-$(date +%Y%m%d-%H%M).xcarchive"
xcodebuild -project HealthAccess.xcodeproj -scheme HealthAccess -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" "${AUTH[@]}" archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist ../appstore/ExportOptions.plist \
  -exportPath build/export "${AUTH[@]}"
echo "Uploaded. Processing takes 5 to 30 minutes; then the build shows in TestFlight."
