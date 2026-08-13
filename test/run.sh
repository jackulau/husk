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
if [ "$HAVE_SYMLINK" = 1 ]; then
  "$HUSK" link --mode symlink >/dev/null 2>&1
  assert "symlink mode: node_modules is a symlink" test -L "$TMP/repo2/node_modules"
  assert "symlink resolves into store" bash -c "readlink '$TMP/repo2/node_modules' | grep -q '$HUSK_STORE'"
  if [ "$CAN_DIRGUARD" = 1 ]; then
    assert "write guard: creating file at entry root fails" bash -c "! touch '$TMP/repo2/node_modules/newpkg' 2>/dev/null"
  else
    ok "skip: dir write guard not enforceable here (root, or FS ignores dir a-w)"
  fi
else
  # fake-symlink platform: forced symlink mode must refuse the fake and
  # fall back to a REAL directory, recording the mode it actually used
  assert "forced symlink degrades to copy on fake-symlink platforms" \
    bash -c "cd '$TMP/repo2' && '$HUSK' link --mode symlink 2>/dev/null | grep -q 'mode=copy'"
  ok "skip: no real symlinks here (MSYS without symlink privilege)"
  ok "skip: no real symlinks here (MSYS without symlink privilege)"
fi

# ================= 6. doctor detects + fixes dangling links =================
if [ "$HAVE_SYMLINK" = 1 ]; then
  entry2=$(readlink "$TMP/repo2/node_modules")
  mv "$entry2" "$entry2.hidden"
  assert "doctor detects dangling link" bash -c "cd '$TMP/repo2' && '$HUSK' doctor | grep -q dangling"
  mv "$entry2.hidden" "$entry2"
  rm "$TMP/repo2/node_modules"; ln -s "$TMP/nowhere" "$TMP/repo2/node_modules"
  cd "$TMP/repo2" || exit 1; "$HUSK" doctor --fix >/dev/null 2>&1 || true
  assert "doctor --fix repaired the link" test -e "$TMP/repo2/node_modules/left-pad/index.js"
  assert "doctor --fix preserved symlink mode" test -L "$TMP/repo2/node_modules"
else
  ok "skip: no real symlinks here (dangling-link tests need them)"
  ok "skip: no real symlinks here (dangling-link tests need them)"
  ok "skip: no real symlinks here (dangling-link tests need them)"
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

# ================= summary =================
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
