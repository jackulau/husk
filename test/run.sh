#!/usr/bin/env bash
# husk test suite - no framework, plain assertions.
set -uo pipefail

HUSK="$(cd "$(dirname "$0")/.." && pwd)/bin/husk"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/husk-test.XXXXXX")"
export HUSK_STORE="$TMP/store"
export HUSK_REAP_DAYS=7
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
assert() { # desc cmd...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}
assert_not() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc"; else ok "$desc"; fi
}
cleanup() { chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

# ---------- capability probes ----------
# MSYS/Git Bash fakes 'ln -s' with a copy unless symlink privilege is enabled,
# so symlink-shaped assertions are meaningless there. Directory write guards
# (chmod a-w) are ignored by root and by NTFS, so that gets its own probe.
HAVE_SYMLINK=0
ln -s "$TMP" "$TMP/.slprobe" 2>/dev/null && [ -L "$TMP/.slprobe" ] && HAVE_SYMLINK=1
rm -rf "$TMP/.slprobe"
# ...but Windows still links DIRECTORIES unprivileged, via a junction, which is
# what husk's symlink mode uses there. Everything that only needs "the worktree
# points at the store" tests HAVE_DIRLINK; only the tests that genuinely need
# `ln -s` itself (store aliases) stay on HAVE_SYMLINK.
HAVE_DIRLINK=$HAVE_SYMLINK
if [ "$HAVE_DIRLINK" = 0 ] && command -v cygpath >/dev/null 2>&1 && command -v cmd >/dev/null 2>&1; then
  mkdir -p "$TMP/.jtgt"
  cmd //c mklink //J "$(cygpath -w "$TMP/.jprobe")" "$(cygpath -w "$TMP/.jtgt")" >/dev/null 2>&1
  [ -L "$TMP/.jprobe" ] && [ -d "$TMP/.jprobe" ] && HAVE_DIRLINK=1
  rm -rf "$TMP/.jprobe" "$TMP/.jtgt"
fi
# replace a live link with one pointing nowhere, whichever kind this box makes
break_link() { # path -> 0 if $1 is now a dangling directory link
  rm -rf "$1"
  if ln -s "$TMP/nowhere" "$1" 2>/dev/null && [ -L "$1" ]; then return 0; fi
  rm -rf "$1"
  mkdir -p "$TMP/.gone" || return 1
  cmd //c mklink //J "$(cygpath -w "$1")" "$(cygpath -w "$TMP/.gone")" >/dev/null 2>&1 || return 1
  rmdir "$TMP/.gone" 2>/dev/null
  [ -L "$1" ]
}
CAN_DIRGUARD=0
mkdir "$TMP/.gdprobe" && chmod a-w "$TMP/.gdprobe" 2>/dev/null
touch "$TMP/.gdprobe/x" 2>/dev/null || CAN_DIRGUARD=1
chmod u+w "$TMP/.gdprobe" 2>/dev/null; rm -rf "$TMP/.gdprobe"

# ---------- fixture: a fake node repo ----------
make_repo() { # path lock-content
  local r="$1" lock="$2"
  mkdir -p "$r"; cd "$r" || exit 1
  git init -q -b main
  echo node_modules > .gitignore   # real repos never commit deps; worktrees must be PROVISIONED
  echo '{"name":"fx"}' > package.json
  printf '%s\n' "$lock" > package-lock.json
  mkdir -p node_modules/left-pad
  echo "module.exports=1 // $lock" > node_modules/left-pad/index.js
  dd if=/dev/zero of=node_modules/blob.bin bs=1024 count=64 2>/dev/null
  local old; old=$(date -v-9d '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d '9 days ago' '+%Y-%m-%dT%H:%M:%S')
  git add -A; GIT_AUTHOR_DATE="$old" GIT_COMMITTER_DATE="$old" git commit -qm init
}

# ================= 1. link seeds store, keys by lockfile =================
make_repo "$TMP/repo" "lock-v1"
cd "$TMP/repo" || exit 1
outp=$("$HUSK" link 2>/dev/null)
assert "link exits 0 on fresh repo" test $? -eq 0
key=$(printf '%s' "$outp" | sed -n 's/.*key=\([a-f0-9]*\).*/\1/p' | head -1)
assert "link emitted a key" test -n "$key"
entries=$(find "$HUSK_STORE" -type d -name "$key" | wc -l | tr -d ' ')
assert "store entry created for key" test "$entries" -eq 1
assert "store entry holds the dep files" test -f "$(find "$HUSK_STORE" -type d -name "$key")/left-pad/index.js"
assert "link is idempotent" bash -c "'$HUSK' link | grep -q linked"

# ================= 2. worktree via husk add gets deps =================
"$HUSK" add "$TMP/wt1" feature-a >/dev/null 2>&1
assert "husk add created worktree" test -d "$TMP/wt1"
assert "worktree has node_modules" test -e "$TMP/wt1/node_modules/left-pad/index.js"
assert "worktree .husk excluded from git status" bash -c "cd '$TMP/wt1' && [ -z \"\$(git status --porcelain)\" ]"

# ================= 3. CoW / storage sharing (APFS or reflink FS) =================
if cp -c "$TMP/repo/package.json" "$TMP/.cowprobe" 2>/dev/null || cp --reflink=always "$TMP/repo/package.json" "$TMP/.cowprobe" 2>/dev/null; then
  rm -f "$TMP/.cowprobe"
  mode=$(cd "$TMP/wt1" && "$HUSK" status | sed -n 's/.*mode=\([a-z]*\).*/\1/p' | head -1)
  assert "CoW filesystem picked clone mode" test "$mode" = "clone"
  assert "clone is isolated: write in wt1 invisible in repo" bash -c "
    echo poison >> '$TMP/wt1/node_modules/left-pad/index.js' &&
    ! grep -q poison '$TMP/repo/node_modules/left-pad/index.js'"
else
  ok "skip: no CoW filesystem here (clone tests elsewhere)"
  ok "skip: no CoW filesystem here (clone tests elsewhere)"
fi

# ================= 4. lockfile divergence -> different store entry =================
cd "$TMP/wt1" || exit 1
printf 'lock-v2\n' > package-lock.json
"$HUSK" link --mode copy >/dev/null 2>&1; rc=$?
# store miss expected (no donor with lock-v2): exit 2
assert "changed lockfile is a store miss (exit 2)" test "$rc" -eq 2
# simulate agent install for lock-v2, assert trust via adopt, then link
mkdir -p node_modules/left-pad
echo "module.exports=2 // lock-v2" > node_modules/left-pad/index.js
"$HUSK" adopt >/dev/null 2>&1
"$HUSK" link >/dev/null 2>&1
key2=$(cd "$TMP/wt1" && "$HUSK" status | sed -n 's/.*key=\([a-f0-9]*\).*/\1/p' | head -1)
assert "divergent lockfile got its own key" test -n "$key2" -a "$key2" != "$key"
assert "both store entries coexist" test "$(find "$HUSK_STORE" -mindepth 3 -maxdepth 3 -type d ! -name '*.tmp.*' ! -name '*.lock' | wc -l | tr -d ' ')" -ge 2

# ================= 5. symlink mode + write guard =================
make_repo "$TMP/repo2" "slock-v1"
cd "$TMP/repo2" || exit 1
if [ "$HAVE_DIRLINK" = 1 ]; then
  slout=$("$HUSK" link --mode symlink 2>/dev/null)
  slentry=$(printf '%s' "$slout" | sed -n 's/.*entry=\([^ ]*\).*/\1/p' | head -1)
  assert "symlink mode: node_modules is a link" test -L "$TMP/repo2/node_modules"
  # -ef, not a readlink string match: MSYS resolves a junction through its own
  # mount table, so the same directory reads back under a different spelling
  assert "symlink resolves to the store entry" test "$TMP/repo2/node_modules" -ef "$slentry"
  if [ "$CAN_DIRGUARD" = 1 ]; then
    assert "write guard: creating file at entry root fails" bash -c "! touch '$TMP/repo2/node_modules/newpkg' 2>/dev/null"
  else
    ok "skip: dir write guard not enforceable here (root, or FS ignores dir a-w)"
  fi
else
  # fake-symlink platform: forced symlink mode must refuse the fake and
  # fall back to a REAL directory, recording the mode it actually used
  assert "forced symlink degrades to copy where no directory link exists" \
    bash -c "cd '$TMP/repo2' && '$HUSK' link --mode symlink 2>/dev/null | grep -q 'mode=copy'"
  ok "skip: no directory links here (neither symlink nor junction)"
  ok "skip: no directory links here (neither symlink nor junction)"
fi

# ================= 6. doctor detects + fixes dangling links =================
if [ "$HAVE_DIRLINK" = 1 ]; then
  entry2=$(readlink "$TMP/repo2/node_modules")
  mv "$entry2" "$entry2.hidden"
  assert "doctor detects dangling link" bash -c "cd '$TMP/repo2' && '$HUSK' doctor | grep -q dangling"
  mv "$entry2.hidden" "$entry2"
  break_link "$TMP/repo2/node_modules"
  cd "$TMP/repo2" || exit 1; "$HUSK" doctor --fix >/dev/null 2>&1 || true
  assert "doctor --fix repaired the link" test -e "$TMP/repo2/node_modules/left-pad/index.js"
  assert "doctor --fix preserved symlink mode" test -L "$TMP/repo2/node_modules"
else
  ok "skip: no directory links here (dangling-link tests need them)"
  ok "skip: no directory links here (dangling-link tests need them)"
  ok "skip: no directory links here (dangling-link tests need them)"
fi

# ================= 7. unlink materializes a private copy =================
cd "$TMP/repo2" || exit 1
"$HUSK" unlink node_modules >/dev/null 2>&1
assert "unlink: no longer a symlink" bash -c "[ ! -L '$TMP/repo2/node_modules' ]"
assert "unlink: files present and private" test -f "$TMP/repo2/node_modules/left-pad/index.js"
assert "unlink: writable again" bash -c "touch '$TMP/repo2/node_modules/probe' && rm '$TMP/repo2/node_modules/probe'"
assert "unlink: store metadata not leaked into worktree" bash -c "[ ! -e '$TMP/repo2/node_modules/.husk-manifest' ] && [ ! -e '$TMP/repo2/node_modules/.husk-seeded' ]"
# poison regression: edit a file post-unlink, bump lockfile, adopt; the new entry
# must carry the NEW content (a stale inherited manifest once fooled dedupe here)
echo "poisoned? no // edited-after-unlink" > "$TMP/repo2/node_modules/left-pad/index.js"
printf '%s\n' "lock-v3-postunlink" > "$TMP/repo2/package-lock.json"
k3=$(cd "$TMP/repo2" && "$HUSK" adopt 2>/dev/null | sed -n 's/.*key=\([a-f0-9]*\).*/\1/p' | head -1)
assert "reseed after unlink+edit stores the edited content" bash -c "grep -q 'edited-after-unlink' \"\$(find '$HUSK_STORE' -type d -name '$k3')/left-pad/index.js\""

# ================= 8. concurrent link race (one seeds, all succeed) =================
make_repo "$TMP/repo3" "rlock-v1"
cd "$TMP/repo3" || exit 1
pids=""
for i in 1 2 3 4 5; do
  ( "$HUSK" link >/dev/null 2>&1 ) & pids="$pids $!"
done
rc_all=0
for p in $pids; do wait "$p" || rc_all=1; done
assert "5 concurrent links all succeeded" test "$rc_all" -eq 0
k3=$(cd "$TMP/repo3" && "$HUSK" status | sed -n 's/.*key=\([a-f0-9]*\).*/\1/p' | head -1)
n3=$(find "$HUSK_STORE" -type d -name "$k3" | wc -l | tr -d ' ')
assert "race produced exactly one store entry" test "$n3" -eq 1
assert "no leftover locks/tmp after race" bash -c "! find '$HUSK_STORE' \( -name '*.lock' -o -name '*.tmp.*' \) | grep -q ."

# ================= 9. reap: only clean+merged+idle worktrees =================
cd "$TMP/repo" || exit 1
OLD=$(date -v-9d '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d '9 days ago' '+%Y-%m-%dT%H:%M:%S')
STAMP=$(date -v-8d +%Y%m%d%H%M 2>/dev/null || date -d '8 days ago' +%Y%m%d%H%M)
git worktree add -q "$TMP/wt-merged" -b merged-branch
( cd "$TMP/wt-merged" && echo x > f && git add f \
  && GIT_AUTHOR_DATE="$OLD" GIT_COMMITTER_DATE="$OLD" git commit -qm work )
# merge commit backdated too: wt-dirty branches from it, and must reach the DIRTY
# guard (not be spared earlier by the age gate) for the guard to have test teeth
GIT_AUTHOR_DATE="$OLD" GIT_COMMITTER_DATE="$OLD" git merge -q --no-ff merged-branch -m "merge" 2>/dev/null \
  || GIT_AUTHOR_DATE="$OLD" GIT_COMMITTER_DATE="$OLD" git merge -q merged-branch
git worktree add -q "$TMP/wt-dirty" -b dirty-branch
echo dirty > "$TMP/wt-dirty/uncommitted.txt"
git worktree add -q "$TMP/wt-unmerged" -b unmerged-branch
( cd "$TMP/wt-unmerged" && echo y > g && git add g \
  && GIT_AUTHOR_DATE="$OLD" GIT_COMMITTER_DATE="$OLD" git commit -qm unmerged-work )
# age the activity signal (per-worktree gitdir HEAD file) 8 days back
for w in "$TMP/wt-merged" "$TMP/wt-dirty" "$TMP/wt-unmerged"; do
  touch -t "$STAMP" "$(git -C "$w" rev-parse --git-dir)/HEAD"
done
dry=$("$HUSK" reap --dry-run 2>/dev/null)
assert "reap targets merged+idle worktree" bash -c "printf '%s' '$dry' | grep -q wt-merged"
assert_not "reap spares dirty worktree" bash -c "printf '%s' '$dry' | grep -q wt-dirty"
assert_not "reap spares unmerged worktree" bash -c "printf '%s' '$dry' | grep -q wt-unmerged"
"$HUSK" reap >/dev/null 2>&1
assert "reap removed merged worktree" bash -c "[ ! -d '$TMP/wt-merged' ]"
assert "reap kept dirty worktree" test -d "$TMP/wt-dirty"
assert "reap kept unmerged worktree" test -d "$TMP/wt-unmerged"

# ================= 10. gc drops unreferenced entries, keeps referenced =================
cd "$TMP/repo" || exit 1
# fabricate an orphan entry referenced only by a worktree that no longer exists
# (in THIS repo's store namespace - derive it from wt1's live key)
live_key=$(cd "$TMP/wt1" && "$HUSK" status | sed -n 's/.*key=\([a-f0-9]*\).*/\1/p' | head -1)
repo_store=$(dirname "$(find "$HUSK_STORE" -type d -name "$live_key" -print -quit)")
mkdir -p "$repo_store/deadbeefdeadbeef"
echo orphan > "$repo_store/deadbeefdeadbeef/file"
printf '%s\n' "$TMP/gone-worktree" > "$repo_store/deadbeefdeadbeef.refs"
# make the live entry's ref-check load-bearing: age it past the seed grace period
echo 0 > "$repo_store/$live_key/.husk-seeded" 2>/dev/null
# freshly seeded orphan must survive gc (ref may not be written yet)
mkdir -p "$repo_store/feedfacefeedface"
date +%s > "$repo_store/feedfacefeedface/.husk-seeded"
assert "gc --dry-run lists the orphan entry" bash -c "'$HUSK' gc --dry-run | grep -q deadbeefdeadbeef"
assert_not "gc --dry-run spares the freshly seeded entry" bash -c "'$HUSK' gc --dry-run | grep -q feedfacefeedface"
"$HUSK" gc >/dev/null 2>&1
assert "gc removed the orphan entry" bash -c "[ ! -d '$repo_store/deadbeefdeadbeef' ]"
assert "gc kept the entry a live worktree references" test -d "$repo_store/$live_key"
assert "gc kept the freshly seeded entry (grace period)" test -d "$repo_store/feedfacefeedface"
rm -rf "$repo_store/feedfacefeedface"

# ================= 11. install.sh =================
BIN_DIR="$TMP/bindir"
( cd "$(dirname "$HUSK")/.." && HUSK_BIN_DIR="$BIN_DIR" bash install.sh >/dev/null 2>&1 )
assert "install.sh installed an executable" test -x "$BIN_DIR/husk"
assert "installed husk self-reports version" bash -c "'$BIN_DIR/husk' version | grep -q husk"

# ================= 12. setup --write (agent adoption) =================
cd "$TMP/repo" || exit 1
"$HUSK" setup --write >/dev/null 2>&1
assert "setup --write created AGENTS.md with snippet" bash -c "grep -q 'husk:agent-instructions' '$TMP/repo/AGENTS.md'"
"$HUSK" setup --write >/dev/null 2>&1
assert "setup --write is idempotent (one snippet)" bash -c "[ \"\$(grep -c 'husk add' '$TMP/repo/AGENTS.md')\" -eq 1 ]"
assert "setup without --write prints snippet" bash -c "'$HUSK' setup | grep -q 'husk add'"

# ================= 13. store dedupe across entries =================
make_repo "$TMP/dd" "dd-lock-v1"
cd "$TMP/dd" || exit 1
"$HUSK" link >/dev/null 2>&1
k1=$(cd "$TMP/dd" && "$HUSK" status | sed -n 's/.*key=\([a-f0-9]*\).*/\1/p' | head -1)
# bump the lockfile; blob.bin unchanged, left-pad content differs (embeds lock string)
printf '%s\n' "dd-lock-v2" > package-lock.json
echo "module.exports=2 // dd-lock-v2" > node_modules/left-pad/index.js
k2=$("$HUSK" adopt 2>/dev/null | sed -n 's/.*key=\([a-f0-9]*\).*/\1/p' | head -1)
dd_store=$(dirname "$(find "$HUSK_STORE" -type d -name "$k1" -print -quit)")
assert "second lockfile made a second entry" test -d "$dd_store/$k2"
# -c first: BSD stat fails it cleanly, while GNU 'stat -f %i' pollutes stdout before failing
inode_of() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1" 2>/dev/null; }
same_inode() { i1=$(inode_of "$1"); i2=$(inode_of "$2"); [ -n "$i1" ] && [ "$i1" = "$i2" ]; }
assert "identical file hardlinked across entries" same_inode "$dd_store/$k1/blob.bin" "$dd_store/$k2/blob.bin"
assert_not "differing file NOT hardlinked" same_inode "$dd_store/$k1/left-pad/index.js" "$dd_store/$k2/left-pad/index.js"
assert "new entry content is the new version" grep -q "dd-lock-v2" "$dd_store/$k2/left-pad/index.js"
assert "old entry content untouched" grep -q "dd-lock-v1" "$dd_store/$k1/left-pad/index.js"
# manual pass over pre-existing entries: undo one link, re-dedupe
chmod u+w "$dd_store/$k2" 2>/dev/null; rm -f "$dd_store/$k2/blob.bin"
dd if=/dev/zero of="$dd_store/$k2/blob.bin" bs=1024 count=64 2>/dev/null
assert_not "fresh copy is a distinct inode" same_inode "$dd_store/$k1/blob.bin" "$dd_store/$k2/blob.bin"
(cd "$TMP/dd" && "$HUSK" dedupe >/dev/null 2>&1)
assert "husk dedupe re-links identical files" same_inode "$dd_store/$k1/blob.bin" "$dd_store/$k2/blob.bin"

# ================= 13b. unlink breaks hardlink-farm sharing =================
# hardlink mode leaves worktree files sharing inodes with the store entry;
# unlink's contract is "stop sharing", so it must rebuild with private inodes
# or a post-unlink in-place edit would poison every sibling worktree
make_repo "$TMP/hl" "hl-lock-v1"
cd "$TMP/hl" || exit 1
"$HUSK" link --mode hardlink >/dev/null 2>&1
"$HUSK" add "$TMP/hl-wt" hl-b --mode hardlink >/dev/null 2>&1
hl_key=$(cd "$TMP/hl-wt" && "$HUSK" status | sed -n 's/.*key=\([a-f0-9]*\).*/\1/p' | head -1)
hl_entry=$(find "$HUSK_STORE" -type d -name "$hl_key" -print -quit)
assert "hardlink worktree shares inodes with store" same_inode "$hl_entry/left-pad/index.js" "$TMP/hl-wt/node_modules/left-pad/index.js"
(cd "$TMP/hl-wt" && "$HUSK" unlink node_modules >/dev/null 2>&1)
assert_not "unlink broke the inode sharing" same_inode "$hl_entry/left-pad/index.js" "$TMP/hl-wt/node_modules/left-pad/index.js"
echo "private edit" >> "$TMP/hl-wt/node_modules/left-pad/index.js"
assert "post-unlink edit does not poison the store" bash -c "! grep -q 'private edit' '$hl_entry/left-pad/index.js'"

# ================= 14. hardening: stampede, residue sweep, store guard =================
# installer stampede: 3 concurrent 'link --install' on the same store miss must run ONE installer
mkdir -p "$TMP/shim"
cat > "$TMP/shim/npm" <<'SHIM'
#!/bin/sh
# fake npm: log the invocation, produce a node_modules
echo "ci" >> "$NPM_LOG"
sleep 1
mkdir -p node_modules/left-pad
echo "module.exports=9 // stampede" > node_modules/left-pad/index.js
SHIM
chmod +x "$TMP/shim/npm"
export NPM_LOG="$TMP/npm-calls.log"
# one repo, three worktrees: same repo-id, same key, same store entry to race on
mkdir -p "$TMP/st"; ( cd "$TMP/st" \
  && git init -q -b main \
  && echo '{"name":"st"}' > package.json \
  && printf 'stampede-lock\n' > package-lock.json \
  && git add -A && git commit -qm init \
  && git worktree add -q ../st-w1 -b w1 \
  && git worktree add -q ../st-w2 -b w2 \
  && git worktree add -q ../st-w3 -b w3 )
rc_st=0
for i in 1 2 3; do
  ( cd "$TMP/st-w$i" && PATH="$TMP/shim:$PATH" "$HUSK" link --install >/dev/null 2>&1 ) &
done
for j in $(jobs -p); do wait "$j" || rc_st=1; done
assert "3 concurrent link --install all exited 0" test "$rc_st" -eq 0
assert "stampede ran exactly one installer" test "$(wc -l < "$NPM_LOG" | tr -d ' ')" -eq 1
assert "all 3 stampede worktrees got deps" bash -c "test -f '$TMP/st-w1/node_modules/left-pad/index.js' -a -f '$TMP/st-w2/node_modules/left-pad/index.js' -a -f '$TMP/st-w3/node_modules/left-pad/index.js'"
st_base=$(cd "$TMP/st-w1" && "$HUSK" status 2>/dev/null | sed -n 's/^store=//p' | head -1)
assert "stampede produced exactly one store entry" bash -c "[ \"\$(find '$st_base/node_modules' -mindepth 1 -maxdepth 1 -type d ! -name '*.lock' ! -name '*.tmp.*' | wc -l | tr -d ' ')\" -eq 1 ]"
assert "no leftover locks/tmp after stampede" bash -c "! find '$st_base' \( -name '*.lock' -o -name '*.tmp.*' \) 2>/dev/null | grep -q ."

# doctor sweeps orphaned tmp residue (dead pid) but spares a live one
res_store=$(dirname "$(find "$HUSK_STORE" -type d -name "$key" -print -quit)")
mkdir -p "$res_store/deadentry.tmp.99999999"
mkdir -p "$TMP/repo/node_modules.husk-tmp.99999999"
mkdir -p "$res_store/liveentry.tmp.$$"
cd "$TMP/repo" || exit 1
assert "doctor flags store tmp residue" bash -c "'$HUSK' doctor | grep -q 'tmp-residue.*deadentry'"
assert "doctor flags worktree tmp residue" bash -c "'$HUSK' doctor | grep -q 'tmp-residue.*node_modules.husk-tmp'"
"$HUSK" doctor --fix >/dev/null 2>&1
assert "doctor --fix removed store tmp residue" bash -c "[ ! -d '$res_store/deadentry.tmp.99999999' ]"
assert "doctor --fix removed worktree tmp residue" bash -c "[ ! -d '$TMP/repo/node_modules.husk-tmp.99999999' ]"
assert "doctor --fix spared live-pid tmp" test -d "$res_store/liveentry.tmp.$$"
rm -rf "$res_store/liveentry.tmp.$$"

# native Win32 farm: it declines small trees on purpose (PowerShell startup
# loses to cp -al there), so HUSK_WINFARM_MIN=1 is the only way to make the
# suite's fixtures exercise it at all. It writes a PowerShell script per call
# and used to leave one behind on every add, because the prefarm farms inside a
# background subshell where the EXIT trap never fires.
if command -v cygpath >/dev/null 2>&1 && command -v powershell >/dev/null 2>&1; then
  wf_before=$(ls "${TMPDIR:-/tmp}"/husk-winfarm.*.ps1 2>/dev/null | wc -l | tr -d ' ')
  make_repo "$TMP/wf" "wf-lock-v1"
  ( cd "$TMP/wf" && HUSK_WINFARM_MIN=1 "$HUSK" adopt >/dev/null 2>&1 )
  wf_out=$(cd "$TMP/wf" && HUSK_WINFARM_MIN=1 "$HUSK" add "$TMP/wf-wt" wf/1 2>/dev/null)
  wf_entry=$(printf '%s' "$wf_out" | sed -n 's/.*entry=\([^ ]*\).*/\1/p' | head -1)
  assert "native Win32 farm provisions a correct tree" test -f "$TMP/wf-wt/node_modules/left-pad/index.js"
  assert "native Win32 farm shares inodes with the store" \
    test "$TMP/wf-wt/node_modules/left-pad/index.js" -ef "$wf_entry/left-pad/index.js"
  wf_after=$(ls "${TMPDIR:-/tmp}"/husk-winfarm.*.ps1 2>/dev/null | wc -l | tr -d ' ')
  assert "native Win32 farm leaves no script residue" test "$wf_before" -eq "$wf_after"
else
  ok "skip: no powershell/cygpath here (native Win32 farm is Windows-only)"
  ok "skip: no powershell/cygpath here (native Win32 farm is Windows-only)"
  ok "skip: no powershell/cygpath here (native Win32 farm is Windows-only)"
fi

# store-inside-repo guard: refuse before any damage can happen
assert_not "store inside repo is refused" bash -c "cd '$TMP/repo' && HUSK_STORE='$TMP/repo/.mystore' '$HUSK' link"
assert "guard names the problem" bash -c "cd '$TMP/repo' && HUSK_STORE='$TMP/repo/.mystore' '$HUSK' link 2>&1 | grep -q 'inside the repo'"

# ================= 15. lock + gc race hardening =================
# a LIVE lock holder slower than HUSK_LOCK_TIMEOUT must not kill waiters
# (the winner of an install stampede legitimately runs a multi-minute npm ci)
cat > "$TMP/shim/npm" <<'SHIM'
#!/bin/sh
echo "ci" >> "$NPM_LOG"
sleep 4
mkdir -p node_modules/left-pad
echo "module.exports=10 // slow" > node_modules/left-pad/index.js
SHIM
( cd "$TMP/st" && printf 'slow-lock\n' > package-lock.json && git add -A && git commit -qm bump \
  && git -C "$TMP/st-w1" checkout -q w1 && git -C "$TMP/st-w1" merge -q main \
  && git -C "$TMP/st-w2" checkout -q w2 && git -C "$TMP/st-w2" merge -q main )
: > "$NPM_LOG"
rc_slow=0
for i in 1 2; do
  ( cd "$TMP/st-w$i" && PATH="$TMP/shim:$PATH" HUSK_LOCK_TIMEOUT=2 "$HUSK" link --install >/dev/null 2>&1 ) &
done
for j in $(jobs -p); do wait "$j" || rc_slow=1; done
assert "waiter survives live holder slower than HUSK_LOCK_TIMEOUT" test "$rc_slow" -eq 0
assert "slow stampede still ran exactly one installer" test "$(wc -l < "$NPM_LOG" | tr -d ' ')" -eq 1

# pid-less stale lock (holder died between mkdir and pid write) gets stolen once old
make_repo "$TMP/pl" "pl-lock-v1"
cd "$TMP/pl" || exit 1
pl_out=$("$HUSK" link 2>/dev/null)
pl_key=$(printf '%s' "$pl_out" | sed -n 's/.*key=\([a-f0-9]*\).*/\1/p' | head -1)
pl_entry=$(find "$HUSK_STORE" -type d -name "$pl_key" -print -quit)
chmod -R u+w "$pl_entry" && rm -rf "$pl_entry"     # force a reseed
mkdir "$pl_entry.lock"                              # pid-less: no pid file inside
touch -t 202601010101 "$pl_entry.lock"              # far in the past
assert "pid-less stale lock is stolen, link reseeds" bash -c "cd '$TMP/pl' && HUSK_LOCK_TIMEOUT=90 '$HUSK' link | grep -q linked"
assert "stolen lock is gone" bash -c "[ ! -d '$pl_entry.lock' ]"

# steal_lock must NOT destroy a FRESH pid-less lock: that is a live holder
# caught between its mkdir and its pid write, not an orphan. A stale-pid
# stealer racing a fresh acquisition used to rm the winner's lock, letting
# two processes hold it and lose state rows. Unit-level: call the function.
sed -n '/^mtime_of()/,/^}/p; /^steal_lock()/,/^}/p' "$HUSK" > "$TMP/lockfns.sh"
mkdir "$TMP/fresh.lock"
sl_rc=0
( . "$TMP/lockfns.sh"; steal_lock "$TMP/fresh.lock" 99999 ) >/dev/null 2>&1 || sl_rc=$?
assert "steal_lock refuses a fresh pid-less lock" test "$sl_rc" -ne 0
assert "refused fresh lock is restored intact" test -d "$TMP/fresh.lock"
mkdir "$TMP/orphan.lock"; touch -t 202601010101 "$TMP/orphan.lock"
sl_rc=0
( . "$TMP/lockfns.sh"; steal_lock "$TMP/orphan.lock" "" ) >/dev/null 2>&1 || sl_rc=$?
assert "steal_lock takes an aged pid-less orphan" test "$sl_rc" -eq 0
assert "aged orphan lock is gone" bash -c "[ ! -d '$TMP/orphan.lock' ]"

# concurrent first-time links in ONE worktree: the per-worktree state lock
# must not lose rows (a lost row makes gc think that entry is unreferenced)
make_repo "$TMP/cc" "cc-lock-v1"
cd "$TMP/cc" || exit 1
printf 'py\n' > pyproject.toml; printf 'rs\n' > Cargo.toml
printf 'rb\n' > Gemfile; printf 'pod\n' > Podfile
mkdir -p .venv/lib venv/lib target/debug vendor/gems Pods/pods
echo a > .venv/lib/a; echo b > venv/lib/b; echo c > target/debug/c
echo d > vendor/gems/d; echo e > Pods/pods/e
git add -A; git commit -qm deps
for ccd in node_modules .venv venv target vendor Pods; do
  ( cd "$TMP/cc" && "$HUSK" link "$ccd" >/dev/null 2>&1 ) &
done
wait
cc_rows=$(wc -l < "$TMP/cc/.husk/state" | tr -d ' ')
assert "6 concurrent links keep all 6 state rows" test "$cc_rows" -eq 6

# gc honors the in-use stamp: old unreferenced entry mid-provision must survive
pl_store=$(dirname "$pl_entry")
mkdir -p "$pl_store/cafebabecafebabe"; echo x > "$pl_store/cafebabecafebabe/f"
echo 0 > "$pl_store/cafebabecafebabe/.husk-seeded"   # long past seed grace
date +%s > "$pl_store/cafebabecafebabe.used"          # but provisioning right now
assert_not "gc spares entry with fresh in-use stamp" bash -c "cd '$TMP/pl' && '$HUSK' gc --dry-run | grep -q cafebabecafebabe"
echo 0 > "$pl_store/cafebabecafebabe.used"            # stamp aged out
assert "gc collects entry once in-use stamp ages" bash -c "cd '$TMP/pl' && '$HUSK' gc --dry-run | grep -q cafebabecafebabe"
(cd "$TMP/pl" && "$HUSK" gc >/dev/null 2>&1)
assert "gc removed the aged entry and its stamp" bash -c "[ ! -d '$pl_store/cafebabecafebabe' ] && [ ! -f '$pl_store/cafebabecafebabe.used' ]"

# ================= 16. conf safety, gc authority, exit codes, edge paths =================
# .husk.conf is parsed, never sourced: injection attempts must not execute
make_repo "$TMP/cf" "cf-lock-v1"
cd "$TMP/cf" || exit 1
cat > .husk.conf <<CONF
# comment line
HUSK_MODE=copy
HUSK_REAP_DAYS=\$(touch $TMP/pwned1)
PWN=\`touch $TMP/pwned2\`
CONF
assert "conf HUSK_MODE honored by parser" bash -c "cd '$TMP/cf' && '$HUSK' link | grep -q 'mode=copy'"
assert "conf injection: command substitution not executed" bash -c "[ ! -e '$TMP/pwned1' ] && [ ! -e '$TMP/pwned2' ]"
rm -f .husk.conf

# gc liveness comes from worktree state, not .refs alone: a process killed
# between state_set and add_ref must not cost the worktree its entry
cf_key=$(cd "$TMP/cf" && "$HUSK" status | sed -n 's/.*key=\([a-f0-9]*\).*/\1/p' | head -1)
cf_entry=$(find "$HUSK_STORE" -type d -name "$cf_key" -print -quit)
echo 0 > "$cf_entry/.husk-seeded"
echo 0 > "$cf_entry.used"
rm -f "$cf_entry.refs"                      # simulate the lost ref
(cd "$TMP/cf" && "$HUSK" gc >/dev/null 2>&1)
assert "gc keeps entry referenced only by worktree state" test -d "$cf_entry"
assert "gc healed the missing ref" bash -c "grep -q 'cf' '$cf_entry.refs'"

# husk add propagates needs-install (exit 2) instead of swallowing it
mkdir -p "$TMP/x2"; ( cd "$TMP/x2" && git init -q -b main \
  && echo '{"name":"x2"}' > package.json && printf 'x2-lock-nowhere\n' > package-lock.json \
  && git add -A && git commit -qm i )
rc_x2=0
( cd "$TMP/x2" && "$HUSK" add ../x2-wt b-x2 >/dev/null 2>&1 ) || rc_x2=$?
assert "husk add propagates needs-install exit 2" test "$rc_x2" -eq 2
assert "worktree still created on store miss" test -d "$TMP/x2-wt"

# doctor sweeps .husk-old replace residue
mkdir -p "$TMP/repo/node_modules.husk-old.99999999"
cd "$TMP/repo" || exit 1
assert "doctor flags .husk-old residue" bash -c "'$HUSK' doctor | grep -q 'node_modules.husk-old'"
"$HUSK" doctor --fix >/dev/null 2>&1
assert "doctor --fix removed .husk-old residue" bash -c "[ ! -d '$TMP/repo/node_modules.husk-old.99999999' ]"

# spaces in repo, store, and worktree paths work end to end
mkdir -p "$TMP/sp repo"; ( cd "$TMP/sp repo" && git init -q -b main \
  && echo '{"name":"sp"}' > package.json && printf 'sp-lock\n' > package-lock.json \
  && mkdir -p node_modules/left-pad && echo m > node_modules/left-pad/index.js \
  && git add -A && git commit -qm i )
assert "link works with spaces in repo+store paths" bash -c "cd '$TMP/sp repo' && HUSK_STORE='$TMP/sp store' '$HUSK' link | grep -q linked"
assert "add works with spaces everywhere" bash -c "cd '$TMP/sp repo' && HUSK_STORE='$TMP/sp store' '$HUSK' add '../sp wt' spb >/dev/null 2>&1 && test -e '$TMP/sp wt/node_modules/left-pad/index.js'"

# store_guard resolves symlink aliases: alias pointing into the repo is refused
if [ "$HAVE_SYMLINK" = 1 ]; then
  mkdir -p "$TMP/repo/.mystore2"; ln -s "$TMP/repo/.mystore2" "$TMP/alias-store"
  assert_not "store via symlink alias into repo refused" bash -c "cd '$TMP/repo' && HUSK_STORE='$TMP/alias-store' '$HUSK' link"

  # ...while a legitimately external symlinked store still works
  mkdir -p "$TMP/real-store"; ln -s "$TMP/real-store" "$TMP/store-link"
  assert "external symlinked store works" bash -c "cd '$TMP/cf' && HUSK_STORE='$TMP/store-link' '$HUSK' link | grep -q linked"
else
  ok "skip: no real symlinks here (store alias tests need them)"
  ok "skip: no real symlinks here (store alias tests need them)"
fi

# store key must survive a Windows update: MSYS bakes the OS build number into
# 'uname -s', which would re-key (and force a reseed of) the whole store
mkdir -p "$TMP/us1" "$TMP/us2"
cat > "$TMP/us1/uname" <<'US'
#!/bin/sh
case "${1:-}" in -s) echo "MINGW64_NT-10.0-22000" ;; -m) echo "x86_64" ;; *) echo "MINGW64_NT" ;; esac
US
sed 's/22000/26200/' "$TMP/us1/uname" > "$TMP/us2/uname"
chmod +x "$TMP/us1/uname" "$TMP/us2/uname"
make_repo "$TMP/un" "un-lock-v1"
kA=$(cd "$TMP/un" && PATH="$TMP/us1:$PATH" "$HUSK" adopt 2>/dev/null | sed -n 's/.*key=\([a-f0-9]*\).*/\1/p' | head -1)
kB=$(cd "$TMP/un" && PATH="$TMP/us2:$PATH" "$HUSK" adopt 2>/dev/null | sed -n 's/.*key=\([a-f0-9]*\).*/\1/p' | head -1)
assert "store key stable across Windows build numbers" test -n "$kA" -a "$kA" = "$kB"

# store key must survive git's line-ending rewriting. core.autocrlf=true is the
# Git for Windows default, so a lockfile committed with LF lands in a fresh
# worktree as CRLF: key by raw bytes and husk misses its own store on every add,
# silently, forever. Same content, two spellings, one key.
make_repo "$TMP/crlf" "crlf-lock-v1"
kLF=$(cd "$TMP/crlf" && "$HUSK" adopt 2>/dev/null | sed -n 's/.*key=\([a-f0-9]*\).*/\1/p' | head -1)
printf 'crlf-lock-v1\r\n' > "$TMP/crlf/package-lock.json"
kCRLF=$(cd "$TMP/crlf" && "$HUSK" adopt 2>/dev/null | sed -n 's/.*key=\([a-f0-9]*\).*/\1/p' | head -1)
assert "store key ignores CRLF vs LF in the lockfile" test -n "$kLF" -a "$kLF" = "$kCRLF"
# ...but content still keys: a real change must still get its own entry
printf 'crlf-lock-v2\r\n' > "$TMP/crlf/package-lock.json"
kV2=$(cd "$TMP/crlf" && "$HUSK" adopt 2>/dev/null | sed -n 's/.*key=\([a-f0-9]*\).*/\1/p' | head -1)
assert "lockfile content still keys" test -n "$kV2" -a "$kV2" != "$kLF"

# repo_id must not depend on which MSYS mount spelling the cwd used: /tmp and
# /c/Users/.../Temp are the same dir on native Git Bash, and mixed spellings
# split the store namespace (adopt seeded one id, add provisioned another)
if command -v cygpath >/dev/null 2>&1; then
  make_repo "$TMP/alias" "alias-lock-v1"
  wform=$(cygpath -m "$TMP/alias")
  altform="/$(printf '%s' "$wform" | cut -c1 | tr 'A-Z' 'a-z')$(printf '%s' "$wform" | cut -c3-)"
  sA=$(cd "$TMP/alias" && HUSK_STORE="$TMP/aliasstore" "$HUSK" status 2>/dev/null | grep '^store=')
  sB=$(cd "$altform" && HUSK_STORE="$TMP/aliasstore" "$HUSK" status 2>/dev/null | grep '^store=')
  assert "store namespace stable across MSYS mount aliases" test -n "$sA" -a "$sA" = "$sB"
else
  ok "skip: no cygpath here (mount-alias spellings are a Windows thing)"
fi

# ================= 17. stress: hostile names + big tree (opt-in: HUSK_STRESS=1) =================
if [ "${HUSK_STRESS:-0}" = "1" ]; then
  mkdir -p "$TMP/stress"; ( cd "$TMP/stress" && git init -q -b main \
    && echo '{"name":"stress"}' > package.json && printf 'stress-lock\n' > package-lock.json \
    && git add -A && git commit -qm i )
  cd "$TMP/stress" || exit 1
  mkdir -p node_modules
  ( cd node_modules || exit 1
    d=deep; for i in $(seq 1 45); do d="$d/n$i"; done; mkdir -p "$d"; echo x > "$d/leaf.js"
    mkdir -p "-dashdir" "empty-dir" "uni-\xc3\xa9\xc3\xb6" 2>/dev/null || mkdir -p "unidir"
    echo x > "./-dashfile"; : > zero-byte; dd if=/dev/zero of=big.bin bs=1048576 count=8 2>/dev/null
    i=0; while [ $i -lt "${HUSK_STRESS_FILES:-2000}" ]; do
      mkdir -p "pkg$((i % 50))"; echo "m$i" > "pkg$((i % 50))/f$i.js"; i=$((i+1))
    done )
  assert "stress: link succeeds on hostile tree" bash -c "cd '$TMP/stress' && '$HUSK' link | grep -q linked"
  printf 'stress-lock-2\n' > package-lock.json
  assert "stress: adopt+dedupe succeed on hostile tree" bash -c "cd '$TMP/stress' && '$HUSK' adopt | grep -q adopted"
  assert "stress: deep leaf survived" bash -c "find \"\$(find '$HUSK_STORE' -type d -name 'n45' | head -1)\" -name leaf.js | grep -q leaf"
fi

# ================= 18. speculative prefarm (add overlaps checkout) =================
make_repo "$TMP/pre" "lock-pre"
cd "$TMP/pre" || exit 1
"$HUSK" link >/dev/null 2>&1
"$HUSK" add "$TMP/pre-wt" feat-pre >/dev/null 2>&1
assert "prefarm: add provisions deps from the stage" test -e "$TMP/pre-wt/node_modules/left-pad/index.js"
assert_not "prefarm: no staging residue after add" bash -c "ls -d '$TMP'/pre-wt.husk-pre.* 2>/dev/null | grep -q ."
# a branch whose lockfile diverged from HEAD must never be served the stale
# stage: link_one re-keys from the real checkout and the stage is discarded
cd "$TMP/pre" || exit 1
git checkout -qb feat-newlock
printf '%s\n' "lock-pre-CHANGED" > package-lock.json
git add package-lock.json && git commit -qm newlock
git checkout -q main
rc_pre=0; "$HUSK" add "$TMP/pre-wt2" feat-newlock >/dev/null 2>&1 || rc_pre=$?
assert "prefarm discard: diverged lockfile is a store miss (exit 2)" test "$rc_pre" -eq 2
assert_not "prefarm discard: stale deps NOT provisioned" test -e "$TMP/pre-wt2/node_modules/left-pad/index.js"
assert_not "prefarm discard: no staging residue" bash -c "ls -d '$TMP'/pre-wt2.husk-pre.* 2>/dev/null | grep -q ."
assert "prefarm off: HUSK_PREFARM=0 still provisions" bash -c "
  HUSK_PREFARM=0 '$HUSK' add '$TMP/pre-wt3' feat-off >/dev/null 2>&1 &&
  test -e '$TMP/pre-wt3/node_modules/left-pad/index.js'"

# ================= 19. list: fleet view + savings accounting =================
# status answers "how is THIS worktree wired"; list has to answer it for the
# whole fleet and put a number on what the sharing actually bought.
make_repo "$TMP/lst" "lock-lst"
cd "$TMP/lst" || exit 1
dd if=/dev/zero of=node_modules/big.bin bs=1024 count=3072 2>/dev/null  # 3 MB, so saved_mb is not 0
"$HUSK" link >/dev/null 2>&1
"$HUSK" add "$TMP/lst-a" feat-a >/dev/null 2>&1
"$HUSK" add "$TMP/lst-b" feat-b >/dev/null 2>&1
lst_out=$("$HUSK" list 2>/dev/null)
assert "list exits 0" bash -c "cd '$TMP/lst' && '$HUSK' list >/dev/null"
assert "list reports every worktree, not just the current one" \
  test "$(printf '%s\n' "$lst_out" | grep -c '^wt ')" -eq 3
assert "list reports a dep line per worktree" \
  test "$(printf '%s\n' "$lst_out" | grep -c '^dep ')" -eq 3
assert "list finds all deps healthy" \
  test "$(printf '%s\n' "$lst_out" | grep -c 'state=ok')" -eq 3
assert "list collapses the fleet onto one store entry" \
  bash -c "printf '%s\n' \"\$0\" | grep -q '^entry .*refs=3'" "$lst_out"
assert "list summary counts the fleet" \
  bash -c "printf '%s\n' \"\$0\" | grep -q '^summary worktrees=3 entries=1'" "$lst_out"
# 3 MB shared by 3 worktrees means 2 copies never paid for: saved must be > 0
lst_saved=$(printf '%s\n' "$lst_out" | sed -n 's/^summary .*saved_mb=\([0-9]*\).*/\1/p')
assert "list reports nonzero disk saved by sharing" test "${lst_saved:-0}" -gt 0
assert "saved_mb credits the copies avoided, not the entry itself" test "${lst_saved:-0}" -ge 5
# a worktree whose lockfile moved on is stale against its store entry; the
# fleet view is where you would notice, so it has to say so
cd "$TMP/lst-a" || exit 1
printf '%s\n' "lock-lst-MOVED" > package-lock.json
assert "list flags lockfile drift in a worktree" \
  bash -c "cd '$TMP/lst-a' && '$HUSK' list | grep -q 'drift=lockfile-changed'"
assert "list still exits 0 when a worktree has drifted" \
  bash -c "cd '$TMP/lst-a' && '$HUSK' list >/dev/null"
assert "list leaves no temp dir behind" \
  bash -c "! ls -d \"\${TMPDIR:-/tmp}\"/husk-list.* 2>/dev/null | grep -q ."
# a worktree whose dep dir was deleted must be reported, not silently counted
# as a healthy reference inflating the savings number
rm -rf "$TMP/lst-b/node_modules"
assert "list flags a worktree whose dep dir vanished" \
  bash -c "cd '$TMP/lst' && '$HUSK' list | grep -q 'state=missing-dir'"
assert "vanished dep drops out of the ref count" \
  bash -c "cd '$TMP/lst' && '$HUSK' list | grep -q '^entry .*refs=2'"

# ================= 19. store compression =================
# A store entry is written once and only read afterwards, which is the one
# shape transparent filesystem compression is safe for. These tests care about
# two things above all: that husk never CLAIMS compression it did not achieve,
# and that a compressed entry still hands back exactly the bytes that went in.
make_repo "$TMP/cmp" "cmp-lock-v1"
cd "$TMP/cmp" || exit 1
# something worth compressing: the default fixture is a few hundred bytes
mkdir -p node_modules/big
i=0
while [ "$i" -lt 400 ]; do
  printf '"use strict"; Object.defineProperty(exports, "__esModule", { value: true });\n' >> node_modules/big/bundle.js
  i=$((i+1))
done
"$HUSK" link >/dev/null 2>&1
# Ask husk where the entry is rather than guessing: the store is laid out as
# <base>/<dep dir>/<key>, and a test that assumes any other shape quietly
# skips itself instead of failing, which is worse than a wrong answer.
cmp_base=$("$HUSK" status 2>/dev/null | sed -n 's/^store=//p' | head -1)
cmp_key=$("$HUSK" status 2>/dev/null | sed -n 's/.* key=\([0-9a-f][0-9a-f]*\).*/\1/p' | head -1)
cmp_dir="$cmp_base/node_modules/$cmp_key"

assert "compress --probe exits 0" bash -c "cd '$TMP/cmp' && '$HUSK' compress --probe >/dev/null"
assert "compress --probe reports a tool" \
  bash -c "cd '$TMP/cmp' && '$HUSK' compress --probe | grep -q '^compress='"
assert "compress rejects an unknown option" \
  bash -c "cd '$TMP/cmp' && ! '$HUSK' compress --nope >/dev/null 2>&1"
assert "compress --dry-run reports without acting" \
  bash -c "cd '$TMP/cmp' && '$HUSK' compress --dry-run | grep -q '^compressed='"
assert "HUSK_COMPRESS=0 disables the probe entirely" \
  bash -c "cd '$TMP/cmp' && HUSK_COMPRESS=0 '$HUSK' compress --probe | grep -q '^compress=none'"

hash_of() { openssl sha256 < "$1" 2>/dev/null || sha256sum < "$1"; }

HAVE_COMPRESS=0
cd "$TMP/cmp" || exit 1
case $("$HUSK" compress --probe 2>/dev/null | sed -n 's/^compress=//p') in
  ''|none) HAVE_COMPRESS=0 ;;
  *)       HAVE_COMPRESS=1 ;;
esac

if [ "$HAVE_COMPRESS" = 1 ] && [ -d "$cmp_dir" ]; then
  cmp_sig_before=$(hash_of "$cmp_dir/big/bundle.js")
  cmp_kb_before=$(du -sk "$cmp_dir" | awk '{print $1}')
  cd "$TMP/cmp" && "$HUSK" compress >/dev/null 2>&1
  cmp_kb_after=$(du -sk "$cmp_dir" | awk '{print $1}')
  cmp_sig_after=$(hash_of "$cmp_dir/big/bundle.js")

  assert "compressed entry consumes fewer blocks" test "$cmp_kb_after" -lt "$cmp_kb_before"
  assert "compressed entry returns identical bytes" test "$cmp_sig_before" = "$cmp_sig_after"
  assert "compress is idempotent (second run exits 0)" \
    bash -c "cd '$TMP/cmp' && '$HUSK' compress >/dev/null"
  # the whole point: a worktree provisioned from a compressed entry inherits
  # the compression, because it points at the same bytes
  ( cd "$TMP/cmp" && "$HUSK" add "$TMP/cmp-wt" cmpwt >/dev/null 2>&1 )
  assert "worktree from a compressed entry has identical content" \
    bash -c "cmp -s '$TMP/cmp-wt/node_modules/big/bundle.js' '$cmp_dir/big/bundle.js'"
  wt_kb=$(du -sk "$TMP/cmp-wt/node_modules" 2>/dev/null | awk '{print $1}')
  assert "worktree inherits the compressed footprint" test "${wt_kb:-999999}" -le "$cmp_kb_before"
else
  ok "skip: no store compression on this filesystem (compress tests elsewhere)"
  ok "skip: no store compression on this filesystem (compress tests elsewhere)"
  ok "skip: no store compression on this filesystem (compress tests elsewhere)"
  ok "skip: no store compression on this filesystem (compress tests elsewhere)"
  ok "skip: no store compression on this filesystem (compress tests elsewhere)"
fi

# an entry that is mid-seed is being WRITTEN; compressing under a writer is how
# a good idea corrupts a store, so a locked entry must be skipped and counted
mkdir -p "$cmp_dir.lock" 2>/dev/null
assert "compress skips a locked entry" \
  bash -c "cd '$TMP/cmp' && '$HUSK' compress | grep -qE '^skipped=[1-9]'"
rmdir "$cmp_dir.lock" 2>/dev/null

# ================= summary =================
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
