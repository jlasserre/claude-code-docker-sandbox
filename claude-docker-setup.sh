#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Claude Code Docker Sandbox — GitHub Auth Setup
# ============================================================
# This script prepares everything needed to run Claude Code
# inside a Docker container with working GitHub authentication.
#
# Usage:
#   chmod +x claude-docker-setup.sh
#   ./claude-docker-setup.sh
#
# It will:
#   1. Verify prerequisites (Docker, gh CLI, Claude Code)
#   2. Authenticate gh CLI if needed
#   3. Configure git credential helper
#   4. Build a Docker image with Claude Code pre-installed
#   5. Generate a launcher script (claude-sandbox.sh)
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

SANDBOX_DIR="${CLAUDE_SANDBOX_DIR:-$HOME/.claude-sandbox}"

# ── 1. Check prerequisites ──────────────────────────────────
info "Checking prerequisites…"

command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install from https://docs.docker.com/get-docker/"
docker info >/dev/null 2>&1      || die "Docker daemon is not running. Start Docker Desktop or 'sudo systemctl start docker'."
ok "Docker is available"

command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) is not installed. Install from https://cli.github.com/"
ok "GitHub CLI (gh) is available"

# ── 2. Ensure gh is authenticated ────────────────────────────
info "Checking GitHub CLI authentication…"
if ! gh auth status >/dev/null 2>&1; then
    warn "gh is not authenticated. Starting login flow…"
    gh auth login --web --git-protocol https
fi
ok "gh is authenticated"

# Configure git to use gh as credential helper on the host
info "Configuring git to use gh as credential helper (host side)…"
gh auth setup-git 2>/dev/null || true
ok "git credential helper configured"

# ── 3. Extract a fresh GitHub token ─────────────────────────
info "Extracting GitHub token from gh CLI…"
GH_TOKEN_VALUE=$(gh auth token 2>/dev/null) || die "Failed to extract token. Run 'gh auth login' manually."
ok "Token extracted (${GH_TOKEN_VALUE:0:8}…)"

# ── 4. Persist token in shell config (for Docker daemon) ─────
# Docker Desktop sandboxes read env vars from shell config,
# not the current shell session.
SHELL_RC=""
if   [[ -f "$HOME/.zshrc" ]];     then SHELL_RC="$HOME/.zshrc"
elif [[ -f "$HOME/.bashrc" ]];    then SHELL_RC="$HOME/.bashrc"
elif [[ -f "$HOME/.bash_profile" ]]; then SHELL_RC="$HOME/.bash_profile"
fi

if [[ -n "$SHELL_RC" ]]; then
    # Remove any old lines we added
    sed -i.bak '/# claude-sandbox-gh-token/d' "$SHELL_RC" 2>/dev/null || true
    echo "export GH_TOKEN=\"$GH_TOKEN_VALUE\"  # claude-sandbox-gh-token" >> "$SHELL_RC"
    echo "export GITHUB_TOKEN=\"$GH_TOKEN_VALUE\"  # claude-sandbox-gh-token" >> "$SHELL_RC"
    ok "Token written to $SHELL_RC (restart your shell or run: source $SHELL_RC)"
else
    warn "Could not find shell rc file. Export these manually:"
    echo "  export GH_TOKEN=\"$GH_TOKEN_VALUE\""
    echo "  export GITHUB_TOKEN=\"$GH_TOKEN_VALUE\""
fi

# Also export for this session
export GH_TOKEN="$GH_TOKEN_VALUE"
export GITHUB_TOKEN="$GH_TOKEN_VALUE"

# ── 5. Create sandbox directory structure ────────────────────
info "Creating sandbox directory at $SANDBOX_DIR …"
mkdir -p "$SANDBOX_DIR"

# ── 6. Build Docker image ───────────────────────────────────
info "Writing Dockerfile…"
cat > "$SANDBOX_DIR/Dockerfile" << 'DOCKERFILE'
FROM node:22-bookworm

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates openssh-client jq \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI (latest version, multi-arch)
RUN GH_VERSION=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/') \
    && ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.deb" -o /tmp/gh.deb \
    && dpkg -i /tmp/gh.deb && rm /tmp/gh.deb

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Create non-root user
RUN useradd -m -s /bin/bash claude
USER claude
WORKDIR /home/claude

