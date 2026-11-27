# shellcheck shell=bash
# lib/min-macos.sh — the release's minimum macOS, as one HTML comment GitHub hides.
# ---------------------------------------------------------------------------
# Sourced by scripts/release.sh and scripts/cut-beta.sh: each appends the line
# to its notes file, so what the app offers can be gated on what the running
# macOS can actually install (issue #8: a release needing a newer macOS must
# never be offered to a Mac that cannot launch it). The app's own
# UpdateChecker parses the line back out; nothing else reads it.
#
#   sparehold_min_macos_line            # "minimum-macos: 26" or "" (unknown)

# The one source of truth is the app's Package.swift platform pin
# (`platforms: [.macOS(.v26)]`). Returns "" when it cannot be read, so a
# release published from an odd checkout simply carries no gate.
sparehold_min_macos() {
  local pkg="app/Package.swift"
  [[ -f "$pkg" ]] || { pkg="Package.swift"; }
  [[ -f "$pkg" ]] || return 0
  grep -o '\.macOS(\.v[0-9]\{1,2\})' "$pkg" \
    | head -1 \
    | sed 's/.*\.v\([0-9]\{1,2\}\)).*/\1/'
}

sparehold_min_macos_line() {
  local minimum
  minimum="$(sparehold_min_macos)"
  [[ -n "$minimum" ]] && printf '<!-- minimum-macos: %s -->' "$minimum"
}
