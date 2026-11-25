#!/bin/bash
# Purpose: one-line installer and updater for MinuteMind. Downloads the latest release, replaces
#          an existing MinuteMind.app where it is (/Applications, then ~/Applications) or installs
#          into /Applications (~/Applications when that is not writable), reopens it, installs
#          Claude Code when the `claude` command is missing and offers Apple's Command Line Tools
#          when git is missing.
# Depends on: the GitHub Release asset MinuteMind.zip of Robschke/MinuteMind (built by
#             Scripts/package_release.sh), Claude Code's official installer at claude.ai/install.sh.
# Dependents: README.md (Install section) links this file via raw.githubusercontent.com;
#             Sources/App/Services/AppUpdateService.swift runs it for in-app updates.
# Notes: Everything runs inside main(), called on the last line, so a download cut off halfway
#        through `curl | bash` never executes a partial script. The release is Apple Silicon only,
#        because the app is built with `swift build` on an arm64 Mac.
#        MINUTEMIND_INSTALL_DIR sets the target folder (the in-app update passes the running
#        app's folder); MINUTEMIND_NO_OPEN=1 skips opening the app (used for testing the script).
#        A MinuteMind that is a parent of this script (the in-app update) gets SIGTERM, any other
#        a polite AppleScript quit; see the quitting step for why.

set -euo pipefail

main() {
  local repo="Robschke/MinuteMind"
  local app_name="MinuteMind.app"
  local download_url="https://github.com/${repo}/releases/latest/download/MinuteMind.zip"

  say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
  fail() { printf '\033[31mError:\033[0m %s\n' "$1" >&2; exit 1; }
  # Whether process $1 is this script or one of its parents.
  is_ancestor() {
    local current=$$
    while [[ -n "$current" && "$current" -gt 1 ]]; do
      [[ "$current" == "$1" ]] && return 0
      current="$(ps -o ppid= -p "$current" 2>/dev/null | tr -d ' ' || true)"
    done
    return 1
  }

  [[ "$(uname -s)" == "Darwin" ]] || fail "MinuteMind runs on macOS only."
  [[ "$(uname -m)" == "arm64" ]] || fail "MinuteMind needs a Mac with Apple Silicon (M1 or newer)."
  local macos_major
  macos_major="$(sw_vers -productVersion | cut -d. -f1)"
  (( macos_major >= 14 )) || fail "MinuteMind needs macOS 14 (Sonoma) or newer."

  local install_dir="${MINUTEMIND_INSTALL_DIR:-}"
  if [[ -z "$install_dir" ]]; then
    if [[ -d "/Applications/$app_name" ]]; then
      install_dir="/Applications"
    elif [[ -d "$HOME/Applications/$app_name" ]]; then
      install_dir="$HOME/Applications"
    elif [[ -w "/Applications" ]]; then
      install_dir="/Applications"
    else
      install_dir="$HOME/Applications"
    fi
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

  # -a: macOS pgrep leaves out its own ancestors otherwise, and the in-app update runs this
  # script as a child of MinuteMind, so the running app was never found and never quit.
  local app_pids
  app_pids="$(pgrep -ax MinuteMind 2>/dev/null || true)"
  if [[ -n "$app_pids" ]]; then
    say "Quitting the running MinuteMind"
    local pid parent_app=""
    for pid in $app_pids; do
      if is_ancestor "$pid"; then parent_app="$pid"; fi
    done
    if [[ -n "$parent_app" && -t 1 ]]; then
      # A terminal inside MinuteMind: quitting the app closes that terminal and would cut the
      # install off halfway.
      fail "This runs in a terminal inside MinuteMind. Update from MinuteMind's update dialog, or run the command in Terminal."
    elif [[ -n "$parent_app" ]]; then
      # The in-app update: MinuteMind started this and waits idle in its update dialog. SIGTERM,
      # because macOS may refuse an Apple event from a child to its own app. MinuteMind treats
      # SIGTERM like Quit (saves and closes); releases up to 0.3.3 simply end.
      kill -TERM "$parent_app" 2>/dev/null || true
    else
      osascript -e 'quit app "MinuteMind"' >/dev/null 2>&1 || true
    fi
    for _ in {1..120}; do pgrep -ax MinuteMind >/dev/null 2>&1 || break; sleep 0.5; done
    if pgrep -ax MinuteMind >/dev/null 2>&1; then
      fail "MinuteMind did not quit. If macOS asked whether Terminal may control MinuteMind, allow it. Otherwise quit MinuteMind (Cmd+Q) and run this command again."
    fi
  fi

  say "Installing into $install_dir"
  rm -rf "${install_dir:?}/$app_name"
  ditto "$tmp/unpacked/$app_name" "$install_dir/$app_name"
  # The system xattr explicitly: a Python xattr earlier on PATH has no -r.
  /usr/bin/xattr -dr com.apple.quarantine "$install_dir/$app_name" >/dev/null 2>&1 || true

  # Where Claude Code's installers put it, for runs with a minimal PATH (the in-app update).
  PATH="$PATH:$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin"
  if command -v claude >/dev/null 2>&1; then
    say "Claude Code is already installed"
  else
    say "Installing Claude Code (MinuteMind uses it for summaries, tasks and knowledge)"
    curl -fsSL https://claude.ai/install.sh | bash \
      || printf 'Claude Code could not be installed. Install it later: https://claude.com/claude-code\n'
  fi

  # Project workspaces are git repositories. Without Apple's Command Line Tools /usr/bin/git is
  # only a stub, so they are offered here. Apple's installer opens only for a run in a terminal;
  # the in-app update (output to a log file) leaves it to MinuteMind's own hint.
  local developer_dir
  developer_dir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [[ -n "$developer_dir" && -x "$developer_dir/usr/bin/git" ]]; then
    say "git is already installed"
  elif [[ -t 1 ]]; then
    say "Opening Apple's installer for the Command Line Tools (git, used for project workspaces)"
    /usr/bin/xcode-select --install >/dev/null 2>&1 || true
  else
    printf 'git is missing. Install it with: xcode-select --install\n'
  fi

  say "Done. MinuteMind is in $install_dir"
  if [[ "${MINUTEMIND_NO_OPEN:-}" != "1" ]]; then
    open "$install_dir/$app_name"
  fi
}

main "$@"
