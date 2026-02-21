# mux — Multi-Repo Session Multiplexer

Run multiple AI coding agents on the same multi-repo project in parallel using OverlayFS and bind mounts. No containers, no file copying, no symlinks.

## Problem

Multiple AI agents editing the same repos simultaneously causes conflicts. Compilers need stable paths. Symlinks leak into build caches. Full copies waste disk. Each agent needs independent git state.

## How It Works

- **OverlayFS** gives each agent a copy-on-write view of the original repos. Edits go to a thin diff layer; originals stay untouched.
- **Bind mounts** switch the compiler's view between sessions at the original path, so build tools don't need reconfiguration.

```
/project/a            original repo (read-only lower layer)
/project/a_1          agent 1 view (overlay: origin + session 1 diffs)
/project/a_2          agent 2 view (overlay: origin + session 2 diffs)
/project/a            compiler view (bind-mounted to a_1 or a_2, or unmounted = origin)
```

## Requirements

- Linux with OverlayFS support (kernel 3.18+)
- `sudo` access (mount operations)

## Usage

```bash
# Register repos
./mux init -w /workspace -r /path/to/a,/path/to/b,/path/to/c

# Create sessions
./mux create 1       # creates a_1/, b_1/, c_1/ (overlay mounts)
./mux create 2       # creates a_2/, b_2/, c_2/

# Agents edit in their session dirs freely

# Compile against a session
./mux switch 1       # a/, b/, c/ now show session 1
make -C /path/to/a

# Switch to another session
./mux switch 2       # session 1 build artifacts preserved

# Return to clean state
./mux switch origin  # originals visible again

# Check state
./mux status

# Re-mount after reboot
./mux remount        # all sessions, or: ./mux remount 1
```

## Commands

| Command | Description |
|---------|-------------|
| `mux init -w <workspace> -r <paths>` | Register workspace and repos. No files moved. |
| `mux create <id>` | Create session with OverlayFS per repo. |
| `mux switch <id\|origin>` | Bind-mount session to compiler paths, or unmount for origin. |
| `mux status` | Show repos, sessions, mount states. |
| `mux remount [id]` | Re-mount sessions after reboot. |
| `mux help` | Usage and manual teardown instructions. |

## Manual Teardown

```bash
./mux switch origin
sudo umount /path/to/a_1 /path/to/b_1
sudo rm -rf /workspace/.mux/sessions/1
sudo rmdir /path/to/a_1 /path/to/b_1
```

## Things to Know

### Git

- Each session gets a CoW copy of `.git/` on first write. This means the first `git` operation in a session (commit, checkout, etc.) triggers a copy of the affected `.git/` internals to the upper layer. For large repos, this initial CoW may take a moment.
- Sessions diverge from origin immediately. There is no automatic merge-back. You need to manually extract changes (e.g., `git diff`, `git format-patch`) from the session's agent view and apply them to the origin.
- `git gc` and repacking in a session will copy packed objects to upper, consuming more disk. Avoid running it in sessions unless necessary.

### Compilation

- Build artifacts written via the compiler view (`/project/a`) land in whichever session is currently switched in. If you forget to switch, artifacts go to the wrong session.
- Switching sessions does **not** invalidate build caches. If repo `a` session 1 and session 2 have different source changes, stale `.o` files from a previous session's build won't be cleaned automatically. Run `make clean` or equivalent after switching if your build system doesn't track dependencies well.
- The compiler view path must not be used while switching. Ensure no process has files open under `/project/a` before running `mux switch`, or `umount` will fail with "device busy."

### Execution / Runtime

- Running programs from a session that reference other repos by path (e.g., a binary in `a` loading a config from `b`) will see whichever view is currently bind-mounted at `b`. Make sure all relevant repos are switched to the same session before running.
- OverlayFS upper/work dirs must be on the same filesystem. If your workspace is on a different mount than the repo, you may hit mount errors.
- NFS is not supported as the upper dir filesystem.
- After a reboot, all mounts are lost. Run `mux remount` to restore. Session diffs persist on disk.

## Tests

```bash
./mux_test.sh    # prompts for sudo password
```

92 assertions across 19 tests covering isolation, git CoW, compiler view switching, remount, error handling, and a full multi-repo workflow simulation.

---

Built with [Antigravity](https://github.com/google-deepmind/antigravity) (Opus 4.6, Plan mode) on 2026-02-21.

## License

MIT
