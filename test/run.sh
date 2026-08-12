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

# ---------- fixture: a fake node repo ----------
make_repo() { # path lock-content
  local r="$1" lock="$2"
  mkdir -p "$r"; cd "$r"
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
cd "$TMP/repo"
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
cd "$TMP/wt1"
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
cd "$TMP/repo2"
"$HUSK" link --mode symlink >/dev/null 2>&1
assert "symlink mode: node_modules is a symlink" test -L "$TMP/repo2/node_modules"
assert "symlink resolves into store" bash -c "readlink '$TMP/repo2/node_modules' | grep -q '$HUSK_STORE'"
assert "write guard: creating file at entry root fails" bash -c "! touch '$TMP/repo2/node_modules/newpkg' 2>/dev/null"

# ================= 6. doctor detects + fixes dangling links =================
entry2=$(readlink "$TMP/repo2/node_modules")
mv "$entry2" "$entry2.hidden"
assert "doctor detects dangling link" bash -c "cd '$TMP/repo2' && '$HUSK' doctor | grep -q dangling"
mv "$entry2.hidden" "$entry2"
rm "$TMP/repo2/node_modules"; ln -s "$TMP/nowhere" "$TMP/repo2/node_modules"
cd "$TMP/repo2"; "$HUSK" doctor --fix >/dev/null 2>&1 || true
assert "doctor --fix repaired the link" test -e "$TMP/repo2/node_modules/left-pad/index.js"
assert "doctor --fix preserved symlink mode" test -L "$TMP/repo2/node_modules"

# ================= 7. unlink materializes a private copy =================
cd "$TMP/repo2"
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
cd "$TMP/repo3"
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
cd "$TMP/repo"
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
cd "$TMP/repo"
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
cd "$TMP/repo"
"$HUSK" setup --write >/dev/null 2>&1
assert "setup --write created AGENTS.md with snippet" bash -c "grep -q 'husk:agent-instructions' '$TMP/repo/AGENTS.md'"
"$HUSK" setup --write >/dev/null 2>&1
assert "setup --write is idempotent (one snippet)" bash -c "[ \"\$(grep -c 'husk add' '$TMP/repo/AGENTS.md')\" -eq 1 ]"
assert "setup without --write prints snippet" bash -c "'$HUSK' setup | grep -q 'husk add'"

# ================= 13. store dedupe across entries =================
make_repo "$TMP/dd" "dd-lock-v1"
cd "$TMP/dd"
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
cd "$TMP/repo"
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

# ================= summary =================
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