# Git config defaults (overridden by mounted .gitconfig if present)
RUN git config --global init.defaultBranch main \
    && git config --global pull.rebase false

# Entrypoint script that wires up auth then launches Claude Code
COPY --chown=claude:claude entrypoint.sh /home/claude/entrypoint.sh
RUN chmod +x /home/claude/entrypoint.sh

ENTRYPOINT ["/home/claude/entrypoint.sh"]
DOCKERFILE

cat > "$SANDBOX_DIR/entrypoint.sh" << 'ENTRYPOINT'
#!/usr/bin/env bash
set -euo pipefail

# ── Import host .gitconfig if mounted ──
if [[ -f "$HOME/.gitconfig-host" ]]; then
    cp "$HOME/.gitconfig-host" "$HOME/.gitconfig"
    echo "[sandbox] Imported host .gitconfig"
fi

# ── Wire up GitHub authentication inside the container ──
# Priority: GH_TOKEN env var > mounted gh config > SSH agent

if [[ -n "${GH_TOKEN:-}" ]] || [[ -n "${GITHUB_TOKEN:-}" ]]; then
    TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
    # Configure git credential helper to use the token
    git config --global credential.helper '!f() { echo "protocol=https"; echo "host=github.com"; echo "username=x-access-token"; echo "password='"$TOKEN"'"; }; f'
    # Also make gh CLI aware
    export GH_TOKEN="$TOKEN"
    echo "[sandbox] GitHub auth: token from environment variable"
elif [[ -f "$HOME/.config/gh/hosts.yml" ]]; then
    echo "[sandbox] GitHub auth: mounted gh CLI config"
else
    echo "[sandbox] WARNING: No GitHub credentials found."
    echo "          Pass -e GH_TOKEN=\$(gh auth token) when starting the container."
fi

# ── Set up git identity if not already configured ──
if ! git config --global user.email >/dev/null 2>&1; then
    git config --global user.email "claude-sandbox@local"
    git config --global user.name "Claude (sandbox)"
fi

# ── Launch Claude Code or the provided command ──
if [[ $# -eq 0 ]]; then
    exec claude --dangerously-skip-permissions
else
    exec "$@"
fi
ENTRYPOINT

info "Building Docker image 'claude-sandbox'… (this may take a minute)"
docker build -t claude-sandbox "$SANDBOX_DIR" --quiet
ok "Docker image 'claude-sandbox' built"

# ── 7. Generate launcher script ─────────────────────────────
LAUNCHER="$SANDBOX_DIR/claude-sandbox.sh"
cat > "$LAUNCHER" << 'LAUNCHER_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# claude-sandbox.sh — Launch Claude Code in a Docker sandbox
#
# Usage:
#   claude-sandbox.sh [project-dir] [-- claude-code-args...]
#
# Examples:
#   claude-sandbox.sh                     # current directory
#   claude-sandbox.sh ~/my-project        # specific project
#   claude-sandbox.sh . -- -p "fix bugs"  # with a prompt
# ============================================================

PROJECT_DIR="$(pwd)"
CLAUDE_ARGS=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --)
            shift
            CLAUDE_ARGS=("$@")
            break
            ;;
        *)
            PROJECT_DIR="$(cd "$1" && pwd)"
            shift
            ;;
    esac
done

# ── Windows / Git Bash (MSYS2) compatibility ──
# Git Bash mangles Unix paths (e.g. /workspace → C:/Program Files/Git/workspace).
# Disable that for docker commands, and convert project paths to Windows format.
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || -n "${MSYSTEM:-}" ]]; then
    export MSYS_NO_PATHCONV=1
    export MSYS2_ARG_CONV_EXCL="*"
    # Convert MSYS path (/c/dev/foo) → Docker-compatible Windows path (C:/dev/foo)
    PROJECT_DIR="$(cygpath -w "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")"
fi

# Resolve the GitHub token (fresh each launch)
TOKEN=""
if [[ -n "${GH_TOKEN:-}" ]]; then
    TOKEN="$GH_TOKEN"
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    TOKEN="$GITHUB_TOKEN"
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    TOKEN="$(gh auth token 2>/dev/null || true)"
fi

