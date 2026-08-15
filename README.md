# husk

**Storage-efficient git worktrees.** Share heavy dependency dirs (`node_modules`,
`.venv`, `target/`, `vendor/`, `Pods/`) across all your worktrees instead of paying
for a full copy in each one, without giving up correctness.

100 worktrees with 1.2 GB of `node_modules` each is 120 GB of mostly identical
bytes. With husk it's a few GB. Built for agent-native workflows where 20-100
concurrent worktrees is normal.

One script, no dependencies. bash 3.2+ (stock macOS works), Linux (suite green on
Ubuntu 24.04), Windows via WSL or native Git Bash (suite green on both).

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
| `symlink` | link into shared store (a directory junction on Windows) | maximal: one tree, N consumers | none: writes shared (guarded) | opt-in, one-lockfile fleets |
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
| `husk add` (clone mode, default) | **20.1s** | **61 MB** |
| `husk add` (hardlink mode) | 51.6s | 39 MB |
| `husk add` (symlink mode) | 4.3s | 2.5 MB |
| `husk add` (copy mode) | 45.7s | 3,954 MB |
| 10 **concurrent** `husk add` (agent-thread race) | 26.3s | 63 MB |

Provisioning fans out per-package across cores (capped at 8 jobs), so the default
path is faster than a warm-cache `npm ci` while consuming 66x less disk. Notes
worth being honest about: `npm ci` at 2.7s per worktree is a best case (warm
cache, fast SSD); cold caches or private registries make the baseline minutes,
while husk's numbers don't change. Hardlink mode is bounded by `link(2)` speed on
APFS; on ext4, where it's the default, links are much cheaper. The concurrent run
produced 10/10 working worktrees with one store entry and no partial trees; wall
time is bounded by git's own worktree lock, not by husk. Store dedupe across two
lockfile versions: the second entry cost 21 MB instead of 395 MB. Reproduce with
`test/run.sh` plus the commands above.

The table above is the APFS `clone`-mode best case. A second run on NTFS
`hardlink` mode, against a real ~400 MB, ~21,000-file `node_modules` with total
disk remeasured after every single `husk add`, puts the **marginal cost of each
extra worktree at 6.70 MB against 405.01 MB**, a 60x saving, ahead from the second
worktree onward. Totals including the store are 5.0x at ten worktrees, because the
store holds one full copy; quote the marginal number or the total, but say which.
That 6.70 MB is a whole-volume delta, not `du`: NTFS keeps small directories
inside the MFT, so `du` over the same pair of trees reports 0.31 MB and is
wrong about it. The volume delta is the number that describes your disk.

That ratio is not a constant. It is roughly the tree's average bytes per file
divided by the per-file directory overhead a hardlink farm still pays, about 310
bytes per file on NTFS. Denser trees do better, and a tree of many tiny files does
worse. Run `husk list` in your own repo for the number that applies to you.

## Commands

