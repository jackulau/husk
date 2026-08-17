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

## Compressing the store

A store entry is written once and only read afterwards, which is the one shape
transparent filesystem compression is unambiguously safe for. `husk compress`
hands the store to whatever compressor the filesystem already accepts: NTFS
`compact /exe:LZX` on Windows, `chattr +c` on btrfs, `afsctool` on APFS if you
have it installed. Nothing is bundled and nothing is inferred from `uname`. husk
compresses a probe file inside the real store and keeps the answer only if the
blocks actually drop *and* the bytes come back byte-identical; anything else is
reported as `compress=none` and the store is left alone.

The saving compounds with sharing instead of competing with it. A hardlink farm
points at the same file records as the store, so compressing one entry
compresses every worktree provisioned from it, at no per-worktree cost.

That is the part moving to a compressing filesystem does not do for you.
Compression alone shrinks each copy but leaves N of them: ten worktrees become
ten compressed copies. husk collapses the N to one first, and compressing that
one is what multiplies. If you already run a compressing volume you get the
second half for free, and `husk compress` will have little left to find. On
NTFS, where nothing is compressed by default, it is the whole difference.

Every sharing mode inherits it: `hardlink` shares the file record, `clone`
reflinks the compressed extents, and `symlink` reads the store directly.
`copy` mode is the honest exception. A plain copy reads the logical bytes and
writes them back out uncompressed, so a copy-mode worktree pays full price no
matter what the store costs.

```sh
husk compress            # compress this repo's published entries, idempotent
husk compress --probe    # just say which compressor works here
husk compress --dry-run  # count what would be compressed, touch nothing
```

Compression is off the `husk add` path by default, because an add that stops to
compress 450 MB is an add that got slower. `HUSK_COMPRESS=1` opts into
compressing a new entry while it is still staged, before it is published, which
costs the first add and nothing afterwards. `HUSK_COMPRESS=0` disables the
feature and the probe entirely. An entry that is mid-write is reported as
`locked=N` and left alone, never compressed underneath its writer, and that
count is kept separate from `skipped=N`, which means an entry that had nothing
left to gain.

Ratios come from your tree, not from husk. Dependency trees are repetitive text
and compress hard; a tree of images or prebuilt binaries will barely move. Run
`husk compress` and read the ratio it prints for the number that applies to you.

## Benchmarks

Two platforms, two real repos, two different default modes. Disk is always the
whole-volume delta (`df`), never apparent size, because a hardlink farm's
apparent size is exactly the thing that lies.

**macOS, APFS, `clone` mode.** 10 worktrees of a 395 MB `node_modules`, 14,700
files, warm npm cache, Apple Silicon:

| approach | wall time | disk consumed |
|---|---|---|
| `git worktree add` + `npm ci` per worktree | 27.1s | 4,013 MB |
| `husk add` (clone mode, default) | **20.1s** | **61 MB** |
| `husk add` (hardlink mode) | 51.6s | 39 MB |
| `husk add` (symlink mode) | 4.3s | 2.5 MB |
| `husk add` (copy mode) | 45.7s | 3,954 MB |
| 10 **concurrent** `husk add` (agent-thread race) | 26.3s | 63 MB |

**Windows, NTFS, `hardlink` mode.** 5 worktrees of a real 21,000-file, 449 MB
`node_modules`, run by `test/bench-fleet.sh`:

| approach | 5 worktrees | each extra worktree | store on disk |
|---|---|---|---|
| `git worktree add` + `cp -R` | 2300.5 MB | 460.1 MB | n/a |
| `husk add` | 476.5 MB | 5.0 MB | 451.0 MB |
| `husk add` + `husk compress` | **86.6 MB** | 5.0 MB | **83.2 MB** |

That is 92x on the marginal worktree and 26.6x on the fleet total. The two
savings are independent: sharing removes the copies, compression shrinks the one
copy that is left, and the store number is what moves between the last two rows.

On time, the same Windows tree gives `husk add` at a 15.9s median against 19.7s
for `git worktree add` + `cp -R`, alternated over five rounds. Windows used to
be husk's slow platform and is not any more; the paragraph under Platforms
explains what changed and why the number is quoted with its spread.

Reading these honestly:

- **Quote the marginal number or the total, but say which.** husk is behind on
  disk at one worktree, because the store holds a full copy, and ahead from the
  second onward. The fleet ratio grows with the fleet.
