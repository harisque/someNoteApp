#!/usr/bin/env bash
#
# distribute-testflight.sh
#
# One-command pipeline: archive the Release build and export/upload it to
# App Store Connect (TestFlight) for the DocumentAssistantApp / "BoardIQ" app.
#
# ---------------------------------------------------------------------------
# PREFLIGHT — this script only succeeds once ALL of the following are true:
#   1. The paid Apple Developer Program enrollment is APPROVED (currently in review).
#   2. An Apple Distribution certificate is installed in the keychain
#      (Xcode > Settings > Accounts, or handled automatically by automatic signing).
#   3. The App Store Connect app record exists for bundle ID
#      com.sc.boardiq (display name: BoardIQ), Team ID 7H8UDM99LP.
#   4. CURRENT_PROJECT_VERSION (build number) has been incremented in
#      project.pbxproj for every re-upload (App Store Connect rejects duplicate
#      build numbers for the same MARKETING_VERSION).
#
# Bundle stays ~1.7 GB (miniCPM5 + Qwen3-Embedding). Do NOT re-add
# Models/Qwen3.5-4B (2.9 GB) — that would exceed the 4 GB uncompressed limit.
# ---------------------------------------------------------------------------

set -euo pipefail

# Resolve repo root (script lives at <root>/DocumentAssistantApp/scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

PROJECT="DocumentAssistantApp/DocumentAssistantApp.xcodeproj"
SCHEME="DocumentAssistantApp"
CONFIGURATION="Release"
DERIVED_DATA=".build/da-derived"
ARCHIVE_PATH="${DERIVED_DATA}/Archives/DocumentAssistantApp.xcarchive"
EXPORT_PATH="${DERIVED_DATA}/Export"
EXPORT_OPTIONS="DocumentAssistantApp/ExportOptions.plist"

echo "==> Repo root:        ${REPO_ROOT}"
echo "==> Project:          ${PROJECT}"
echo "==> Scheme:           ${SCHEME} (${CONFIGURATION})"
echo "==> Archive path:     ${ARCHIVE_PATH}"
echo "==> Export options:   ${EXPORT_OPTIONS}"
echo "==> Export path:      ${EXPORT_PATH}"
echo

echo "==> [1/2] Archiving..."
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "${DERIVED_DATA}" \
  -archivePath "${ARCHIVE_PATH}" \
  -allowProvisioningUpdates \
  archive

echo
echo "==> [2/2] Exporting and uploading to App Store Connect..."
xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  -exportPath "${EXPORT_PATH}" \
  -allowProvisioningUpdates

echo
echo "==> Done. The build will appear under TestFlight after App Store Connect finishes processing."
