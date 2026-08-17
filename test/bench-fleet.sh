#!/usr/bin/env bash
# Copyright 2026 Jack Lau
# SPDX-License-Identifier: Apache-2.0
#
# Fleet storage benchmark: what does a FLEET of worktrees actually cost on disk?
#
# The README's numbers come from here. Disk is measured as a whole-volume delta
# (df), never `du`: NTFS keeps small directories inside the MFT and `du` cannot
# see them, and a hardlink farm's whole point is that apparent size lies. The
# volume delta is the number that describes your disk.
#
#   bash test/bench-fleet.sh --self-test        # fast harness check, tiny fixture
#   bash test/bench-fleet.sh --baseline [N]     # real run: N worktrees, both ways
#   bash test/bench-fleet.sh --after [N]        # husk side only, anchored on store du
#   bash test/bench-fleet.sh --compress-check   # husk compress shrinks the store
#   bash test/bench-fleet.sh --inherit-check    # a worktree inherits that compression
#   bash test/bench-fleet.sh --health           # doctor clean, no residue, contents intact
#
# The three checks report "skipped" and exit 0 where the filesystem accepts no
# compressor, because that is the honest answer on such a volume.
#
# HUSK_BENCH_FIXTURE=/path/to/node_modules uses a REAL dependency tree instead
# of the synthetic one. Numbers quoted in the README should come from a real one.
set -euo pipefail

HUSK_BIN=${HUSK_BIN:-"$(cd "$(dirname "$0")/.." && pwd)/bin/husk"}
BENCH_N=${BENCH_N:-5}
WORK=""

say()  { printf 'bench: %s\n' "$*" >&2; }
out()  { printf '%s\n' "$*"; }
die()  { printf 'bench: error: %s\n' "$*" >&2; exit 1; }