- **The ratio is not a constant.** For sharing it is roughly the tree's average
  bytes per file over the ~310 bytes per file of directory overhead a hardlink
  farm still pays on NTFS, so denser trees do better and many-tiny-file trees do
  worse. For compression it is whatever your tree compresses to. Run `husk list`
  and `husk compress` for the numbers that apply to you.
- **Store size is measured with `du`, fleet totals with `df`.** `du` counts
  blocks on the entry and cannot be perturbed by anything else on the volume,
  which makes it the right instrument for the store. It is the wrong one for a
  hardlink farm: NTFS keeps small directories in the MFT, and `du` over a pair
  of worktrees reports 0.31 MB where the volume says 6.7 MB.
- **`npm ci` at 2.7s per worktree is a best case** (warm cache, fast SSD). Cold
  caches or a private registry make that baseline minutes; husk's numbers do not
  move.
- Clone mode beats a warm `npm ci` because provisioning fans out per top-level
  package across cores, capped at 8 jobs. Hardlink mode is the slow row on APFS
  because it is bounded by `link(2)`; on ext4, where it is the default, links
  are far cheaper.
- The concurrent run produced 10/10 working worktrees from one store entry with
  no partial trees. Wall time there is bounded by git's own worktree lock, not
  by husk.

Reproduce with `test/run.sh`, `test/bench-fleet.sh --baseline` and
`test/bench-fleet.sh --after`.

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
   --days N                  override the idle threshold for this run
husk gc [--dry-run]          drop store entries no worktree references
husk dedupe                  hardlink identical files across store entries
husk compress                compress this repo's store entries in place (worktrees inherit it)
   --probe                   report which compressor this filesystem accepts
   --dry-run                 count what would be compressed, touch nothing
