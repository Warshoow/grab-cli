# Using grab inside a VSCode devcontainer

This guide covers known friction points when running `grab` inside a VSCode
devcontainer (or any container that inherits the same patterns: GitHub
Codespaces, JetBrains Dev Containers, etc.). It is **not** about running grab
on a "classic" host — there it works out of the box.

If you are not using devcontainers, you can ignore this document.

---

## Symptom

```
$ grab add my-tool
▸ Cloning tools repo (sparse)...
error: could not write config file /root/.gitconfig: Resource busy
```

The exact phrasing may vary slightly:

- `error: could not lock config file /root/.gitconfig: Device or resource busy`
- `fatal: could not write config file /home/vscode/.gitconfig: Resource busy`

Common to all variants: a write to the **global** gitconfig (`~/.gitconfig`)
fails inside the container, while the same operation works fine on the host.

---

## Root cause

### tl;dr

VSCode bind-mounts your host's `~/.gitconfig` into the container as a
**single file**. Linux does not allow `rename(2)` to replace a single-file
bind mount in place, and `git` always writes config atomically via a
rename → you get `EBUSY`.

### Detailed walkthrough

1. **VSCode mounts your host's gitconfig into the container.** When VSCode
   starts a devcontainer, it inspects your host environment and, by default,
   bind-mounts a few "convenience" files so the inner container feels like
   your normal shell. `~/.gitconfig` is one of them. The mount is a
   **file-level bind mount** (not a directory mount), which is the source of
   the entire problem.