cleanup() { [ -n "$WORK" ] && [ -d "$WORK" ] && { chmod -R u+w "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }; }
trap cleanup EXIT

# ---------- measurement ----------
vol_free_kb() { # path -> free KB on the volume that path lives on
  df -k -P "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

settle() { # give the filesystem a moment to finish accounting before we read it
  sleep 1
}

# consumed_kb BEFORE AFTER -> KB the work consumed (free space went DOWN)
consumed_kb() { echo $(( $1 - $2 )); }

noise_floor_kb() { # path -> how much this volume moves on its OWN over a settle window
  # A whole-volume delta on a live dev box is not a clean instrument: an editor
  # autosave, a package cache, or Windows Defender writing its logs all land in
  # the same number. Sample the volume doing nothing, and treat anything under
  # that as unmeasured rather than measured-as-zero.
  local a b d worst=0 i=0
  while [ "$i" -lt 3 ]; do
    a=$(vol_free_kb "$1"); settle; b=$(vol_free_kb "$1")
    d=$(( a - b )); [ "$d" -lt 0 ] && d=$(( -d ))
    [ "$d" -gt "$worst" ] && worst=$d
    i=$((i + 1))
  done
  echo "$worst"
}

mb() { # kb -> MB, one decimal, no bc
  awk -v k="$1" 'BEGIN { printf "%.1f", k/1024 }'
}

delta_mb() { # kb noise_kb [divisor] -> MB, or "unmeasured" if the delta is inside the noise
  local kb="$1" noise="$2" div="${3:-1}"
  if [ "$kb" -le "$noise" ]; then printf 'unmeasured'; else mb $(( kb / div )); fi
}

# ---------- fixture ----------
make_fixture() { # dir pkgs files_per_pkg -> a node_modules-shaped tree of JS-ish text
  local root="$1" pkgs="$2" per="$3" p f d
  mkdir -p "$root"
  p=0
  while [ "$p" -lt "$pkgs" ]; do
    d="$root/pkg-$p"
    mkdir -p "$d/dist" "$d/src"
    printf '{"name":"pkg-%s","version":"1.0.%s","main":"dist/index.js"}\n' "$p" "$p" > "$d/package.json"
    f=0
    while [ "$f" -lt "$per" ]; do
      # JS-like text: real dependency trees are repetitive text, and a
      # compressor's ratio depends entirely on that. Random bytes would
      # measure nothing useful.
      {
        printf '"use strict";\n'
        printf 'Object.defineProperty(exports, "__esModule", { value: true });\n'
        printf 'var helper_%s = require("../src/helper");\n' "$f"
        printf 'function transform_%s(input, options) {\n' "$f"
        printf '  if (!input) { throw new TypeError("input is required"); }\n'
        printf '  var result = helper_%s.normalize(input, options || {});\n' "$f"
        printf '  return result.map(function (item) { return item.value; });\n'
        printf '}\n'
        printf 'exports.transform_%s = transform_%s;\n' "$f" "$f"
      } > "$d/dist/f$f.js"
      f=$((f + 1))
    done
    printf 'module.exports = { normalize: function (v) { return [v]; } };\n' > "$d/src/helper.js"
    p=$((p + 1))
  done
}

make_fat_fixture() { # dir pkgs files_per_pkg -> same shape, but files big enough to compress
  # A compressor cannot show you anything on a 400-byte file: the saving is
  # smaller than the cluster it still has to occupy. The compression checks
  # need files that span several clusters, so build one repetitive chunk and
  # stamp it out, rather than looping printf tens of thousands of times.
  local root="$1" pkgs="$2" per="$3" chunk="$1/../.chunk" p f d i=0
  mkdir -p "$root"
  : > "$chunk"
  while [ "$i" -lt 250 ]; do
    {
      printf 'exports.handler_%s = function (input, options) {\n' "$i"
      printf '  var normalized = require("./helper").normalize(input, options || {});\n'
      printf '  return normalized.map(function (item) { return item.value; });\n'
      printf '};\n'
    } >> "$chunk"
    i=$((i + 1))
  done
  p=0
  while [ "$p" -lt "$pkgs" ]; do
    d="$root/pkg-$p"
    mkdir -p "$d/dist"
    printf '{"name":"pkg-%s","version":"1.0.%s","main":"dist/index.js"}\n' "$p" "$p" > "$d/package.json"
    f=0
    while [ "$f" -lt "$per" ]; do
      { printf '"use strict";\n// pkg-%s file-%s\n' "$p" "$f"; cat "$chunk" "$chunk" "$chunk"; } > "$d/dist/f$f.js"
      f=$((f + 1))
    done
    printf 'module.exports = { normalize: function (v) { return [v]; } };\n' > "$d/dist/helper.js"
    p=$((p + 1))
  done
  rm -f "$chunk"
}

make_repo() { # dir lockcontent -> a git repo with a lockfile and deps installed
  local dir="$1" lock="$2"
  mkdir -p "$dir"
  ( cd "$dir"
    git init -q .
    git config user.email bench@example.com
    git config user.name bench
    printf '{"name":"bench","version":"1.0.0"}\n' > package.json
    printf '%s\n' "$lock" > package-lock.json
    printf 'node_modules/\n' > .gitignore
    git add -A
    git commit -qm init
  )
}

# ---------- the two ways to get a fleet ----------
fleet_plain() { # repo n -> git worktree add + a full copy of node_modules, N times
  local repo="$1" n="$2" i
  i=1
  while [ "$i" -le "$n" ]; do
    ( cd "$repo" && git worktree add -q -b "plain-$i" "../plain-$i" >/dev/null 2>&1 )
    cp -R "$repo/node_modules" "$repo/../plain-$i/node_modules"
    i=$((i + 1))
  done
}

fleet_husk() { # repo from to -> husk add for worktrees from..to
  local repo="$1" i="$2" n="$3" rc log
  log="$WORK/husk-add.log"
  while [ "$i" -le "$n" ]; do
    rc=0
    ( cd "$repo" && "$HUSK_BIN" add "../husk-$i" "husk-$i" ) >> "$log" 2>&1 || rc=$?
    if [ "$rc" != 0 ]; then
      # A benchmark that hides why the thing under test failed is a benchmark
      # you cannot debug. Show the tail rather than an exit code alone.
      say "husk add failed on worktree $i (exit $rc); last lines:"
      tail -12 "$log" >&2
      die "husk add failed on worktree $i (exit $rc)"
    fi
    i=$((i + 1))
  done
}

# ---------- runs ----------
count_shared() { # dir -> number of files with nlink > 1 (i.e. actually shared)
  local dir="$1" n
  n=$(find "$dir" -type f -links +1 2>/dev/null | grep -c . || true)
  echo "${n:-0}"
}

run_bench() { # pkgs per n label -> prints key=value lines, returns the numbers
  local pkgs="$1" per="$2" n="$3"
  local base free0 free1 free2 free_seed plain_kb husk_kb seed_kb marginal_kb store_kb noise total_files shared

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/husk-bench.XXXXXX") || die "mktemp failed"
  base="$WORK/repo"
  export HUSK_STORE="$WORK/store"

  say "building fixture (${pkgs} packages x ${per} files)"
  make_repo "$base" "bench-lock-v1"
  if [ -n "${HUSK_BENCH_FIXTURE:-}" ]; then
    say "using real fixture: $HUSK_BENCH_FIXTURE"
    cp -R "$HUSK_BENCH_FIXTURE" "$base/node_modules"
  else
    make_fixture "$base/node_modules" "$pkgs" "$per"
  fi

  settle
  noise=$(noise_floor_kb "$WORK")
  say "volume noise floor: $(mb "$noise") MB over a settle window"

  free0=$(vol_free_kb "$WORK")
  say "plain: $n x (git worktree add + cp -R)"
  fleet_plain "$base" "$n"
  settle
  free1=$(vol_free_kb "$WORK")
  plain_kb=$(consumed_kb "$free0" "$free1")

  # The first husk add pays for the whole store entry; every later one pays
  # only for what it cannot share. Quoting one number for both is how a
  # storage claim becomes dishonest, so measure them apart.
  say "husk: seeding worktree (store is cold)"
  fleet_husk "$base" 1 1
  settle
  free_seed=$(vol_free_kb "$WORK")
  seed_kb=$(consumed_kb "$free1" "$free_seed")

  if [ "$n" -gt 1 ]; then
    say "husk: $((n - 1)) more (store is warm)"
    fleet_husk "$base" 2 "$n"
  fi
  settle
  free2=$(vol_free_kb "$WORK")
  marginal_kb=$(consumed_kb "$free_seed" "$free2")
  husk_kb=$(consumed_kb "$free1" "$free2")
  store_kb=$(du -sk "$HUSK_STORE" 2>/dev/null | awk '{print $1}')

  total_files=$(find "$base/../husk-1/node_modules" -type f 2>/dev/null | grep -c . || true)
  shared=$(count_shared "$base/../husk-1/node_modules")

  out "worktrees=$n"
  out "noise_floor_mb=$(mb "$noise")"
  out "plain_total_mb=$(mb "$plain_kb")"
  out "husk_total_mb=$(mb "$husk_kb")"
  out "plain_per_worktree_mb=$(mb $(( plain_kb / n )))"
  out "husk_per_worktree_mb=$(mb $(( husk_kb / n )))"
  out "husk_seed_mb=$(mb "$seed_kb")"
  if [ "$n" -gt 1 ]; then
    out "husk_marginal_per_worktree_mb=$(mb $(( marginal_kb / (n - 1) )))"
  fi
  out "store_physical_mb=$(mb "${store_kb:-0}")"
  out "worktree_files=${total_files:-0}"
  out "worktree_files_shared=${shared:-0}"
  # A ratio computed from a delta smaller than the volume's own noise is a
  # fabricated number. Say "unmeasured" instead of printing one.
  if [ "$husk_kb" -le "$noise" ] || [ "$plain_kb" -le "$noise" ]; then
    out "ratio_total=unmeasured"
    say "deltas are within the noise floor: use a bigger fixture for a real ratio"
  elif [ "$husk_kb" -gt 0 ]; then
    out "ratio_total=$(awk -v a="$plain_kb" -v b="$husk_kb" 'BEGIN { printf "%.1f", a/b }')"
  else
    out "ratio_total=inf"
  fi
}

self_test() {
  local o files shared
  o=$(run_bench 6 4 2)
  printf '%s\n' "$o"
  printf '%s\n' "$o" | grep -q '^worktrees=2$'    || die "self-test: no worktree count"
  printf '%s\n' "$o" | grep -q '^plain_total_mb=' || die "self-test: no plain total"
  printf '%s\n' "$o" | grep -q '^husk_total_mb='  || die "self-test: no husk total"
  printf '%s\n' "$o" | grep -q '^noise_floor_mb=' || die "self-test: no noise floor"
  # The storage delta on a tiny fixture is noise, so the harness proves itself
  # on the thing that is NOT noise: husk's worktree must actually share inodes
  # with the store. If that fails, husk is copying and every later number is a lie.
  files=$(printf '%s\n' "$o"  | sed -n 's/^worktree_files=//p')
  shared=$(printf '%s\n' "$o" | sed -n 's/^worktree_files_shared=//p')
  [ "${files:-0}" -gt 0 ]        || die "self-test: husk worktree has no files"
  [ "${shared:-0}" -eq "$files" ] || die "self-test: only $shared/$files worktree files are shared (husk is not sharing)"
  say "self-test ok: $shared/$files files shared, noise floor $(printf '%s\n' "$o" | sed -n 's/^noise_floor_mb=//p') MB"
}

run_after() { # n -> the husk side only, with a compression-anchored report
  # Deliberately does NOT re-measure the plain fleet. Compression cannot change
  # what a plain worktree costs, and the plain phase is both the slowest part of
  # the run and the largest single disturbance to the volume it is measuring.
  # Compare against the plain number in baseline.txt, taken on this same box,
  # fixture and method.
  local n="$1" base free0 free_seed free2 seed_kb marginal_kb store_kb store_lkb
  local noise noise_after total_files shared tool

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/husk-after.XXXXXX") || die "mktemp failed"
  base="$WORK/repo"
  export HUSK_STORE="$WORK/store"

  make_repo "$base" "bench-lock-v1"
  if [ -n "${HUSK_BENCH_FIXTURE:-}" ]; then
    say "using real fixture: $HUSK_BENCH_FIXTURE"
    cp -R "$HUSK_BENCH_FIXTURE" "$base/node_modules"
  else
    make_fat_fixture "$base/node_modules" 40 40
  fi

  settle
  noise=$(noise_floor_kb "$WORK")
  free0=$(vol_free_kb "$WORK")
  say "husk: seeding worktree (store is cold)"
  fleet_husk "$base" 1 1
  settle
  free_seed=$(vol_free_kb "$WORK")
  seed_kb=$(consumed_kb "$free0" "$free_seed")
  if [ "$n" -gt 1 ]; then
    say "husk: $((n - 1)) more (store is warm)"
    fleet_husk "$base" 2 "$n"
  fi
  settle
  free2=$(vol_free_kb "$WORK")
  marginal_kb=$(consumed_kb "$free_seed" "$free2")

  store_kb=$(du -sk "$HUSK_STORE" 2>/dev/null | awk '{print $1}')
  store_lkb=$(du -sk --apparent-size "$HUSK_STORE" 2>/dev/null | awk '{print $1}') || store_lkb=""
  total_files=$(find "$base/../husk-1/node_modules" -type f 2>/dev/null | grep -c . || true)
  shared=$(count_shared "$base/../husk-1/node_modules")
  tool=$( cd "$base" && "$HUSK_BIN" compress --probe 2>/dev/null | sed -n 's/^compress=//p' )

  # Measured again at the end. A volume that was quiet going in and busy coming
  # out was not measuring husk for part of the run, and the report has to say so
  # rather than let a contaminated delta pass as a result.
  noise_after=$(noise_floor_kb "$WORK")

  out "worktrees=$n"
  out "compress_tool=${tool:-none}"
  out "noise_floor_mb=$(mb "$noise")"
  out "noise_floor_after_mb=$(mb "$noise_after")"
  # A delta smaller than the volume's own drift is not a small measurement, it
  # is no measurement. A NEGATIVE one is proof of that: free space went up while
  # husk was writing. Print the word, not a number that reads like a result.
  out "husk_seed_mb=$(delta_mb "$seed_kb" "$noise")"
  [ "$n" -gt 1 ] && out "husk_marginal_per_worktree_mb=$(delta_mb "$marginal_kb" "$noise" "$((n - 1))")"
  out "husk_total_mb=$(delta_mb $(( seed_kb + marginal_kb )) "$noise")"
  out "store_physical_mb=$(mb "${store_kb:-0}")"
  if [ -n "${store_lkb:-}" ]; then
    out "store_logical_mb=$(mb "$store_lkb")"
    [ "${store_kb:-0}" -gt 0 ] && \
      out "store_compression_ratio=$(awk -v a="$store_lkb" -v b="$store_kb" 'BEGIN { printf "%.1f", a/b }')"
  fi
  out "worktree_files=${total_files:-0}"
  out "worktree_files_shared=${shared:-0}"
  # The store numbers come from du, which counts blocks on the entry itself and
  # is unaffected by anything else happening on the volume. The volume deltas
  # are the fragile ones, so flag them rather than quietly trusting them.
  if [ "$noise_after" -gt "$noise" ] && [ "$noise_after" -gt $(( seed_kb / 20 )) ]; then
    out "volume_quiet=no"
    say "the volume was NOT quiet: treat the *_mb deltas as unmeasured, the store numbers still hold"
  else
    out "volume_quiet=yes"
  fi
}

# ---------- compression checks ----------
setup_compressible() { # -> $WORK/repo with a compressible node_modules, HUSK_STORE exported
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/husk-cmp.XXXXXX") || die "mktemp failed"
  export HUSK_STORE="$WORK/store"
  make_repo "$WORK/repo" "compress-check-v1"
  make_fat_fixture "$WORK/repo/node_modules" 20 10
}

probe_tool() { # -> the compression tool husk found here, or "none"
  ( cd "$WORK/repo" && "$HUSK_BIN" compress --probe 2>/dev/null ) | sed -n 's/^compress=//p'
}

kb_of() { du -sk "$1" 2>/dev/null | awk '{print $1; exit}'; }

sha_of() { # file -> a hash, whichever tool this box has
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | awk '{print $1}'
  else openssl sha256 < "$1" | awk '{print $NF}'; fi
}

compress_check() {
  local tool out_c before after n ratio sample sha1 sha2 src_kb wt_kb
  setup_compressible
  ( cd "$WORK/repo" && "$HUSK_BIN" add ../w1 w1 ) >/dev/null 2>&1 || die "compress-check: husk add failed"

  tool=$(probe_tool)
  out "compress_tool=${tool:-none}"
  if [ -z "$tool" ] || [ "$tool" = none ]; then
    # No compressor this filesystem accepts. That is a legitimate answer on
    # most volumes, and the check reports it rather than inventing a pass.
    out "compress_check=skipped"
    say "no store compression available here; nothing to check"
    return 0
  fi

  sample=$(find "$WORK/store" -name 'f0.js' -type f 2>/dev/null | head -1)
  [ -n "$sample" ] || die "compress-check: no sample file in the store"
  sha1=$(sha_of "$sample")
  src_kb=$(kb_of "$WORK/repo/node_modules")

  out_c=$( cd "$WORK/repo" && "$HUSK_BIN" compress ) || die "compress-check: husk compress failed"
  printf '%s\n' "$out_c" >&2
  n=$(printf '%s\n'      "$out_c" | sed -n 's/^compressed=//p')
  before=$(printf '%s\n' "$out_c" | sed -n 's/^physical_before_kb=//p')
  after=$(printf '%s\n'  "$out_c" | sed -n 's/^physical_after_kb=//p')
  ratio=$(printf '%s\n'  "$out_c" | sed -n 's/^ratio=//p')

  [ "${n:-0}" -ge 1 ]                    || die "compress-check: compressed 0 entries with $tool available"
  [ -n "${before:-}" ] && [ -n "${after:-}" ] || die "compress-check: no physical bytes reported"
  [ "$after" -lt "$before" ]             || die "compress-check: physical size did not drop ($before -> $after KB)"

  sha2=$(sha_of "$sample")
  [ "$sha1" = "$sha2" ]                  || die "compress-check: file contents changed under compression"
  diff -r "$WORK/repo/node_modules" "$WORK/w1/node_modules" >/dev/null 2>&1 \
    || die "compress-check: worktree no longer matches the source tree"

  # Idempotent: a second pass must not fail, and must not claim new savings
  # on entries it already compressed.
  ( cd "$WORK/repo" && "$HUSK_BIN" compress ) >/dev/null 2>&1 \
    || die "compress-check: second compress pass failed (not idempotent)"

  wt_kb=$(kb_of "$WORK/w1/node_modules")
  out "physical_before_kb=$before"
  out "physical_after_kb=$after"
  out "ratio=${ratio:-unmeasured}"
  out "source_tree_kb=${src_kb:-0}"
  out "worktree_tree_kb=${wt_kb:-0}"
  out "compress_check=ok"
  say "compress-check ok: $n entries, $before -> $after KB (${ratio:-?}:1) with $tool, contents unchanged"
}

inherit_check() {
  local tool files shared src_kb wt_kb
  setup_compressible

  tool=$( cd "$WORK/repo" && HUSK_COMPRESS=1 "$HUSK_BIN" compress --probe 2>/dev/null | sed -n 's/^compress=//p' )
  out "compress_tool=${tool:-none}"
  if [ -z "$tool" ] || [ "$tool" = none ]; then
    out "inherit_check=skipped"
    say "no store compression available here; nothing to inherit"
    return 0
  fi

  # Seed WITH compression, then provision. The point being proved is that the
  # worktree costs compressed bytes without husk compressing the worktree:
  # a hardlink shares the file record, and the compression rides along.
  ( cd "$WORK/repo" && HUSK_COMPRESS=1 "$HUSK_BIN" add ../w1 w1 ) >/dev/null 2>&1 \
    || die "inherit-check: husk add failed"

  files=$(find "$WORK/w1/node_modules" -type f 2>/dev/null | grep -c . || true)
  shared=$(count_shared "$WORK/w1/node_modules")
  [ "${files:-0}" -gt 0 ] || die "inherit-check: worktree has no files"
  [ "${shared:-0}" -eq "${files:-0}" ] \
    || die "inherit-check: only $shared/$files files shared, so nothing could inherit"

  src_kb=$(kb_of "$WORK/repo/node_modules")   # same content, never compressed
  wt_kb=$(kb_of "$WORK/w1/node_modules")
  out "worktree_files=$files"
  out "worktree_files_shared=$shared"
  out "source_tree_kb=${src_kb:-0}"
  out "worktree_tree_kb=${wt_kb:-0}"
  [ "${wt_kb:-0}" -lt "${src_kb:-0}" ] \
    || die "inherit-check: worktree costs ${wt_kb} KB against an uncompressed ${src_kb} KB, so it did not inherit"

  diff -r "$WORK/repo/node_modules" "$WORK/w1/node_modules" >/dev/null 2>&1 \
    || die "inherit-check: compressed worktree does not match the source tree"
  out "inherit_check=ok"
  say "inherit-check ok: $shared/$files shared, ${wt_kb} KB against an uncompressed ${src_kb} KB, contents identical"
}

health_check() {
  local tool doc lst residue files shared
  setup_compressible
  ( cd "$WORK/repo" && HUSK_COMPRESS=1 "$HUSK_BIN" add ../w1 w1 ) >/dev/null 2>&1 \
    || die "health: husk add failed"

  tool=$(probe_tool)
  if [ -n "$tool" ] && [ "$tool" != none ]; then
    ( cd "$WORK/repo" && "$HUSK_BIN" compress ) >/dev/null 2>&1 || die "health: husk compress failed"
  fi
  out "compress_tool=${tool:-none}"

  # doctor must be clean on a store that has been through the whole path
  doc=$( cd "$WORK/repo" && "$HUSK_BIN" doctor ) || die "health: husk doctor exited non-zero"
  printf '%s\n' "$doc" | grep -q '^doctor ok=1$' \
    || { printf '%s\n' "$doc" >&2; die "health: doctor found issues after the compressed path"; }

  # list must still describe the store, and must describe it physically
  lst=$( cd "$WORK/repo" && "$HUSK_BIN" list ) || die "health: husk list exited non-zero"
  printf '%s\n' "$lst" | grep -q 'physical' \
    || { printf '%s\n' "$lst" >&2; die "health: list does not report physical size"; }

  # no residue: staging dirs and locks are removed on the way out
  residue=$(find "$WORK/store" \( -name '*.tmp.*' -o -name '*.lock' -o -name '*.husk-dd.*' \) 2>/dev/null | grep -c . || true)
  [ "${residue:-0}" -eq 0 ] || { find "$WORK/store" \( -name '*.tmp.*' -o -name '*.lock' \) >&2; die "health: $residue residue entries left in the store"; }

  files=$(find "$WORK/w1/node_modules" -type f 2>/dev/null | grep -c . || true)
  shared=$(count_shared "$WORK/w1/node_modules")
  [ "${shared:-0}" -eq "${files:-0}" ] && [ "${files:-0}" -gt 0 ] \
    || die "health: only $shared/$files worktree files shared after compression"
  diff -r "$WORK/repo/node_modules" "$WORK/w1/node_modules" >/dev/null 2>&1 \
    || die "health: worktree content diverged from the source tree"

  out "doctor=ok"
  out "residue=0"
  out "worktree_files=$files"
  out "worktree_files_shared=$shared"
  out "health=ok"
  say "health ok: doctor clean, no residue, $shared/$files shared, contents identical (compress: ${tool:-none})"
}

main() {
  case "${1:---self-test}" in
    --self-test)      self_test ;;
    --baseline)       run_bench 40 40 "${2:-$BENCH_N}" ;;
    --after)          run_after "${2:-$BENCH_N}" ;;
    --compress-check) compress_check ;;
    --inherit-check)  inherit_check ;;
    --health)         health_check ;;
    -h|--help)        sed -n '5,16p' "$0" ;;
    *)                die "unknown argument: $1 (try --help)" ;;
  esac
}

main "$@"
