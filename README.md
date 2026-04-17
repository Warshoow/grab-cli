# grab

> Pull individual tools from a monorepo into any project.

`grab` is a small Bash script that lets you maintain a single monorepo of shared tools (CLIs, scripts, dev utilities, Docker helpers...) and cherry-pick them into any project on demand — without cloning the whole repo, without Git submodules, without copy-paste.

Think of it as a mix between `npm install` and `git sparse-checkout`, but dead simple.

## Why

You probably have a folder of useful scripts you copy from project to project. Over time they drift, get patched in one place but not the others, and you lose track of which version is the good one.

`grab` solves this with one rule: **the monorepo is the source of truth**, and every project pulls only what it needs.

- No submodules, no vendoring headaches
- Sparse checkout (`--filter=blob:none`) — only the tools you ask for are downloaded
- Per-project manifest (`.grabfile`) so anyone cloning your project can run `grab install` and get the same tools
- Optional pinning to a branch or tag per tool

## Installation

Drop the script somewhere in your `$PATH` and make it executable:

```bash
curl -o ~/.local/bin/grab https://raw.githubusercontent.com/Warshoow/grab/main/grab
chmod +x ~/.local/bin/grab
```

Or clone this repo and symlink it:

```bash
git clone https://github.com/Warshoow/grab.git
ln -s "$PWD/grab/grab" ~/.local/bin/grab
```

Requirements: `bash`, `git` (>= 2.25 for sparse-checkout cone mode).

## Quick start

```bash
# 1. One-time global setup (optional but recommended)
grab setup git@github.com:you/tools.git git@github.com:you/grab.git

# 2. In any project
cd my-project
grab init git@github.com:you/tools.git

# 3. Pull a tool
grab add stripe-cli

# 4. Pin one to a tag
grab add docker-utils @v2.1

# 5. Run it
grab exec stripe-cli listen --forward-to localhost:3000
```

That's it. The tool ends up in `.grab/tools/stripe-cli/` and is tracked in `.grabfile`.

## How it works

When you `grab add <tool>`, the script:

1. Sparse-clones your tools monorepo into `.grab/.repo/` (the first time only — `--filter=blob:none` keeps it tiny)
2. Adds `<tool>` to the sparse-checkout cone, so only that subdirectory is materialized
3. Copies `.grab/.repo/<tool>/` into `.grab/tools/<tool>/`
4. Records the tool (and optional ref) in `.grabfile`
5. Adds `.grab/` to `.gitignore` so the cache and tools stay out of your repo

Other contributors clone your project, run `grab install`, and get the same tools at the same versions.

## Commands

| Command | Description |
|---|---|
| `grab init <repo-url>` | Initialize grab in the current project |
| `grab add <tool> [@ref]` | Add a tool, optionally pinned to a branch or tag |
| `grab remove <tool>` | Remove a tool from the project |
| `grab update [tool]` | Pull updates from the repo (one or all tools) |
| `grab push <tool> ["msg"]` | Push local changes back to the repo |
| `grab install` | Install every tool listed in `.grabfile` |
| `grab list [--remote]` | List installed tools (or available ones in the repo) |
| `grab status` | Show grab status for the current project |
| `grab path <tool>` | Print the absolute path to a tool (handy for scripts) |
| `grab exec <tool> [args]` | Run a tool's entrypoint script |
| `grab hook <tool>` | Run a tool's post-grab hook manually |
| `grab clean` | Remove the cached repo (keeps installed tools) |
| `grab self-update` | Update the `grab` script itself |
| `grab setup [tools-repo] [grab-repo]` | Configure global defaults |
| `grab help` | Show help |

Aliases: `rm` for `remove`, `i` for `install`, `ls` for `list`, `run` for `exec`.

## Layout of a tools monorepo

`grab` expects each tool to live in its own top-level directory at the root of your monorepo:

```
your-tools-repo/
├── stripe-cli/
│   ├── run.sh           # entrypoint (optional, for `grab exec`)
│   └── TOOL.md          # first line is used as description in `grab list --remote`
├── docker-utils/
│   ├── main.sh
│   └── README.md
└── devcontainer/
    ├── .devcontainer/
    │   └── devcontainer.json
    └── post-grab.sh     # hook: moves .devcontainer/ to the project root
```