2. **Why git wants to write to `~/.gitconfig`.** Even though `grab` itself
   only **reads** from gitconfig (see [`grab:486-487`](../grab#L486-L487)),
   the git binary it shells out to may need to *write* to the global config
   in several scenarios:

   - **Credential persistence.** A `git clone` of a private repo with
     `credential.helper=store` (or `cache`) will try to record the
     credential in `~/.gitconfig` or in a sibling file referenced from it.
   - **`safe.directory` auto-add.** Modern git (≥ 2.35) refuses to operate
     on a repository whose `.git` directory is owned by a different UID
     than the current process. Some VSCode workflows offer to fix this by
     appending a `safe.directory` entry to `~/.gitconfig`. That append is
     itself an atomic write.
   - **`init.defaultBranch` / first-run prompts.** Older git versions wrote
     defaults the first time they were used.
   - **Extensions / wrappers.** The VSCode Git extension, `gh`, `gpg-agent`
     hooks, etc. can all trigger writes to the global gitconfig as a side
     effect.

   Any of these triggers, when combined with the file-level bind mount,
   blows up with `EBUSY`.

3. **Why the rename fails.** Git writes config atomically:

   ```
   write  ~/.gitconfig.lock         # temp file in the same dir
   rename ~/.gitconfig.lock → ~/.gitconfig
   ```

   `rename(2)` on Linux requires that both source and target live on the
   **same mount**. A single-file bind mount has the host's filesystem on
   one side of the inode and the container's tmpfs / overlayfs on the
   other. The kernel returns `EBUSY` (or `EXDEV` on some configurations)
   and git surfaces it as `Resource busy`.

4. **Why this never happens on the host.** On a real filesystem,
   `~/.gitconfig` is a normal file in your home directory. Atomic rename
   works as designed. The error is **specific to the bind-mount setup**,
   not to grab and not to your gitconfig contents.

---

## Why grab seems to be the trigger

`grab` is usually one of the **first** things in a devcontainer to perform
a non-trivial git operation — typically `git clone --no-checkout
--filter=blob:none <repo>` against your tools monorepo. That clone is
where credential helpers, prompts, and `safe.directory` checks all fire
for the first time. The error surfaces under grab simply because grab is
the first to provoke it, not because grab is doing anything unusual.

Confirm this for yourself: run `git clone <any-private-repo>` in the
container, outside grab. You will get the same error.

---

## Fixes, in order of preference

### 1. Point git at a writable gitconfig inside the container *(recommended)*

This is the cleanest fix: leave the host bind-mount alone (so VSCode is
happy), and tell git to use a different file as its global config inside
the container via the `GIT_CONFIG_GLOBAL` environment variable.

In `.devcontainer/devcontainer.json`:

```jsonc
{
  "remoteEnv": {
    "GIT_CONFIG_GLOBAL": "/tmp/gitconfig"
  },
  "postCreateCommand": "cp ${HOME}/.gitconfig /tmp/gitconfig 2>/dev/null || touch /tmp/gitconfig"
}
```

What this does:

- `GIT_CONFIG_GLOBAL=/tmp/gitconfig` makes every `git` invocation in the
  container treat `/tmp/gitconfig` as `~/.gitconfig`. The mounted
  `~/.gitconfig` becomes inert — git ignores it.
- The `postCreateCommand` seeds `/tmp/gitconfig` with whatever was
  already in your bind-mounted gitconfig (your name, email, aliases,
  etc.), so you don't lose your identity. If the bind mount is empty or
  missing, it falls back to creating an empty file.

Pros: nothing destructive, host gitconfig remains untouched, all git
operations including those triggered by grab work normally.

Cons: changes you make inside the container (`git config --global ...`)
do **not** propagate back to the host. For most users this is desirable.

### 2. Remove the bind mount and copy the file at startup

If you don't need any host-side gitconfig sync, you can disable the
default mount:

```jsonc
{
  "mounts": [
    // Override the default ~/.gitconfig mount with nothing
  ],
  "postCreateCommand": "cp /workspaces/host-gitconfig.copy ~/.gitconfig 2>/dev/null || true"
}
```

You will need to make a snapshot of your host gitconfig available to the
container by other means (committed to your dotfiles, baked into the
image, fetched at start, etc.). Heavier setup than option 1.

### 3. Mount the home directory instead of the file

```jsonc
{
  "mounts": [
    "source=${localEnv:HOME},target=/host-home,type=bind,consistency=cached"
  ],
  "postCreateCommand": "cp /host-home/.gitconfig ~/.gitconfig"
}
```

This works because directory bind mounts allow rename within the mount.
But it exposes your entire host home directory to the container, which is
a much larger trust surface than just a gitconfig. **Not recommended**
unless you have a specific reason.

### 4. Disable credential helpers and `safe.directory` writes

If you can't change the devcontainer config, you can suppress the writes
that trigger the bug, at the cost of less convenient git behavior:

```bash
# Inside the container, before running grab:
git config --global --unset credential.helper 2>/dev/null || true
export GIT_CONFIG_NOSYSTEM=1
```

This is a workaround, not a fix. Credentials will need to be supplied
each time, and any code that expects to write to `~/.gitconfig` will
still fail — you've just narrowed the surface.

---

## Verification

To confirm the diagnosis on your machine:

```bash
# 1. Check whether ~/.gitconfig is a bind mount
mount | grep gitconfig
# Expected output if affected:
#   /host/path/to/.gitconfig on /root/.gitconfig type ... (bind)

# 2. Reproduce the error without grab
git clone https://github.com/some/private-repo /tmp/test-clone
# Same EBUSY error ⇒ devcontainer issue, not grab.

# 3. Apply fix #1 then re-run
export GIT_CONFIG_GLOBAL=/tmp/gitconfig
cp ~/.gitconfig /tmp/gitconfig 2>/dev/null || touch /tmp/gitconfig
grab add <tool>   # should succeed
```

To get the exact git command grab runs when the error fires:

```bash
GIT_TRACE=1 grab add <tool> 2>&1 | tee grab-trace.log
```

Look at the last `git ...` line before the `Resource busy` error — that's
the operation that triggered the write. Useful if you want to file a
more targeted issue or rule out an exotic git wrapper.

---

## Will grab itself ever fix this?

Probably not directly — the bug is in the **devcontainer mount pattern**,
not in grab. Grab cannot reasonably guarantee that every git operation it
delegates to will avoid touching the global config, because that depends
on your installed git version, your credential helpers, and your VSCode
extensions.

What grab **could** do (tracked in the [Roadmap](../README.md#roadmap--ideas)):

- A `grab doctor` command that detects this exact setup
  (file-level bind mount on `~/.gitconfig`) and prints the appropriate
  fix link before you ever hit the error.

If you want to push that forward, that's the right place to contribute.

---

## References

- `git-config(1)` documentation, section on `GIT_CONFIG_GLOBAL`
- `mount(2)` and `rename(2)` man pages for the underlying kernel behavior
- VSCode devcontainers docs: "Sharing Git credentials with your container"