husk version                 print the husk version
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
husk compress                # shrink what survived; every worktree shrinks with it
```

`husk setup --write` drops the equivalent of this into your `AGENTS.md` automatically:

> To create a worktree, use `husk add <path> <branch>` instead of `git worktree add`.
> If a husk command exits 2, run `husk link --install`. Never delete `~/.husk/store`.

Why agents like it: every command is **idempotent** (retry freely), **self-healing**
(dangling links are detected and repaired on the spot), and **parseable**. There is
no daemon and no proxy. husk never intercepts git, so nothing else in the toolchain
changes behavior.

## Tradeoffs, honestly

**Correctness and isolation.** Store entries are keyed by lockfile hash, so a
branch with a different lockfile can never silently get the wrong deps. Default
`clone` mode gives fully private writes. A worktree whose lockfile changed is
*refused* sharing until deps are reinstalled (`--install`) or explicitly trusted
(`adopt`).

**Concurrency.** This is the case husk is built for, so it is worth being
specific:

- Store seeding is serialized by a portable lock with atomic rename. 100
  parallel `husk link` calls produce exactly one entry, and no partial tree is
  ever visible.
- The same lock serializes `--install`, so 100 agents hitting a fresh lockfile
  run **one** installer while 99 wait and reuse the result.
- Provisioning from an entry that already exists takes no lock at all.
- Interrupted commands clean up after themselves: held locks and half-built temp
  dirs are released on exit. A killed process's lock is stolen once its pid is
  gone, and the steal is rename-then-verify, so two stealers can never wipe a
  lock a third process just legitimately took. `husk doctor --fix` sweeps
  whatever survives a hard kill.
- `gc` re-verifies under the entry lock before deleting, treats the repo's
  actual worktrees rather than ref files as the source of truth for liveness,
  and never touches an entry seeded or provisioned from in the last 10 minutes.
- In `symlink` mode the entry root is read-only, so a direct write fails loudly
  with EACCES. An accidental `npm install` cannot poison siblings either: npm
  replaces the symlink with a fresh private dir, which is correct but silently
  unshared, and `husk status` flags it as `not-a-link`.

**Tooling assumptions.** `clone`, `hardlink`, and `copy` produce real
directories, and no tool can tell the difference. `symlink` mode has the classic
realpath caveats (Node's `__dirname` resolves into the store, Docker build
contexts cannot follow it), which is why it is opt-in rather than the default.
Python venvs are path-bound by design: symlink mode works, clone mode is flagged
by `doctor`. If you already use `uv` or a global-cache package manager (pnpm, Go
modules), you have most of this; husk adds the most for npm-style per-project
dirs.

**When it breaks.** Every failure degrades toward `copy`, which is always
correct. Dangling link: `husk doctor --fix` re-provisions. Lockfile drift:
`status` and `doctor` flag it, `link` re-keys, `unlink` goes private. Store
deleted: worktrees re-seed from any checkout with real dirs. A store configured
*inside* the repo is refused outright, because deleting a worktree would destroy
it. husk can never make a worktree *less* correct than a plain worktree, only
cheaper.

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
HUSK_COMPRESS=auto            # auto (compress only when asked) | 1 (compress new entries) | 0 (off)
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

Three more knobs are environment-only, because they switch off a fast path for
debugging rather than describe a repo: `HUSK_WINFARM=0` forces the portable
`cp -al` chain instead of the native Windows hardlink farm, `HUSK_JUNCTION=0`
refuses directory junctions for `symlink` mode on Windows, and `HUSK_PREFARM=0`
stops `husk add` from farming the store while git is still checking out. All
three only change how the same result is reached.

## Platforms

- **macOS**: primary target. APFS clonefile gives the default `clone` mode.
- **Linux**: fully supported, test suite runs green on Ubuntu 24.04. btrfs and XFS
  get `clone` (reflink), ext4 and overlayfs get `hardlink`. Needs git, perl, and
  openssl or sha256sum (all present on any dev box).
- **Windows (WSL)**: the Linux path above; suite green on Ubuntu 24.04 under
  WSL2.
- **Windows (native Git Bash)**: supported, suite green. The probe lands on
  `hardlink` mode, because NTFS hardlinks are real. MSYS fakes `ln -s` with a
  copy unless Developer Mode is on, so `--mode symlink` uses a **directory
  junction** instead, which is the one directory link Windows grants an
  unprivileged user; the link is verified after creation, and anything that
  isn't a real link falls back to `copy` rather than record sharing that
  isn't happening. Removing a worktree removes the junction and leaves the
  store intact (checked against `rm -rf`, `git worktree remove`, and husk's
  own force-writable delete). Hardlink farming goes through a native
  `CreateHardLinkW` walk, which avoids MSYS path translation on every one of
  a `node_modules`' tens of thousands of files; `HUSK_WINFARM=0` forces the
  portable `cp -al` chain. Paths that native `git.exe` emits
  (`C:/...`) are normalized before being hashed or compared, so the store
  namespace is stable across the main checkout and its worktrees.
  **On Windows, expect a big disk win and, as of this round, a time win too.**
  The disk side is the NTFS table under Benchmarks, and husk is ahead there
  from the second worktree onward. On time, `husk add` now runs at **15.9s
  against 19.7s** for `git worktree add` + `cp -R` on the same 21,000-file,
  449 MB tree: medians of five rounds alternated against each other in one
  session, husk ahead in four of the five. It used to be 103s against 37s.

  Read that as a direction, not a point. The individual rounds were 13.4-23.2s
  for husk and 19.3-21.6s for plain, and the reason for the difference in
  spread is the reason husk wins at all. `cp -R` writes 449 MB every time, which
  is steady, predictable work. husk writes metadata into a store the page cache
  is already holding, so it is bound by **process creation** instead, and every
  process on this platform is a real Windows process that Defender inspects.
  That makes husk the noisier of the two and the faster one, and the gap widens
  as a fleet grows, because plain repeats all 449 MB per worktree while husk
  never does.

  It also means the honest unit for optimizing husk on Windows is **processes
  spawned per add, not seconds**. The process count is deterministic; the clock
  on this box swings 40% between identical runs. `husk add` currently spawns 24
  external processes on a 21,000-file tree, counted from a `bash -x` trace,
  down from 29 before this round; the whole hardlink walk is one of the 24. The
  count is what gets optimized and the clock is what confirms it, in that
  order. The work helps on every platform, but the size of the win does not
  transfer, because no other platform charges anything like this per process.

  One-time `husk adopt` is ~93s on that tree. Machine state dominates
  everything here: one `cp -R` measured minutes after a full test suite came
  in at 355s against the same command's usual 30s, purely because Defender was
  still working through what the suite had written. Exclude your store
  directory if you care about the numbers, and never trust a single timing.

husk never guesses the platform. Every mode is probed against the actual
filesystems in play, and anything that fails a probe falls off the ladder.

Store compression follows the same rule. NTFS gets `compact /exe:LZX`, btrfs
gets `chattr +c`, APFS gets `afsctool` if you have installed it, and every other
filesystem reports `compress=none` and is left untouched. ZFS compresses at the
dataset level, which husk did not do and therefore does not claim. The probe
runs against the real store path and is only believed if the blocks drop and the
bytes come back identical.

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
./test/run.sh                       # 135 tests, ~60s, runs in a throwaway tmpdir
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
