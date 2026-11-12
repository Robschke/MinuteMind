#!/bin/bash
# Purpose: one-line installer for MinuteMind. Downloads the latest release, installs it into
#          /Applications (or ~/Applications when that is not writable) and installs Claude Code
#          when the `claude` command is missing.
# Depends on: the GitHub Release asset MinuteMind.zip of Robschke/MinuteMind (built by
#             Scripts/package_release.sh), Claude Code's official installer at claude.ai/install.sh.
# Dependents: README.md (Install section) links this file via raw.githubusercontent.com.
# Notes: Everything runs inside main(), called on the last line, so a download cut off halfway
#        through `curl | bash` never executes a partial script. The release is Apple Silicon only,
#        because the app is built with `swift build` on an arm64 Mac.
#        MINUTEMIND_INSTALL_DIR overrides the target folder (used for testing the script).

set -euo pipefail

main() {
  local repo="Robschke/MinuteMind"
  local app_name="MinuteMind.app"
  local download_url="https://github.com/${repo}/releases/latest/download/MinuteMind.zip"

  say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
  fail() { printf '\033[31mError:\033[0m %s\n' "$1" >&2; exit 1; }

  [[ "$(uname -s)" == "Darwin" ]] || fail "MinuteMind runs on macOS only."
  [[ "$(uname -m)" == "arm64" ]] || fail "MinuteMind needs a Mac with Apple Silicon (M1 or newer)."
  local macos_major
  macos_major="$(sw_vers -productVersion | cut -d. -f1)"
  (( macos_major >= 14 )) || fail "MinuteMind needs macOS 14 (Sonoma) or newer."

  local install_dir="${MINUTEMIND_INSTALL_DIR:-/Applications}"
  if [[ -z "${MINUTEMIND_INSTALL_DIR:-}" && ! -w "$install_dir" ]]; then
    install_dir="$HOME/Applications"
  fi
  mkdir -p "$install_dir"

  local tmp
  tmp="$(mktemp -d)"
  # Expanded now: tmp is local to main and already gone when the EXIT trap fires.
  trap "rm -rf '$tmp'" EXIT

  say "Downloading MinuteMind"
  curl -fL --progress-bar "$download_url" -o "$tmp/MinuteMind.zip" \
    || fail "Download failed: $download_url"
  ditto -x -k "$tmp/MinuteMind.zip" "$tmp/unpacked"
  [[ -d "$tmp/unpacked/$app_name" ]] || fail "The download does not contain $app_name."

  if pgrep -x MinuteMind >/dev/null 2>&1; then
    say "Quitting the running MinuteMind"
    osascript -e 'quit app "MinuteMind"' >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -x MinuteMind >/dev/null 2>&1 || break; sleep 0.5; done
  fi

  say "Installing into $install_dir"
  rm -rf "${install_dir:?}/$app_name"
  ditto "$tmp/unpacked/$app_name" "$install_dir/$app_name"
  # The system xattr explicitly: a Python xattr earlier on PATH has no -r.
  /usr/bin/xattr -dr com.apple.quarantine "$install_dir/$app_name" >/dev/null 2>&1 || true

  if command -v claude >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/claude" ]]; then
    say "Claude Code is already installed"
  else
    say "Installing Claude Code (MinuteMind uses it for summaries, tasks and knowledge)"
    curl -fsSL https://claude.ai/install.sh | bash \
      || printf 'Claude Code could not be installed. Install it later: https://claude.com/claude-code\n'
  fi

  say "Done. MinuteMind is in $install_dir"
  if [[ -z "${MINUTEMIND_INSTALL_DIR:-}" ]]; then
    open "$install_dir/$app_name"
  fi
}

main "$@"
