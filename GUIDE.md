# Running Claude Code in a Docker Sandbox with GitHub Auth

## The Problem

Running Claude Code inside Docker means GitHub authentication doesn't "just work." The container can't access your host's SSH agent, `gh` CLI session, or git credential store — so `git push`, `git clone` of private repos, and `gh pr create` all fail with permission errors.

## The Solution (TL;DR)

Run the automated setup script:

```bash
chmod +x claude-docker-setup.sh
./claude-docker-setup.sh
```

Then launch with:

```bash
claude-sandbox ~/my-project
```

The rest of this document explains what the script does and how to troubleshoot.

---

## Step-by-Step Procedure

### 1. Prerequisites

Install these on your **host machine**:

- **Docker** — [docs.docker.com/get-docker](https://docs.docker.com/get-docker/)
- **GitHub CLI (`gh`)** — [cli.github.com](https://cli.github.com/)
- **Node.js ≥ 22** — only needed if you also run Claude Code outside Docker
- An **Anthropic API key** (set `ANTHROPIC_API_KEY` in your environment)

### 2. Authenticate `gh` on the Host

```bash
gh auth login --web --git-protocol https
```

Choose HTTPS (not SSH) as the git protocol — it's much easier to forward into containers. After login, configure git to use `gh` as its credential helper:

```bash
gh auth setup-git
```

### 3. Understand the Auth Forwarding Strategy

There are three ways to get GitHub credentials into a container. The setup script uses **all three as fallbacks**, in priority order:

| Method | How | Pros | Cons |
|--------|-----|------|------|
| **`GH_TOKEN` env var** (preferred) | `-e GH_TOKEN=$(gh auth token)` | Simple, works everywhere | Token visible in `docker inspect` |
| **Mount gh config** | `-v ~/.config/gh:/home/user/.config/gh:ro` | Full gh CLI works | Mounts a directory |
| **SSH agent forwarding** | `-v $SSH_AUTH_SOCK:/ssh-agent` | Works with SSH-based git remotes | Doesn't work on all OS/Docker combos |

The `GH_TOKEN` env var approach is the most reliable. The container's entrypoint script configures a git credential helper that uses this token for all HTTPS GitHub operations.

### 4. Build the Docker Image

The setup script builds an image called `claude-sandbox` containing:

- Node.js 22 (required by Claude Code)
- Claude Code CLI (`@anthropic-ai/claude-code`)
- GitHub CLI (`gh`)
- Git, curl, jq, openssh-client
- An entrypoint that wires up GitHub auth automatically

### 5. Launch Claude Code

The generated launcher script (`claude-sandbox.sh`) handles:

- Extracting a **fresh** `GH_TOKEN` from `gh auth token` on each launch
- Mounting your project directory into the container at `/workspace`
- Mounting your `~/.claude` config for session persistence
- Mounting `~/.gitconfig` read-only so your git identity is preserved
- Forwarding `SSH_AUTH_SOCK` if available
- Passing `ANTHROPIC_API_KEY` through

```bash
# Current directory
claude-sandbox

# Specific project
claude-sandbox ~/projects/my-app

# With a Claude Code prompt
claude-sandbox ~/projects/my-app -- -p "refactor the auth module"
```

---

## Troubleshooting

### "working directory is invalid" on Windows / Git Bash

Git Bash (MSYS2) automatically converts Unix-style paths like `/workspace` into `C:/Program Files/Git/workspace`, which Docker rejects. The launcher script now detects Git Bash and sets `MSYS_NO_PATHCONV=1` automatically. If you're running `docker run` manually, prefix it:

```bash
MSYS_NO_PATHCONV=1 docker run -w /workspace ...
```

### "Permission denied (publickey)" on git push

Your remote is set to SSH (`git@github.com:...`). Inside the container, switch to HTTPS:

```bash
git remote set-url origin https://github.com/OWNER/REPO.git
```

Or, if you need SSH, make sure your SSH agent is running on the host and your key is loaded:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

The launcher script will forward the agent socket automatically.

### "gh: not authenticated" inside the container

Check that `GH_TOKEN` is set:

```bash
echo $GH_TOKEN | head -c 12
```

If empty, your host `gh` session may have expired. Re-authenticate:

```bash
gh auth login --web
```

### Token expired / 401 errors

GitHub OAuth tokens from `gh auth token` expire. The launcher script extracts a fresh token on every launch, but if you're inside a long-running container, re-launch to refresh.

### Docker Desktop Sandboxes (docker sandbox command)

If you're using Docker Desktop's built-in `docker sandbox` feature rather than plain `docker run`, the daemon doesn't inherit env vars from your current shell. You must set `ANTHROPIC_API_KEY` and `GH_TOKEN` in your **shell config file** (`~/.zshrc` or `~/.bashrc`), then restart Docker Desktop:

```bash
echo 'export ANTHROPIC_API_KEY="sk-ant-..."' >> ~/.zshrc
echo 'export GH_TOKEN="$(gh auth token)"' >> ~/.zshrc
# Restart Docker Desktop after this
```

### Container can't resolve github.com

If you're behind a corporate proxy or firewall, pass proxy env vars:

```bash
docker run ... -e HTTP_PROXY -e HTTPS_PROXY -e NO_PROXY claude-sandbox
```

---

## Security Notes

- The container runs with `--dangerously-skip-permissions`, which is safe because it's isolated inside Docker — Claude can't escape to your host filesystem.
- Your project directory is mounted read-write so Claude can edit files. This is intentional.
- `~/.gitconfig` and `~/.config/gh` are mounted **read-only**.
- The `GH_TOKEN` is visible inside the container. Don't use this setup in shared or multi-tenant environments.
- For production CI/CD, use the official [Claude Code GitHub Action](https://github.com/anthropics/claude-code-action) instead.
