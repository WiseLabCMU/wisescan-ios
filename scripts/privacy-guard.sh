#!/bin/bash
# Shared privacy-guard checks, sourced by the pre-commit and pre-push hooks.
# (Copied next to the hooks in .git/hooks/ by scripts/install-hooks.sh.)
#
# Blocks two classes of accidental privacy leak from entering the repo — and thus
# from ever reaching a production build:
#
#   1. Debug-only Info.plist keys (UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace)
#      that expose the app's Documents — including raw, UNBLURRED 360° stills — to the
#      Files app and Finder. Enabling them LOCALLY for development is fine; committing
#      them is not. See CONTRIBUTING.md -> Privacy Filtering Patterns.
#
#   2. Raw capture artifacts (scan bundles, 360° equirects, downloaded .xcappdata
#      containers). A 360° still sees everyone in the room, and per-face blur for
#      equirects is not implemented yet (docs/design/still-source-360.md, P3), so any
#      raw still that escapes the device is a privacy leak.

# Info.plist keys that must never be committed (debug-only file sharing).
PG_FORBIDDEN_PLIST_KEYS="UIFileSharingEnabled LSSupportsOpeningDocumentsInPlace"

# Path patterns for raw capture artifacts that must never be committed.
PG_FORBIDDEN_PATH_REGEX='(^|/)(raw_data|equirect_stills)/|(^|/)R[0-9]{7}\.JPG$|(^|/)still_[0-9]{4}\.JPG$|\.xcappdata(/|$)'

# pg_plist_violations <plist-content>
# Echoes a space-separated list of any forbidden keys found. Empty output => clean.
pg_plist_violations() {
    local content="$1" key hits=""
    for key in $PG_FORBIDDEN_PLIST_KEYS; do
        if printf '%s\n' "$content" | grep -q "<key>$key</key>"; then
            hits="$hits $key"
        fi
    done
    printf '%s' "$hits"
}

# pg_is_forbidden_path <path>  -> exit 0 if the path is a raw capture artifact.
pg_is_forbidden_path() {
    printf '%s\n' "$1" | grep -qE "$PG_FORBIDDEN_PATH_REGEX"
}
