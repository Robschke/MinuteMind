#!/bin/zsh
# Purpose: builds dist/MinuteMind.zip, the release asset that install.sh downloads.
# Depends on: Scripts/package_app.sh (tests, release build, signing), Sources/App/Supporting/Info.plist (version),
#             release-notes/<version>.md (the release body).
# Dependents: install.sh expects the asset name MinuteMind.zip on the latest GitHub Release;
#             Sources/App/Views/AppUpdateSheet.swift shows the release body as "What's new".
# Notes: Sign releases with the same "MinuteMind-Self-Signed" certificate every time. macOS ties
#        granted permissions (microphone, screen recording, calendars) to the signing identity, so a
#        stable certificate keeps them across updates on users' Macs; ad-hoc signing resets them.
#        Pass --publish to create the GitHub Release for the version in Info.plist with gh. The notes
#        file is required for --publish: GitHub's generated notes are only a changelog link for a
#        repository without pull requests, and the update dialog shows this text to users.
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$PROJECT_ROOT/dist/MinuteMind.app"
ZIP_PATH="$PROJECT_ROOT/dist/MinuteMind.zip"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_ROOT/Sources/App/Supporting/Info.plist")"
NOTES_PATH="$PROJECT_ROOT/release-notes/$VERSION.md"

if [[ "${1:-}" == "--publish" && ! -s "$NOTES_PATH" ]]; then
  echo "Error: write the release notes for $VERSION to release-notes/$VERSION.md first (a few user-facing bullets)." >&2
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -q "MinuteMind-Self-Signed"; then
  echo "Error: the 'MinuteMind-Self-Signed' certificate is missing. Releases must not be ad-hoc signed." >&2
  exit 1
fi

"$PROJECT_ROOT/Scripts/package_app.sh"

rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
echo "Created $ZIP_PATH (version $VERSION)"

if [[ "${1:-}" == "--publish" ]]; then
  gh release create "v$VERSION" "$ZIP_PATH" --title "MinuteMind $VERSION" --notes-file "$NOTES_PATH"
fi
