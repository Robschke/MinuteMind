#!/bin/zsh
# Purpose: regenerates THIRD_PARTY_NOTICES.md from the license and notice files of every package
#          pinned in Package.resolved.
# Depends on: Package.resolved, .build/checkouts (filled by `swift package resolve`).
# Dependents: Scripts/package_app.sh copies THIRD_PARTY_NOTICES.md into the app bundle.
# Notes: The MIT, Apache 2.0 and BSD licenses of the dependencies require their notices to ship
#        with the binary. Run this after adding or updating a package and commit the result.
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname "$0")/.." && pwd)"
OUT="$PROJECT_ROOT/THIRD_PARTY_NOTICES.md"
cd "$PROJECT_ROOT"
swift package resolve >/dev/null

{
  echo "# Third-Party Notices"
  echo
  echo "MinuteMind includes the following open-source packages. Their licenses and notices follow."
  for dir in .build/checkouts/*(/); do
    name="${dir:t}"
    url="$(git -C "$dir" remote get-url origin 2>/dev/null || echo "")"
    echo
    echo "## $name"
    [[ -n "$url" ]] && { echo; echo "$url"; }
    for file in "$dir"/(LICENSE|LICENSE.*|COPYING|NOTICE|NOTICE.*)(N.); do
      echo
      echo '```'
      cat "$file"
      echo '```'
    done
  done
} > "$OUT"

echo "Wrote $OUT"
