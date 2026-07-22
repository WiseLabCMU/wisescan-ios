#!/bin/bash
# Install git hooks from scripts/ into .git/hooks/
# Run once after cloning: ./scripts/install-hooks.sh

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"

echo "Installing git hooks..."

# Shared library sourced by the hooks (must be installed alongside them)
cp "$REPO_ROOT/scripts/privacy-guard.sh" "$HOOKS_DIR/privacy-guard.sh"
echo "  ✅ privacy-guard.sh installed"

# Pre-commit hook
cp "$REPO_ROOT/scripts/pre-commit" "$HOOKS_DIR/pre-commit"
chmod +x "$HOOKS_DIR/pre-commit"
echo "  ✅ pre-commit hook installed"

# Pre-push hook (privacy backstop against --no-verify)
cp "$REPO_ROOT/scripts/pre-push" "$HOOKS_DIR/pre-push"
chmod +x "$HOOKS_DIR/pre-push"
echo "  ✅ pre-push hook installed"

echo "Done."
