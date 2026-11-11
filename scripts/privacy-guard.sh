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
#      containers), and *.secrets.xcconfig files.
#   3. Credential values in tracked plists and literal SDK secrets in Swift (below). A 360° still sees everyone in the room, and per-face blur for
#      equirects is not implemented yet (docs/design/still-source-360.md, P3), so any
#      raw still that escapes the device is a privacy leak.

# Info.plist keys that must never be committed (debug-only file sharing).
PG_FORBIDDEN_PLIST_KEYS="UIFileSharingEnabled LSSupportsOpeningDocumentsInPlace"

# Path patterns for raw capture artifacts that must never be committed.
PG_FORBIDDEN_PATH_REGEX='(^|/)(raw_data|equirect_stills)/|(^|/)R[0-9]{7}\.JPG$|(^|/)still_[0-9]{4}\.JPG$|\.xcappdata(/|$)|\.secrets\.xcconfig$'

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

# pg_pbxproj_violations <pbxproj-content>
# Echoes forbidden keys reachable via Xcode build settings. INFOPLIST_KEY_ passthroughs
# (e.g. `INFOPLIST_KEY_UIFileSharingEnabled = YES`) generate the same Info.plist keys at
# build time — the identical leak in a different spelling, which the *.plist check never
# sees. Matching the bare key name also catches INFOPLIST_FILE-style indirection labels.
pg_pbxproj_violations() {
    local content="$1" key hits=""
    for key in $PG_FORBIDDEN_PLIST_KEYS; do
        if printf '%s\n' "$content" | grep -q "$key"; then
            hits="$hits $key"
        fi
    done
    printf '%s' "$hits"
}

# Credentials that must never be committed (CONTRIBUTING.md -> Credentials).
#   3. Info.plist keys the Meta Wearables toolkit reads: a tracked plist may carry the
#      key with an EMPTY value or a $(BUILD_SETTING) placeholder, never a real value.
PG_SECRET_PLIST_KEYS="MetaAppID ClientToken"

# pg_plist_secret_violations <plist-content>
# Echoes the credential keys that carry a real value. Empty output => clean.
pg_plist_secret_violations() {
    local content="$1" key hits=""
    for key in $PG_SECRET_PLIST_KEYS; do
        if printf '%s\n' "$content" | grep -A1 "<key>$key</key>" | grep -qE '<string>[^<$][^<]{2,}</string>'; then
            hits="$hits $key"
        fi
    done
    printf '%s' "$hits"
}

# pg_swift_secret_violations <swift-content>
#   4. A literal SDK app id + secret in code (the Insta360 SDK's activation call). The
#      vendor's own placeholders ("Appid", "secret", YOUR_..., <...>) are allowed.
#   Always returns 0: grep exits 1 when nothing matches, and under check-privacy.sh's
#   `set -eo pipefail` that status would end the whole scan, silently, at the first clean file.
pg_swift_secret_violations() {
    local content="$1"
    printf '%s\n' "$content" | grep -nE 'setAppid\("[^"]{4,}",[[:space:]]*secret:[[:space:]]*"[^"]{8,}"' \
        | grep -vE '"(Appid|secret|YOUR_[A-Za-z_]+|<[^>]+>)"' | cut -d: -f1 | tr '\n' ' ' || true
}

# pg_is_forbidden_path <path>  -> exit 0 if the path is a raw capture artifact.
pg_is_forbidden_path() {
    printf '%s\n' "$1" | grep -qE "$PG_FORBIDDEN_PATH_REGEX"
}
