# Claude Code Docker Sandbox

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) inside an isolated Docker container with **GitHub authentication that just works** — on Linux, macOS, and Windows (Git Bash).

## Why?

Running Claude Code in Docker gives you the safety of `--dangerously-skip-permissions` (Claude can't escape the container) but introduces a painful problem: GitHub auth breaks. SSH keys aren't available, `gh` isn't authenticated, and `git push` fails.

This project solves that with a single setup script that:

- ✅ Builds a Docker image with Claude Code + GitHub CLI pre-installed
- ✅ Forwards your GitHub credentials into the container automatically
- ✅ Generates a `claude-sandbox` launcher you can use from anywhere
- ✅ Handles Windows/Git Bash path mangling issues
- ✅ Supports SSH agent forwarding as a fallback
- ✅ Always fetches the latest `gh` CLI version (no hardcoded URLs that 404)

## Quick Start

### Prerequisites

| Tool | Install |
|------|---------|
| Docker | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/) |
| GitHub CLI (`gh`) | [cli.github.com](https://cli.github.com/) |
| Anthropic API key | [console.anthropic.com](https://console.anthropic.com/) → API Keys |

### Install

```bash
git clone https://github.com/YOUR_USERNAME/claude-code-docker-sandbox.git
cd claude-code-docker-sandbox
chmod +x claude-docker-setup.sh
./claude-docker-setup.sh
```

The setup script will:
1. Verify Docker and `gh` are installed and running
2. Authenticate `gh` if needed (opens a browser)
3. Extract your GitHub token and persist it in your shell config
4. Build the `claude-sandbox` Docker image
5. Install the `claude-sandbox` command on your PATH

### Use

```bash
# Launch in the current directory
claude-sandbox

# Launch for a specific project
claude-sandbox ~/projects/my-app

# Launch with a Claude Code prompt
claude-sandbox ~/projects/my-app -- -p "refactor the auth module"
```

### Set your API key

```bash
export ANTHROPIC_API_KEY="sk-ant-api03-..."
```

Add this to your `~/.bashrc` or `~/.zshrc` to persist it. If you're on a Claude **Pro** or **Max** plan, you can skip this — Claude Code will prompt you to authenticate via OAuth instead.

## How It Works

The launcher script runs on every `claude-sandbox` invocation and:

1. Extracts a **fresh** GitHub token from `gh auth token`
2. Passes it as `GH_TOKEN` into the container
3. The container's entrypoint configures a **git credential helper** that uses the token for all HTTPS GitHub operations
4. Mounts your project directory, `.gitconfig`, `gh` config, and `.claude` session data

### Auth Priority

| Priority | Method | Details |
|----------|--------|---------|
| 1st | `GH_TOKEN` env var | Extracted from `gh auth token` each launch |
| 2nd | Mounted `~/.config/gh` | Full `gh` CLI config (read-only) |
| 3rd | SSH agent forwarding | If `SSH_AUTH_SOCK` is set on the host |

## Windows / Git Bash Support

Git Bash (MSYS2) mangles Unix paths, turning Docker's `-w /workspace` into `C:/Program Files/Git/workspace`. The launcher auto-detects Git Bash and:

- Sets `MSYS_NO_PATHCONV=1` to prevent path mangling
- Converts mount paths via `cygpath -w` for Docker Desktop compatibility

No manual workarounds needed.

## What's in the Docker Image

| Component | Purpose |
|-----------|---------|
| `node:22-bookworm` | Base image (Node.js required by Claude Code) |
| `@anthropic-ai/claude-code` | Claude Code CLI |
| `gh` (latest) | GitHub CLI for PRs, issues, auth |
| `git`, `curl`, `jq`, `openssh-client` | Standard dev tools |

## File Structure

```
claude-code-docker-sandbox/
├── README.md                  # This file
├── GUIDE.md                   # Detailed guide and troubleshooting
├── claude-docker-setup.sh     # One-time setup script
├── LICENSE                    # MIT License
└── .gitignore
```

After running `claude-docker-setup.sh`, the following is created at `~/.claude-sandbox/`:

```
~/.claude-sandbox/
├── Dockerfile                 # Image definition
├── entrypoint.sh              # Container entrypoint (wires up auth)
└── claude-sandbox.sh          # Launcher script (symlinked to PATH)
```

## Troubleshooting

See [GUIDE.md](GUIDE.md) for detailed troubleshooting, including:

- "Permission denied (publickey)" on git push
- "gh: not authenticated" inside the container
- Token expired / 401 errors
- Docker Desktop Sandbox (`docker sandbox`) env var issues
- Corporate proxy / firewall issues

## Security Notes

- Claude runs with `--dangerously-skip-permissions` — safe because it's **isolated inside Docker** and can only access your mounted project directory.
- `~/.gitconfig` and `~/.config/gh` are mounted **read-only**.
- The `GH_TOKEN` is visible inside the container. Don't use this in shared or multi-tenant environments.
- For production CI/CD, use the official [Claude Code GitHub Action](https://github.com/anthropics/claude-code-action) instead.

## License

[MIT](LICENSE)
