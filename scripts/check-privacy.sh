#!/bin/bash
# Repo-wide privacy check: fails if the committed tree carries debug-only
# file-sharing plist keys or raw capture artifacts. Shares its patterns with the
# git hooks via privacy-guard.sh, so the hooks and CI can never drift.
#
#   Run locally:  ./scripts/check-privacy.sh        (checks HEAD)
#   Check a ref:  ./scripts/check-privacy.sh <ref>
#   In CI:        .github/workflows/lint.yml (check-privacy job)
#
# It inspects the committed tree (not the working tree), so a developer who keeps
# the debug keys as a LOCAL uncommitted edit is not flagged — only what would
# actually land in the repo is.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(git rev-parse --show-toplevel)"
. "$SCRIPT_DIR/privacy-guard.sh"

REF="${1:-HEAD}"
fail=0

annotate() {  # annotate <file> <message>
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::error file=$1::$2"
    else
        echo "❌ $1: $2"
    fi
    fail=1
}

while IFS= read -r -d '' f; do
    case "$f" in
    *.plist)
        hits=$(pg_plist_violations "$(git show "$REF:$f" 2>/dev/null || true)")
        if [ -n "$hits" ]; then
            annotate "$f" "debug-only key(s)$hits must be local-only, never committed"
        fi
        ;;
    *.pbxproj)
        hits=$(pg_pbxproj_violations "$(git show "$REF:$f" 2>/dev/null || true)")
        if [ -n "$hits" ]; then
            annotate "$f" "file-sharing key(s)$hits via INFOPLIST_KEY_ build settings — same leak as the plist keys, local-only"
        fi
        ;;
    esac
    if pg_is_forbidden_path "$f"; then
        annotate "$f" "raw capture artifact committed (unblurred imagery of people)"
    fi
done < <(git ls-tree -r --name-only -z "$REF")

if [ "$fail" -ne 0 ]; then
    echo "See CONTRIBUTING.md -> Privacy Filtering Patterns."
    exit 1
fi
echo "✅ $REF: no debug file-sharing keys or raw capture artifacts in the committed tree"
