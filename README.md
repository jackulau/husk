# husk

**Storage-efficient git worktrees.** Share heavy dependency dirs (`node_modules`,
`.venv`, `target/`, `vendor/`, `Pods/`) across all your worktrees instead of paying
for a full copy in each one, without giving up correctness.

100 worktrees with 1.2 GB of `node_modules` each is 120 GB of mostly identical
bytes. With husk it's a few GB. Built for agent-native workflows where 20-100
concurrent worktrees is normal.

One script, no dependencies. bash 3.2+ (stock macOS works), Linux, git.

## Install

One command, no dependencies, no sudo (installs to `~/.local/bin`):

```sh
curl -fsSL https://raw.githubusercontent.com/jackulau/husk/main/install.sh | bash
# or from a clone:
bash install.sh
```

The installer verifies the binary and tells you if PATH needs a line. `HUSK_BIN_DIR`
overrides the destination.

## Quickstart

```sh
cd my-repo            # your main checkout, deps already installed
husk setup --write    # seed the shared store + drop agent instructions into AGENTS.md

husk add ../wt-feature my-branch    # worktree + deps, one verb, done
cd ../wt-feature && npm test        # it just works
```

That's it. `husk add` is `git worktree add` plus dependency provisioning plus a
stale-worktree nudge, in one command. (`husk adopt` does the store seeding alone
if you don't want the AGENTS.md edit.)

## One-click agent adoption

Paste this to any coding agent (Claude Code, Cursor, etc.) working in your repo:

```text
Install husk and set this repo up for cheap worktrees: run curl -fsSL https://raw.githubusercontent.com/jackulau/husk/main/install.sh | bash, make sure ~/.local/bin is on PATH, then cd into the repo and run husk setup --write. From now on create worktrees with husk add <path> <branch> instead of git worktree add. If a husk command exits with code 2, run husk link --install.
```

`husk setup --write` is idempotent: it seeds the store from your installed deps and
appends a marked instruction block to `AGENTS.md` (or `CLAUDE.md` if that's what the
repo uses) exactly once, so every future agent session picks up the workflow with
zero re-prompting.

## How it works

husk keeps a **content-keyed store** (`~/.husk/store`). Each dependency dir is stored
under a key derived from its **lockfile hash** (plus OS and arch). Two worktrees share
an entry *only if* their lockfiles are byte-identical. Version skew across branches is
impossible by construction, not by discipline.

Worktrees are provisioned from the store using the best mechanism the filesystem
supports (the **strategy ladder**):

| mode | mechanism | storage | isolation | when |
|---|---|---|---|---|
| `clone` | copy-on-write clone (APFS, btrfs, XFS) | shared until divergence | full: writes are private | **default on every Mac and CoW Linux** |
| `hardlink` | hardlink farm | file-level dedupe | near-full | default on ext4 |
| `symlink` | link into shared store | maximal: one tree, N consumers | none: writes shared (guarded) | opt-in, one-lockfile fleets |
| `copy` | plain copy | none | full | last-resort fallback, always correct |

`clone` is the sweet spot: ~95% of symlink's storage win, 100% of a real dir's
correctness. Real paths, private writes, zero tooling caveats. Cross-agent
interference is structurally impossible.

Store entries themselves are **deduplicated across lockfile versions**. When a
branch bumps one dependency, the new store entry hardlinks every byte-identical
file to its nearest sibling entry (hash and permissions matched, fully batched,
no per-file forks). Measured on a 395 MB `node_modules` with one bumped package:
the second entry costs about 20 MB, not 395 MB. Off switch: `HUSK_DEDUPE=0`.

## Benchmarks

10 worktrees of a real repo (395 MB `node_modules`, 14,700 files, warm npm cache),
Apple Silicon, APFS. Disk is measured as real blocks consumed (`df` delta), not
apparent size:

| approach | wall time | disk consumed |
|---|---|---|
| `git worktree add` + `npm ci` per worktree | 27.1s | 4,013 MB |
| `husk add` (clone mode, default) | 30.5s | **61 MB** |
| `husk add` (hardlink mode) | 56.6s | 34 MB |
| `husk add` (symlink mode) | 4.3s | 2.5 MB |
| `husk add` (copy mode) | 70.0s | 4,038 MB |
| 10 **concurrent** `husk add` (agent-thread race) | 26.3s | 63 MB |

Notes worth being honest about: `npm ci` at 2.7s per worktree is a best case
(warm cache, fast SSD); cold caches or private registries make the baseline
minutes, while husk's numbers don't change. The concurrent run produced 10/10
working worktrees with one store entry and no partial trees; wall time is bounded
by git's own worktree lock, not by husk. Store dedupe across two lockfile
versions: the second entry cost 21 MB instead of 395 MB and took about 11s to
seed. Reproduce with `test/run.sh` plus the commands above.

## Commands

```
husk add <path> [branch]     create worktree + link deps (+ reap nudge)
husk link [dir...]           link/provision deps in current worktree
   --install                 store miss? run the right installer (npm ci / pnpm / uv ...)
   --mode clone|hardlink|symlink|copy
husk unlink [dir...]         materialize a private copy, stop sharing
husk adopt                   seed store from this checkout's real dirs
husk setup [--write]         adopt + agent instructions (--write: append to AGENTS.md once)
husk status                  link states, lockfile drift, store size
husk doctor [--fix]          detect/repair dangling links, drift, stale locks
husk reap [--dry-run]        delete stale worktrees (clean + merged/gone + idle 7d)
husk gc [--dry-run]          drop store entries no worktree references
husk dedupe                  hardlink identical files across store entries
```

Machine-readable: stdout is stable `key=value` lines, prose goes to stderr.
Exit codes: `0` ok, `2` needs install, `1` error.

## Agent workflow (20-100 worktrees)

```sh
# spawn phase - each agent gets a cheap worktree in seconds
husk add ../agents/task-042 fix/issue-042

# lockfile changed on a branch? husk refuses to share stale deps (exit 2), so:
husk link --install          # installs correctly, seeds the store for siblings

# fleet hygiene - no daemon, run whenever (husk add nudges you)
husk reap                    # clean + merged + idle worktrees deleted
husk gc                      # store entries nobody uses anymore
```

`husk setup --write` drops the equivalent of this into your `AGENTS.md` automatically:

> To create a worktree, use `husk add <path> <branch>` instead of `git worktree add`.
> If a husk command exits 2, run `husk link --install`. Never delete `~/.husk/store`.

Why agents like it: every command is **idempotent** (retry freely), **self-healing**
(dangling links are detected and repaired on the spot), and **parseable**. There is
no daemon and no proxy. husk never intercepts git, so nothing else in the toolchain
changes behavior.

## Tradeoffs, honestly

| axis | how husk handles it |
|---|---|
| **Correctness / isolation** | Store entries are keyed by lockfile hash, so a branch with a different lockfile can never silently get the wrong deps. Default `clone` mode gives fully private writes. A worktree whose lockfile changed is *refused* sharing until deps are reinstalled (`--install`) or explicitly trusted (`adopt`). |
| **Concurrency / write contention** | Store seeding is serialized by a portable lock with atomic rename: 100 parallel `husk link` calls produce exactly one entry, and no partial tree is ever visible. Provisioning from an existing entry is lock-free. In `symlink` mode the entry root is made read-only, so direct writes fail loudly (EACCES). An accidental `npm install` can't poison siblings either: npm replaces the symlink with a fresh private dir (correct results, sharing silently lost, and `husk status` flags it as `not-a-link`). |
| **Tooling assumptions** | `clone`, `hardlink`, and `copy` produce real directories, and no tool can tell the difference. `symlink` mode has the classic realpath caveats (Node's `__dirname` resolves into the store; Docker build contexts can't follow it), which is why it's opt-in rather than the default. Python venvs are path-bound by design: symlink mode works, clone mode is flagged by `doctor`. If you use `uv` or a global-cache package manager (pnpm, Go modules), you already have most of this; husk adds the most for npm-style per-project dirs. |
| **When it breaks** | Every failure degrades toward `copy`, which is always correct. Dangling link: `husk doctor --fix` re-provisions. Lockfile drift: `status` and `doctor` flag it, `link` re-keys, `unlink` goes private. Store deleted: worktrees re-seed from any checkout with real dirs. husk can never make a worktree *less* correct than a plain worktree, only cheaper. |

## Stale worktree reaping

Fleets go stale. `husk reap` deletes worktrees that are **provably abandoned**,
meaning all of:

1. working tree clean (nothing uncommitted)
2. branch merged into the default branch, or its upstream is gone
3. no activity for `HUSK_REAP_DAYS` (default 7)

Anything dirty or unmerged is never touched. There is deliberately no `--force`.
`husk add` prints a nudge when stale worktrees exist, so fleets stay bounded without
any resident process.

## Configuration

Environment (or `.husk.conf` at repo root, shell syntax):

```sh
HUSK_STORE=~/.husk/store      # store location
HUSK_MODE=auto                # auto | clone | hardlink | symlink | copy
HUSK_DIRS="node_modules"      # override auto-detection
HUSK_REAP_DAYS=7              # reap idle threshold
HUSK_DEDUPE=1                 # hardlink identical files across store entries at seed time
```

## What husk is not

- **Not a package manager.** It shares and clones what your installer produced; it
  never resolves a dependency.
- **Not a daemon.** Every guarantee holds via on-invocation checks and atomic
  filesystem operations.
- **Not a git proxy.** Considered and rejected: PATH shims over `git` are fragile
  and surprising. One extra verb (`husk add`) buys the same ergonomics safely.
- **Not Windows-ready** (v1). Symlink privileges and no clonefile; NTFS hardlinks
  could work as future work.

## License

[Apache 2.0](LICENSE).

## Development

```sh
./test/run.sh     # 46 tests, no framework, ~30s
shellcheck bin/husk install.sh
```