if [[ -z "$TOKEN" ]]; then
    echo "⚠  No GitHub token found. git push/pull to GitHub will not work."
    echo "   Fix: run 'gh auth login' or export GH_TOKEN."
fi

# Build docker run arguments
DOCKER_ARGS=(
    --rm -it
    -v "$PROJECT_DIR:/workspace"
    -w /workspace
    -e "GH_TOKEN=${TOKEN}"
    -e "GITHUB_TOKEN=${TOKEN}"
    -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
)

# Mount Claude config for session persistence
CLAUDE_CONFIG_DIR="${HOME}/.claude"
if [[ -d "$CLAUDE_CONFIG_DIR" ]]; then
    HOST_PATH="$CLAUDE_CONFIG_DIR"
    [[ -n "${MSYS_NO_PATHCONV:-}" ]] && HOST_PATH="$(cygpath -w "$HOST_PATH" 2>/dev/null || echo "$HOST_PATH")"
    DOCKER_ARGS+=(-v "$HOST_PATH:/home/claude/.claude")
fi

# Mount host .gitconfig to a staging path (entrypoint will copy it)
if [[ -f "$HOME/.gitconfig" ]]; then
    HOST_PATH="$HOME/.gitconfig"
    [[ -n "${MSYS_NO_PATHCONV:-}" ]] && HOST_PATH="$(cygpath -w "$HOST_PATH" 2>/dev/null || echo "$HOST_PATH")"
    DOCKER_ARGS+=(-v "$HOST_PATH:/home/claude/.gitconfig-host:ro")
fi

# Mount gh CLI config (read-only) if it exists
GH_CONFIG_DIR="${HOME}/.config/gh"
if [[ -d "$GH_CONFIG_DIR" ]]; then
    HOST_PATH="$GH_CONFIG_DIR"
    [[ -n "${MSYS_NO_PATHCONV:-}" ]] && HOST_PATH="$(cygpath -w "$HOST_PATH" 2>/dev/null || echo "$HOST_PATH")"
    DOCKER_ARGS+=(-v "$HOST_PATH:/home/claude/.config/gh:ro")
fi

# Forward SSH agent if available
if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
    DOCKER_ARGS+=(
        -v "$SSH_AUTH_SOCK:/ssh-agent"
        -e "SSH_AUTH_SOCK=/ssh-agent"
    )
fi

echo "🚀 Launching Claude Code sandbox for: $PROJECT_DIR"
if [[ ${#CLAUDE_ARGS[@]} -gt 0 ]]; then
    exec docker run "${DOCKER_ARGS[@]}" claude-sandbox claude --dangerously-skip-permissions "${CLAUDE_ARGS[@]}"
else
    exec docker run "${DOCKER_ARGS[@]}" claude-sandbox
fi
LAUNCHER_SCRIPT

chmod +x "$LAUNCHER"

# ── 8. Symlink to a convenient location ─────────────────────
if [[ -d "$HOME/.local/bin" ]]; then
    ln -sf "$LAUNCHER" "$HOME/.local/bin/claude-sandbox"
    ok "Symlinked to ~/.local/bin/claude-sandbox"
elif [[ -d "$HOME/bin" ]]; then
    ln -sf "$LAUNCHER" "$HOME/bin/claude-sandbox"
    ok "Symlinked to ~/bin/claude-sandbox"
else
    mkdir -p "$HOME/.local/bin"
    ln -sf "$LAUNCHER" "$HOME/.local/bin/claude-sandbox"
    warn "Created ~/.local/bin/ — add it to your PATH if not already there:"
    echo '  export PATH="$HOME/.local/bin:$PATH"'
fi

# ── Done ─────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}✅ Setup complete!${NC}"
echo ""
echo "Launch Claude Code in a sandbox:"
echo "  claude-sandbox                          # current dir"
echo "  claude-sandbox ~/my-project             # specific project"
echo "  claude-sandbox . -- -p 'fix all bugs'   # with a prompt"
echo ""
echo "Or run directly:"
echo "  $LAUNCHER"
echo ""
echo "Don't forget to set ANTHROPIC_API_KEY in your environment"
echo "(or authenticate interactively when Claude Code starts)."