```
husk add <path> [branch]     create worktree + link deps (+ reap nudge)
husk link [dir...]           link/provision deps in current worktree
   --install                 store miss? run the right installer (npm ci / pnpm / uv ...)
   --mode clone|hardlink|symlink|copy
husk unlink [dir...]         materialize a private copy, stop sharing
husk adopt                   seed store from this checkout's real dirs
husk setup [--write]         adopt + agent instructions (--write: append to AGENTS.md once)
husk status                  link states, lockfile drift, store size (this worktree)
husk list                    every worktree, its deps, and disk saved by sharing
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
| **Concurrency / write contention** | Store seeding is serialized by a portable lock with atomic rename: 100 parallel `husk link` calls produce exactly one entry, and no partial tree is ever visible. The same lock serializes `--install`, so 100 agents hitting a fresh lockfile run **one** installer while 99 wait and reuse the result. Interrupted commands clean up after themselves (held locks and half-built temp dirs are released on exit), a killed process's lock is stolen once its pid is gone (steal is rename-then-verify, so two stealers can never wipe a lock a third process just took), and `husk doctor --fix` sweeps any residue that survives a hard kill. `gc` re-verifies under the entry lock before deleting, treats the repo's actual worktrees (not just ref files) as the source of truth for liveness, and never touches an entry that was seeded or provisioned from in the last 10 minutes. Provisioning from an existing entry is lock-free. In `symlink` mode the entry root is made read-only, so direct writes fail loudly (EACCES). An accidental `npm install` can't poison siblings either: npm replaces the symlink with a fresh private dir (correct results, sharing silently lost, and `husk status` flags it as `not-a-link`). |
| **Tooling assumptions** | `clone`, `hardlink`, and `copy` produce real directories, and no tool can tell the difference. `symlink` mode has the classic realpath caveats (Node's `__dirname` resolves into the store; Docker build contexts can't follow it), which is why it's opt-in rather than the default. Python venvs are path-bound by design: symlink mode works, clone mode is flagged by `doctor`. If you use `uv` or a global-cache package manager (pnpm, Go modules), you already have most of this; husk adds the most for npm-style per-project dirs. |
| **When it breaks** | Every failure degrades toward `copy`, which is always correct. Dangling link: `husk doctor --fix` re-provisions. Lockfile drift: `status` and `doctor` flag it, `link` re-keys, `unlink` goes private. Store deleted: worktrees re-seed from any checkout with real dirs. A store configured *inside* the repo is refused outright (deleting a worktree would destroy it). husk can never make a worktree *less* correct than a plain worktree, only cheaper. |

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

Environment variables, or `.husk.conf` at the repo root:

```sh
HUSK_STORE=~/.husk/store      # store location
HUSK_MODE=auto                # auto | clone | hardlink | symlink | copy
HUSK_DIRS="node_modules"      # override auto-detection
HUSK_REAP_DAYS=7              # reap idle threshold
HUSK_DEDUPE=1                 # hardlink identical files across store entries at seed time
HUSK_NUDGE_SECS=86400         # how often 'husk add' probes for stale worktrees
HUSK_LOCK_TIMEOUT=120         # seconds to wait for an orphaned lock
HUSK_LOCK_TIMEOUT_BUSY=3600   # seconds to wait for a lock whose holder is alive (e.g. an installer)
```

`.husk.conf` is plain `KEY=VALUE` lines and is **parsed, never sourced**: agents
run husk inside freshly cloned repositories, so a config file that executed
shell would hand any repo arbitrary code execution. Unknown keys are ignored
with a warning, `HUSK_MODE` is validated against the mode list, and numeric
fields must be numeric. A leading `~/` or `$HOME/` in a value is expanded;
nothing else is.

## Platforms

- **macOS**: primary target. APFS clonefile gives the default `clone` mode.
- **Linux**: fully supported, test suite runs green on Ubuntu 24.04. btrfs and XFS
  get `clone` (reflink), ext4 and overlayfs get `hardlink`. Needs git, perl, and
  openssl or sha256sum (all present on any dev box).
- **Windows (WSL)**: the Linux path above; suite green on Ubuntu 24.04 under
  WSL2.
- **Windows (native Git Bash)**: supported, suite green. The probe lands on
  `hardlink` mode — NTFS hardlinks are real. MSYS fakes `ln -s` with a copy
  unless Developer Mode is on, so `--mode symlink` uses a **directory
  junction** instead, which is the one directory link Windows grants an
  unprivileged user; the link is verified after creation, and anything that
  isn't a real link falls back to `copy` rather than record sharing that
  isn't happening. Removing a worktree removes the junction and leaves the
  store intact (checked against `rm -rf`, `git worktree remove`, and husk's
  own force-writable delete). Hardlink farming goes through a native
  `CreateHardLinkW` walk, which avoids MSYS path translation on every one of
  a `node_modules`' 21,000 files; `HUSK_WINFARM=0` forces the portable
  `cp -al` chain. Paths that native `git.exe` emits
  (`C:/...`) are normalized before being hashed or compared, so the store
  namespace is stable across the main checkout and its worktrees.
  **On Windows, expect a big disk win and a smaller time loss.** Measured on
  NTFS against the ~400 MB, ~21,000-file `node_modules` above: each extra
  worktree costs **6.7 MB instead of 405 MB**, a 60x saving, and husk is ahead
  on disk from the second worktree onward. On time it is still behind, but by
  much less than it was: `husk add` is **55.6s against 33.8s** for
  `git worktree add` + `cp -R`, median of three runs alternated against each
  other in one session. It used to be 103s against 37s.

  Where the remaining time goes is worth knowing before you read too much into
  that ratio. A 10-file `node_modules` costs 45-51s on the same box and the
  21,000-file one costs 55.6s, so almost all of it is **fixed cost, not tree
  size** — process creation, which MSYS implements with a real Windows process
  and Defender then inspects. That runs about 1.3s per process here. Cutting
  the process count and caching what husk kept re-deriving took the fixed part
  from 149s to under 50s, which is where most of the 103s → 55.6s came from.
  The work helps on every platform; the size of the win does not transfer,
  because no other platform charges anything like that per process.

  One-time `husk adopt` is ~250s on that tree. Machine state dominates
  everything here: one `cp -R` measured minutes after a full test suite came
  in at 355s against the same command's usual 30s, purely because Defender was
  still working through what the suite had written. Exclude your store
  directory if you care about the numbers, and never trust a single timing.

husk never guesses the platform. Every mode is probed against the actual
filesystems in play, and anything that fails a probe falls off the ladder.

## What husk is not

- **Not a package manager.** It shares and clones what your installer produced; it
  never resolves a dependency.
- **Not a daemon.** Every guarantee holds via on-invocation checks and atomic
  filesystem operations.
- **Not a git proxy.** Considered and rejected: PATH shims over `git` are fragile
  and surprising. One extra verb (`husk add`) buys the same ergonomics safely.

## License

[Apache 2.0](LICENSE).

## Development

Everything lives in two files: `bin/husk` (the whole tool, one bash script) and
`test/run.sh` (the whole test suite, plain assertions, no framework).

```sh
./test/run.sh                       # 105 tests, ~60s, runs in a throwaway tmpdir
HUSK_STRESS=1 ./test/run.sh         # + hostile-name / deep-nesting / big-tree stress section
shellcheck --severity=warning bin/husk install.sh test/run.sh   # must stay clean
```

Before claiming Linux works, run the suite as a **non-root** user on a real
distro. Root bypasses permission checks and hides an entire class of bugs:

```sh
docker run --rm -v "$PWD":/husk ubuntu:24.04 bash -c '
  apt-get update -qq && apt-get install -y -qq git perl openssl >/dev/null
  useradd -m u && cp -r /husk /home/u/husk && chown -R u:u /home/u/husk
  su - u -c "cd ~/husk && ./test/run.sh"'
```

Ground rules for changes:

- **bash 3.2 compatible.** Stock macOS ships bash 3.2; no associative arrays,
  no `mapfile`, no `${var,,}`.
- **Zero dependencies** beyond git, perl, and openssl or sha256sum. Nothing
  gets installed; every capability is probed at runtime and falls back.
- **Never guess the platform.** Filesystem features (CoW clone, hardlinks,
  real symlinks) are probed against the actual paths in play, not inferred
  from `uname`.
- **stdout is an API.** Machine-readable `key=value` lines only; prose and
  warnings go to stderr. Agents parse stdout, so its format is stable.
- **Every command is idempotent** and safe to interrupt. If you add a step
  that holds a lock or builds a temp dir, register it for cleanup and give
  `doctor --fix` a way to sweep the residue after a hard kill.
- **A test per bug.** Anything that broke once gets a regression test in
  `test/run.sh` so it can't break silently again.