For `grab exec <tool>` to work, the tool must contain one of: `run.sh`, `main.sh`, `<tool>.sh`, or `entrypoint.sh`.

## Post-grab hooks

A tool can include a `post-grab.sh` script at its root. This hook runs after the tool is installed and can automate setup steps like moving files to the right place, symlinking configs, or printing instructions.

**Example** — a `devcontainer` tool whose hook copies `.devcontainer/` to the project root:

```bash
#!/usr/bin/env bash
# post-grab.sh for the devcontainer tool
cp -r "${GRAB_TOOL_DIR}/.devcontainer" "${GRAB_PROJECT_DIR}/.devcontainer"
echo "Installed .devcontainer to project root"
```

By default, `grab add` and `grab install` will **ask before running** a hook. You can override this:

```bash
grab add devcontainer --hook       # always run the hook
grab add devcontainer --no-hook    # skip the hook
grab install --hook                # run all hooks without asking
```

To run a hook manually at any time:

```bash
grab hook devcontainer
```

The following environment variables are available inside the hook:

| Variable | Description |
|---|---|
| `GRAB_TOOL_NAME` | Name of the tool (e.g., `devcontainer`) |
| `GRAB_TOOL_DIR` | Absolute path to the installed tool directory |
| `GRAB_PROJECT_DIR` | Absolute path to the project root |

## The `.grabfile`

Created by `grab init` at the root of your project. Format:

```
repo=git@github.com:you/tools.git
# Tools listed below, one per line
# format: tool_name [@branch_or_tag]
stripe-cli
docker-utils @v2.1
deploy-helper @main
```

Commit it to your project so collaborators can `grab install`.

## Configuration

Repo URLs are resolved in this order:

1. `.grabfile` (the `repo=` line)
2. `$GRAB_REPO` environment variable
3. `~/.config/grab/config` (set via `grab setup`)

The default branch used by `grab update` / `grab install` follows the same resolution (defaults to `main`):

1. `.grabfile` (the `branch=` line)
2. `$GRAB_BRANCH` environment variable
3. `~/.config/grab/config` (the `branch=` line)

The global config file looks like:

```
# grab global configuration
repo=git@github.com:you/tools.git
grab_repo=git@github.com:you/grab.git
branch=main
```

- `repo` — your tools monorepo (default for `grab init`)
- `grab_repo` — where the `grab` script lives, used by `grab self-update`
- `branch` — default branch to track in the tools repo (optional, defaults to `main`)

## Files grab creates

| Path | Purpose |
|---|---|
| `.grabfile` | Project manifest (commit this) |
| `.grab/tools/` | Where installed tools live (gitignored) |
| `.grab/.repo/` | Cached sparse checkout (gitignored, removable with `grab clean`) |
| `~/.config/grab/config` | Global configuration |

## Self-update

`grab` lives in its own repo, separate from your tools. Configure it once:

```bash
grab setup <tools-repo> <grab-repo>
```

Then `grab self-update` will fetch the latest version, compare `GRAB_VERSION`, and replace itself in place (using `sudo` if necessary).

## Roadmap / Ideas

Potential evolutions, not committed to:

- `grab self-update --force` — skip the `GRAB_VERSION` comparison and always replace the local script. Useful during active development when pushing changes without bumping the version.
- `grab self-update --ref <branch|tag|sha>` — pull a specific revision instead of the default branch tip.
- `grab doctor` — sanity-check the local environment (git version, sparse-checkout support, repo reachability, `.grabfile` validity).
- Lockfile (`.grabfile.lock`) pinning each tool to a resolved commit SHA for fully reproducible installs.
- Post-install hooks per tool (e.g. `grab.hook` script run after `grab add`).
- Shell completion (bash/zsh/fish) for tool names from the remote repo.
- Avoid duplicating tool data between `.grab/.repo/<tool>/` (sparse-checkout cache) and `.grab/tools/<tool>/` (working copy) — current behavior is `cp -r`. Could use hard links (`cp -al` on Linux, `mklink /H` on Windows NTFS) for zero disk overhead, or an opt-in `grab add --linked` that symlinks directly into the cache (faster updates, but exposes `.git` and breaks on `grab clean`).

## License

MIT
