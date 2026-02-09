#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Quick script to create a GitHub repo and push everything.
#
# Usage:
#   ./push-to-github.sh                    # uses default name
#   ./push-to-github.sh my-custom-name     # custom repo name
# ============================================================

REPO_NAME="${1:-claude-code-docker-sandbox}"

echo "📦 Creating GitHub repo: $REPO_NAME"

# Create the repo (public, with description)
gh repo create "$REPO_NAME" \
    --public \
    --description "Run Claude Code in a Docker sandbox with GitHub auth that just works (Linux/macOS/Windows)" \
    --source . \
    --remote origin \
    --push

echo ""
echo "✅ Done! Your repo is live at:"
gh repo view --web 2>/dev/null || gh repo view --json url -q '.url'
