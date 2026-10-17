#!/bin/bash
# Test suite for zfsb. Runs the engine (and the real vendored sanoid) against
# fake zfs/docker/virsh/emcmd commands in a throwaway sandbox under /tmp.
#
# Needs Linux with bash 5, GNU find, jq, rsync and perl with Config::IniFiles +
# Capture::Tiny (an Unraid box with the plugin's deps installed qualifies).
#
#   bash tests/run-tests.sh            run everything
#   bash tests/run-tests.sh convert    run tests whose name matches "convert"
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
PLUGIN_DIR="$ROOT/src/usr/local/emhttp/plugins/zfs.backups"
ENGINE="$PLUGIN_DIR/scripts/zfsb"
FILTER="${1-}"
PASS=0; FAIL=0; FAILED=()

# --------------------------------------------------------------------------- sandbox
setup() {
  SB=$(mktemp -d /tmp/zfsb-test.XXXXXX)
  export ZFSMOCK="$SB/mock"; mkdir -p "$ZFSMOCK"
  export PATH="$HERE/mocks:$ORIG_PATH"
  # SAFETY: never let a test reach the real zfs / docker / virsh
  local b
  for b in zfs docker virsh; do
    [[ $(command -v $b) == "$HERE/mocks/$b" ]] || { echo "SAFETY ABORT: '$b' resolves to $(command -v $b), not the mock"; exit 99; }
  done
  export ZFSB_CFG_DIR="$SB/cfg" ZFSB_STATE_DIR="$SB/state" ZFSB_LOG_DIR="$SB/log" ZFSB_EMHTTP="$PLUGIN_DIR"
  export ZFSB_NOTIFY="$HERE/mocks/notify" ZFSB_EMCMD="$HERE/mocks/emcmd" ZFSB_UPDATE_CRON="$HERE/mocks/update_cron"
  export ZFSB_SYNCOID="$HERE/mocks/syncoid" ZFSB_DISKS_INI="$ZFSMOCK/disks.ini" ZFSB_LOCK="$SB/lock"
  export ZFSB_MNT="$SB/mnt" ZFSB_SPINUP_TIMEOUT=4 ZFSB_CONFLICT_FILES="$SB/none"
  mkdir -p "$ZFSB_CFG_DIR/jobs" "$SB/mnt"
  : > "$ZFSMOCK/calls.log"
}
# KEEP=1 bash tests/run-tests.sh <name>   keeps the sandbox for debugging
teardown() { unset ZFSMOCK_FAIL; [[ -n ${KEEP-} ]] && { echo "    sandbox kept: $SB"; return; }; rm -rf "$SB"; }
ORIG_PATH=$PATH

zfsb() { bash "$ENGINE" "$@"; }

# add_ds <name> [avail-bytes]   - mountpoint is $SB/mnt/<name>
add_ds() {
  mkdir -p "$SB/mnt/$1"
  printf '%s\t%s\t%s\n' "$1" "$SB/mnt/$1" "${2:-100000000000}" >> "$ZFSMOCK/datasets"
}
# add_snap <dataset> <type> <age-seconds>   - sanoid-style name
add_snap() {
  local epoch=$(( $(date +%s) - $3 ))
  printf '%s@autosnap_%s_%s\t%s\n' "$1" "$(date -d "@$epoch" +%Y-%m-%d_%H:%M:%S)" "$2" "$epoch" >> "$ZFSMOCK/snapshots"
}
# job <id> KEY=value...
job() {
  local id=$1; shift
  { echo "NAME=\"$id\""; local kv; for kv in "$@"; do echo "${kv%%=*}=\"${kv#*=}\""; done; } > "$ZFSB_CFG_DIR/jobs/$id.cfg"
}
snaps_of() { awk -F'\t' -v d="$1" 'index($1, d"@")==1 {print $1}' "$ZFSMOCK/snapshots"; }
count()    { grep -c . <<< "$1"; }
calls()    { cat "$ZFSMOCK/calls.log"; }

# --------------------------------------------------------------------------- asserts
CUR=""
ok() { # <description> <command...>
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$CUR: $d"); echo "    FAIL: $d"; fi
}
eq() { # <description> <expected> <actual>
  if [[ $2 == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$CUR: $1"); echo "    FAIL: $1 - expected [$2] got [$3]"; fi
}
has()    { grep -qF -- "$2" <<< "$1"; }
hasnt()  { ! grep -qF -- "$2" <<< "$1"; }

t() { # <name> <function>
  [[ -n $FILTER && $1 != *$FILTER* ]] && return
  CUR=$1; echo "- $1"
  setup; "$2"; teardown
}

# =========================================================================== tests

test_config_reader_is_strict() {
  cat > "$SB/x.cfg" <<'EOF'
# comment
NAME="Has spaces"
EVIL="$(touch SBDIR/pwned)"
lower="ignored"
DATASETS="a/b c/d"
EOF
  sed -i "s|SBDIR|$SB|" "$SB/x.cfg"
  local out
  out=$(source "$ENGINE"; declare -A X; load_cfg "$SB/x.cfg" X; echo "${X[NAME]}|${X[DATASETS]}|${X[EVIL]}|${X[lower]-unset}")
  eq "values parsed and quotes stripped" 'Has spaces|a/b c/d|$(touch '"$SB"'/pwned)|unset' "$out"
  ok "config values are never executed" test ! -e "$SB/pwned"
}

test_sanoid_config_recursive_with_excludes() {
  add_ds pool/appdata; add_ds pool/appdata/plex; add_ds pool/appdata/sonarr; add_ds pool/appdata/tmp; add_ds pool/appdata/tmp/cache
  job apps DATASETS=pool/appdata RECURSIVE=yes EXCLUDE=pool/appdata/tmp DAILY=7 WEEKLY=4 MONTHLY=3
  local conf
  conf=$(source "$ENGINE"; load_job apps; write_sanoid_config "$SB/sc"; cat "$SB/sc/sanoid.conf")
  ok "parent has its own section" has "$conf" "[pool/appdata]"
  ok "child plex has a section"   has "$conf" "[pool/appdata/plex]"
  ok "excluded child skipped"     hasnt "$conf" "[pool/appdata/tmp]"
  ok "excluded grandchild skipped" hasnt "$conf" "[pool/appdata/tmp/cache]"
  ok "no sanoid recursion used"   hasnt "$conf" "recursive"
  for k in "frequently = 0" "hourly = 0" "daily = 7" "weekly = 4" "monthly = 3" "yearly = 0"; do
    ok "template sets '$k' explicitly" has "$conf" "$k"
  done
  ok "defaults file copied" test -f "$SB/sc/sanoid.defaults.conf"
}

test_sanoid_config_atomic_zfs_recursion() {
  add_ds disk1/ANIME; add_ds disk1/ANIME/sub
  job media DATASETS=disk1/ANIME RECURSIVE=zfs DAILY=2
  local conf
  conf=$(source "$ENGINE"; load_job media; write_sanoid_config "$SB/sc"; cat "$SB/sc/sanoid.conf")
  ok "uses recursive = zfs" has "$conf" "recursive = zfs"
  ok "children not listed separately" hasnt "$conf" "[disk1/ANIME/sub]"
}

test_run_takes_and_prunes_per_retention() {
  add_ds pool/appdata; add_ds pool/appdata/plex
  for ds in pool/appdata pool/appdata/plex; do
    add_snap $ds daily $((86400*1+60)); add_snap $ds daily $((86400*2+60)); add_snap $ds daily $((86400*3+60))
  done
  printf 'pool/appdata/plex@2026-05-07-221614\t%s\n' $(( $(date +%s) - 86400*100 )) >> "$ZFSMOCK/snapshots"
  job apps DATASETS=pool/appdata RECURSIVE=yes DAILY=2 WEEKLY=0 MONTHLY=0
  zfsb run apps > "$SB/out" 2>&1; local rc=$?
  eq "run exits 0" 0 $rc
  local plex; plex=$(snaps_of pool/appdata/plex | grep autosnap_)
  eq "plex keeps exactly 2 dailies" 2 "$(count "$plex")"
  ok "the 3-day-old daily was pruned" bash -c "! grep -q '$(date -d @$(( $(date +%s) - 86400*3-60 )) +%Y-%m-%d)' <<< '$plex'"
  ok "manual (non-autosnap) snapshot untouched" has "$(snaps_of pool/appdata/plex)" "@2026-05-07-221614"
  local st; st=$(cat "$ZFSB_STATE_DIR/status/apps.json")
  eq "status: success" success "$(jq -r .state <<< "$st")"
  eq "status: 2 taken" 2 "$(jq -r .taken <<< "$st")"
  eq "status: 4 pruned" 4 "$(jq -r .pruned <<< "$st")"
  ok "status persisted to flash dir" test -f "$ZFSB_CFG_DIR/status/apps.json"
  ok "success notification sent" has "$(calls)" "-i normal"
}

test_exclude_gets_no_snapshot() {
  add_ds pool/appdata; add_ds pool/appdata/keep; add_ds pool/appdata/skip
  job apps DATASETS=pool/appdata RECURSIVE=yes EXCLUDE=pool/appdata/skip DAILY=3
  zfsb run apps >/dev/null 2>&1
  eq "kept child snapshotted" 1 "$(count "$(snaps_of pool/appdata/keep)")"
  eq "excluded child not snapshotted" 0 "$(snaps_of pool/appdata/skip | grep -c .)"
}

test_media_job_daily_one() {
  add_ds disk1; add_ds disk1/ANIME
  add_snap disk1/ANIME daily $((86400+60))
  job media DATASETS=disk1/ANIME RECURSIVE=yes DAILY=1
  zfsb run media >/dev/null 2>&1
  local s; s=$(snaps_of disk1/ANIME)
  eq "media keeps a single daily after a run" 1 "$(count "$s")"
}

test_overlapping_jobs_refused() {
  add_ds pool/appdata; add_ds pool/appdata/plex
  job a DATASETS=pool/appdata RECURSIVE=yes DAILY=7
  job b DATASETS=pool/appdata/plex RECURSIVE=no DAILY=1
  zfsb run b > "$SB/out" 2>&1; local rc=$?
  eq "overlapping job fails" 1 $rc
  ok "error names the overlap" grep -q "is in both job" "$SB/out"
  eq "no snapshot taken" 0 "$(grep -c '^zfs snapshot' "$ZFSMOCK/calls.log")"
  eq "status: failed" failed "$(jq -r .state "$ZFSB_STATE_DIR/status/b.json")"
  ok "failure notification sent" has "$(calls)" "-i alert"
}

test_disabled_job_does_not_count_as_overlap() {
  add_ds pool/appdata
  job a DATASETS=pool/appdata ENABLED=no DAILY=7
  job b DATASETS=pool/appdata DAILY=1
  zfsb run b >/dev/null 2>&1
  eq "runs fine when the other job is disabled" 0 $?
}

test_dry_run_changes_nothing() {
  add_ds pool/appdata
  add_snap pool/appdata daily $((86400*10))
  add_snap pool/appdata daily $((86400*11))
  job apps DATASETS=pool/appdata DAILY=1 REPL_METHOD=zfs REPL_TARGET=backup/apps
  add_ds backup
  zfsb run apps --dry-run > "$SB/out" 2>&1
  ok "no zfs snapshot/destroy/create calls" bash -c "! grep -E '^zfs (snapshot|destroy|create)' '$ZFSMOCK/calls.log'"
  ok "syncoid not executed" bash -c "! grep -q '^syncoid' '$ZFSMOCK/calls.log'"
  ok "reports what it would take" grep -q "taking snapshot pool/appdata@" "$SB/out"
  ok "reports what it would prune" grep -q "INFO: pruning pool/appdata@" "$SB/out"
  eq "status flags dry run" true "$(jq -r .dry_run "$ZFSB_STATE_DIR/status/apps.json")"
}

test_invalid_retention_and_missing_dataset() {
  job bad DATASETS="nope/missing" DAILY=abc
  zfsb run bad > "$SB/out" 2>&1
  eq "invalid job fails" 1 $?
  ok "missing dataset reported" grep -q "does not exist" "$SB/out"
  ok "bad number reported" grep -q "whole number" "$SB/out"
  job zero DATASETS="nope/missing" DAILY=0
  add_ds pool/x; job zero DATASETS=pool/x
  zfsb run zero > "$SB/out" 2>&1
  ok "all-zero retention refused" grep -q "keeps nothing" "$SB/out"
}

disks_ini() { # <disk>=<spundown>...
  local kv; : > "$ZFSMOCK/disks.ini"
  for kv in "$@"; do printf '["%s"]\nname="%s"\nspundown="%s"\n' "${kv%=*}" "${kv%=*}" "${kv#*=}" >> "$ZFSMOCK/disks.ini"; done
}

test_wake_only_needed_spun_down_disks() {
  disks_ini disk1=1 disk2=0 disk3=1
  add_ds disk1/ANIME; add_ds disk2/TV; add_ds pool/appdata
  job media DATASETS="disk1/ANIME disk2/TV" DAILY=1
  zfsb run media > "$SB/out" 2>&1
  ok "spins up disk1 via emcmd" has "$(calls)" "emcmd cmdSpinup=disk1"
  ok "leaves already-spinning disk2 alone" hasnt "$(calls)" "cmdSpinup=disk2"
  ok "does not touch unrelated disk3" hasnt "$(calls)" "cmdSpinup=disk3"
  ok "spin-up happens before snapshots" bash -c "grep -nE '^(emcmd|zfs snapshot)' '$ZFSMOCK/calls.log' | head -1 | grep -q emcmd"
  ok "logs disks awake" grep -q "all disks awake" "$SB/out"
}

test_no_wake_for_pool_jobs_or_when_disabled() {
  disks_ini disk1=1
  add_ds pool/appdata; add_ds disk1/ANIME
  job apps DATASETS=pool/appdata DAILY=1
  job media DATASETS=disk1/ANIME DAILY=1 WAKE_DISKS=no
  zfsb run apps >/dev/null 2>&1; zfsb run media >/dev/null 2>&1
  ok "no emcmd calls" hasnt "$(calls)" "emcmd"
}

test_spinup_timeout_is_a_warning_not_failure() {
  disks_ini disk1=1
  add_ds disk1/ANIME
  job media DATASETS=disk1/ANIME DAILY=1
  # an emcmd that does nothing: disk never reports spun up
  export ZFSB_EMCMD=/bin/true
  zfsb run media > "$SB/out" 2>&1
  eq "run still succeeds" 0 $?
  eq "status: warning" warning "$(jq -r .state "$ZFSB_STATE_DIR/status/media.json")"
  eq "snapshot still taken" 1 "$(count "$(snaps_of disk1/ANIME)")"
}

test_replication_runs_between_snapshot_and_prune() {
  add_ds pool/appdata; add_ds pool/appdata/plex; add_ds disk6; add_ds disk6/BACKUPS
  add_snap pool/appdata/plex daily $((86400*5)); add_snap pool/appdata/plex daily $((86400*6))
  disks_ini disk6=1
  job apps DATASETS=pool/appdata RECURSIVE=yes EXCLUDE=pool/appdata/x DAILY=1 REPL_METHOD=zfs REPL_TARGET=disk6/BACKUPS/zfsb
  add_ds pool/appdata/x
  zfsb run apps > "$SB/out" 2>&1
  local order; order=$(grep -nE '^(zfs snapshot|syncoid|zfs destroy)' "$ZFSMOCK/calls.log" | cut -d: -f2 | awk '{print $1}' | uniq | tr '\n' ' ')
  eq "order is snapshot -> syncoid -> destroy" "zfs syncoid zfs " "$order"
  ok "target parent created" has "$(calls)" "zfs create -p disk6/BACKUPS/zfsb"
  local sc; sc=$(grep '^syncoid' "$ZFSMOCK/calls.log")
  ok "syncoid recursive" has "$sc" " -r"
  ok "syncoid uses --no-sync-snap" has "$sc" "--no-sync-snap"
  ok "syncoid keeps a bookmark" has "$sc" "--create-bookmark"
  ok "strict mirror by default" has "$sc" "--delete-target-snapshots"
  ok "exclude passed to syncoid" has "$sc" "--exclude-datasets=^pool/appdata/x(/|\$)"
  ok "destination named pool_dataset" has "$sc" "pool/appdata disk6/BACKUPS/zfsb/pool_appdata"
  ok "target array disk woken too" has "$(calls)" "cmdSpinup=disk6"
}

test_remote_replication_args() {
  add_ds pool/appdata
  job apps DATASETS=pool/appdata RECURSIVE=no DAILY=1 REPL_METHOD=zfs REPL_TARGET=tank/backups \
      REPL_HOST=192.0.2.10 REPL_PORT=2222 REPL_ZFS_MODE=basic
  local out; out=$(source "$ENGINE"; DRY_RUN=yes; load_job apps; replicate_zfs)
  ok "remote target in user@host:dataset form" has "$out" "root@192.0.2.10:tank/backups/pool_appdata"
  ok "ssh port passed" has "$out" "--sshport=2222"
  ok "basic mode does not delete target snapshots" hasnt "$out" "--delete-target-snapshots"
  ok "non-recursive job not sent with -r" hasnt "$out" " -r "
}

test_rsync_incremental_and_keep() {
  add_ds pool/docs; add_ds pool/docs/sub
  echo hello > "$SB/mnt/pool/docs/a.txt"; echo world > "$SB/mnt/pool/docs/sub/b.txt"
  # the mock can't expose .zfs/snapshot, so point the temp snapshot path at live data
  mkdir -p "$SB/mnt/pool/docs/.zfs/snapshot" "$SB/mnt/pool/docs/sub/.zfs/snapshot"
  ln -s "$SB/mnt/pool/docs" "$SB/mnt/pool/docs/.zfs/snapshot/zfsb_rsync_tmp"
  ln -s "$SB/mnt/pool/docs/sub" "$SB/mnt/pool/docs/sub/.zfs/snapshot/zfsb_rsync_tmp"
  mkdir -p "$SB/backup/pool_docs/2020-01-01_0000" "$SB/backup/pool_docs/2020-01-02_0000" "$SB/backup/pool_docs/2020-01-03_0000"
  job docs DATASETS=pool/docs RECURSIVE=yes DAILY=1 REPL_METHOD=rsync REPL_TARGET="$SB/backup" REPL_RSYNC_KEEP=2
  zfsb run docs > "$SB/out" 2>&1
  local newest; newest=$(ls -1 "$SB/backup/pool_docs" | sort | tail -1)
  ok "new dated copy has parent file" test -f "$SB/backup/pool_docs/$newest/a.txt"
  ok "child dataset copied into its subfolder" test -f "$SB/backup/pool_docs/$newest/sub/b.txt"
  eq "keeps only newest 2 copies" 2 "$(ls -1 "$SB/backup/pool_docs" | wc -l)"
  ok "hard-link base used" grep -q "hard-linked against 2020-01-03_0000" "$SB/out"
  ok "temp snapshots cleaned up" bash -c "! grep -q 'zfsb_rsync_tmp' <(cut -f1 '$ZFSMOCK/snapshots')"
}

# ---- converter ----
convert_fixture() {
  add_ds pool/appdata
  add_ds pool/appdata/already
  mkdir -p "$SB/mnt/pool/appdata/newapp/config" "$SB/mnt/pool/appdata/my app"
  echo data > "$SB/mnt/pool/appdata/newapp/config/settings.xml"
  echo x > "$SB/mnt/pool/appdata/newapp/db.sqlite"
  mkdir -p "$SB/mnt/user"; ln -s "$SB/mnt/pool/appdata" "$SB/mnt/user/appdata"
  printf 'c1\tnewapp\t1\t%s\nc2\tother\t1\t%s\n' "$SB/mnt/user/appdata/newapp/config" "$SB/mnt/pool/appdata/already" > "$ZFSMOCK/containers"
  cat > "$ZFSB_CFG_DIR/convert.cfg" <<EOF
ENABLED="yes"
PARENTS="pool/appdata"
STOP_CONTAINERS="yes"
MODE="before_jobs"
EOF
}

test_convert_folder_to_dataset() {
  convert_fixture
  zfsb convert > "$SB/out" 2>&1
  eq "convert exits 0" 0 $?
  ok "dataset created" has "$(cut -f1 "$ZFSMOCK/datasets")" "pool/appdata/newapp"
  ok "files preserved" test -f "$SB/mnt/pool/appdata/newapp/config/settings.xml"
  ok "temp folder removed" test ! -e "$SB/mnt/pool/appdata/newapp_zfsb_tmp"
  ok "container using it was stopped" has "$(calls)" "docker stop c1"
  ok "and started again" has "$(calls)" "docker start newapp"
  ok "unrelated container not stopped" hasnt "$(calls)" "docker stop c2"
  ok "folder with space skipped with warning" grep -q "skipping 'my app'" "$SB/out"
  ok "space folder left alone" test -d "$SB/mnt/pool/appdata/my app"
}

test_convert_dry_run() {
  convert_fixture
  zfsb convert --dry-run > "$SB/out" 2>&1
  ok "no dataset created" hasnt "$(cut -f1 "$ZFSMOCK/datasets")" "pool/appdata/newapp"
  ok "no container stopped" hasnt "$(calls)" "docker stop"
  ok "reports plan" grep -q "would convert" "$SB/out"
  ok "folder untouched" test -f "$SB/mnt/pool/appdata/newapp/db.sqlite"
}

test_convert_rolls_back_on_failure() {
  convert_fixture
  # make the copy step fail: a fake rsync first in PATH
  mkdir -p "$SB/bin"; printf '#!/bin/bash\nexit 23\n' > "$SB/bin/rsync"; chmod +x "$SB/bin/rsync"
  PATH="$SB/bin:$PATH" bash "$ENGINE" convert > "$SB/out" 2>&1
  eq "convert reports failure" 1 $?
  ok "original folder restored" test -f "$SB/mnt/pool/appdata/newapp/config/settings.xml"
  ok "no temp left" test ! -e "$SB/mnt/pool/appdata/newapp_zfsb_tmp"
  ok "half-made dataset destroyed" hasnt "$(cut -f1 "$ZFSMOCK/datasets")" "pool/appdata/newapp"
  ok "container restarted anyway" has "$(calls)" "docker start newapp"
}

test_convert_runs_before_snapshots_in_job() {
  convert_fixture
  job apps DATASETS=pool/appdata RECURSIVE=yes DAILY=7
  zfsb run apps > "$SB/out" 2>&1
  eq "job ok" 0 $?
  ok "converted dataset got tonight's snapshot" test "$(snaps_of pool/appdata/newapp | grep -c .)" -eq 1
  ok "conversion logged before snapshotting" bash -c "grep -n -e 'converting' -e 'Taking snapshots' '$SB/out' | head -1 | grep -q converting"
}

test_convert_not_enough_space() {
  convert_fixture
  head -c 4096 /dev/zero > "$SB/mnt/pool/appdata/newapp/blob"   # 4 KiB to copy, only 1 KiB free
  awk -F'\t' -v OFS='\t' '$1=="pool/appdata"{$3=1024} 1' "$ZFSMOCK/datasets" > "$ZFSMOCK/d" && mv "$ZFSMOCK/d" "$ZFSMOCK/datasets"
  zfsb convert > "$SB/out" 2>&1
  ok "refuses when space is short" grep -q "not enough space" "$SB/out"
  ok "folder untouched" test -f "$SB/mnt/pool/appdata/newapp/db.sqlite"
  ok "container not stopped for a folder that is skipped" hasnt "$(calls)" "docker stop"
}

two_app_fixture() {
  add_ds pool/appdata
  mkdir -p "$SB/mnt/pool/appdata/appA" "$SB/mnt/pool/appdata/appB"
  echo a > "$SB/mnt/pool/appdata/appA/a.conf"; echo b > "$SB/mnt/pool/appdata/appB/b.conf"
  printf 'ca\ta\t1\t%s\ncb\tb\t1\t%s\n' "$SB/mnt/pool/appdata/appA" "$SB/mnt/pool/appdata/appB/config" > "$ZFSMOCK/containers"
  printf 'ENABLED="yes"\nPARENTS="pool/appdata"\nSTOP_CONTAINERS="yes"\n' > "$ZFSB_CFG_DIR/convert.cfg"
}
line_of() { grep -nF -- "$1" "$ZFSMOCK/calls.log" | head -1 | cut -d: -f1; }

test_convert_one_folder_at_a_time() {
  two_app_fixture
  zfsb convert > "$SB/out" 2>&1
  eq "convert exits 0" 0 $?
  local sa sta sb stb
  sa=$(line_of "docker stop ca"); sta=$(line_of "docker start a"); sb=$(line_of "docker stop cb"); stb=$(line_of "docker start b")
  ok "a stopped, then restarted before b is stopped" test -n "$sa" -a -n "$sta" -a -n "$sb" -a -n "$stb" -a "$sa" -lt "$sta" -a "$sta" -lt "$sb" -a "$sb" -lt "$stb"
  ok "appA converted" has "$(cut -f1 "$ZFSMOCK/datasets")" "pool/appdata/appA"
  ok "appB converted" has "$(cut -f1 "$ZFSMOCK/datasets")" "pool/appdata/appB"
  ok "both containers running at the end" bash -c "! awk -F'\t' '\$3==0' '$ZFSMOCK/containers' | grep -q ."
}

test_convert_timeout_rolls_back() {
  two_app_fixture
  # a copy that hangs: exec so the timeout's signal reaches the sleeping process directly
  mkdir -p "$SB/bin"; printf '#!/bin/bash\nexec sleep 60\n' > "$SB/bin/rsync"; chmod +x "$SB/bin/rsync"
  local t0=$SECONDS
  PATH="$SB/bin:$PATH" ZFSB_FOLDER_TIMEOUT_SECS=2 bash "$ENGINE" convert > "$SB/out" 2>&1
  local rc=$? took=$(( SECONDS - t0 ))
  eq "reports failure" 1 $rc
  ok "gave up quickly instead of hanging (took ${took}s)" test $took -lt 20
  ok "timeout reported" grep -q "did not finish within" "$SB/out"
  ok "appA folder restored" test -f "$SB/mnt/pool/appdata/appA/a.conf"
  ok "appB folder restored" test -f "$SB/mnt/pool/appdata/appB/b.conf"
  ok "no temp folders left" bash -c "! ls -d '$SB'/mnt/pool/appdata/*_zfsb_tmp 2>/dev/null | grep -q ."
  ok "half-made datasets destroyed" hasnt "$(cut -f1 "$ZFSMOCK/datasets")" "pool/appdata/app"
  ok "containers restarted" bash -c "grep -q 'docker start a' '$ZFSMOCK/calls.log' && grep -q 'docker start b' '$ZFSMOCK/calls.log'"
}

test_convert_timeout_setting_in_minutes() {
  convert_fixture
  echo 'FOLDER_TIMEOUT="7"' >> "$ZFSB_CFG_DIR/convert.cfg"
  zfsb convert > "$SB/out" 2>&1
  ok "limit from config is used" grep -q "time limit 7 min" "$SB/out"
  printf 'ENABLED="yes"\nPARENTS="pool/appdata"\nFOLDER_TIMEOUT="0"\n' > "$ZFSB_CFG_DIR/convert.cfg"
  mkdir -p "$SB/mnt/pool/appdata/another"; echo x > "$SB/mnt/pool/appdata/another/f"
  zfsb convert > "$SB/out" 2>&1
  ok "0 means no limit" bash -c "grep -q 'converting.*another' '$SB/out' && ! grep -q 'time limit' '$SB/out'"
}

test_convert_skips_in_use_when_stopping_disabled() {
  convert_fixture
  sed -i 's/^STOP_CONTAINERS=.*/STOP_CONTAINERS="no"/' "$ZFSB_CFG_DIR/convert.cfg"
  zfsb convert > "$SB/out" 2>&1
  ok "folder in use is skipped" grep -q "skipping 'newapp': in use by container" "$SB/out"
  ok "container left running" hasnt "$(calls)" "docker stop"
  ok "not converted" hasnt "$(cut -f1 "$ZFSMOCK/datasets")" "pool/appdata/newapp"
}

test_convert_stop_failure_skips_folder() {
  convert_fixture
  ZFSMOCK_DOCKER_FAIL="stop c1" bash "$ENGINE" convert > "$SB/out" 2>&1
  ok "error reported" grep -q "could not stop container newapp - folder skipped" "$SB/out"
  ok "not converted while possibly in use" hasnt "$(cut -f1 "$ZFSMOCK/datasets")" "pool/appdata/newapp"
  ok "folder untouched" test -f "$SB/mnt/pool/appdata/newapp/db.sqlite"
}

test_convert_failure_in_job_is_warning() {
  convert_fixture
  mkdir -p "$SB/bin"; printf '#!/bin/bash\nexit 23\n' > "$SB/bin/rsync"; chmod +x "$SB/bin/rsync"
  job apps DATASETS=pool/appdata RECURSIVE=yes DAILY=7
  PATH="$SB/bin:$PATH" bash "$ENGINE" run apps > "$SB/out" 2>&1
  eq "job still succeeds overall" 0 $?
  eq "status: warning" warning "$(jq -r .state "$ZFSB_STATE_DIR/status/apps.json")"
  ok "summary counts the warnings" bash -c "jq -r .summary '$ZFSB_STATE_DIR/status/apps.json' | grep -q '2 warning(s)'"
  ok "warning notification names the failed conversion" bash -c "grep '^notify' '$ZFSMOCK/calls.log' | grep -- '-i warning' | grep -q 'dataset conversion: newapp: copy failed'"
  ok "snapshots still taken" test "$(snaps_of pool/appdata | grep -c .)" -eq 1
}

# ---- scheduling / misc ----
test_cron_generation() {
  add_ds pool/a
  job daily1 DATASETS=pool/a SCHEDULE=daily SCHEDULE_TIME=00:25
  job weekly1 DATASETS=pool/a SCHEDULE=weekly SCHEDULE_TIME=23:05 SCHEDULE_DOW=6
  job hourly1 DATASETS=pool/a SCHEDULE=hourly SCHEDULE_TIME=00:15
  job custom1 DATASETS=pool/a SCHEDULE=custom SCHEDULE_CRON="*/30 1-5 * * *"
  job evil DATASETS=pool/a SCHEDULE=custom SCHEDULE_CRON="* * * * * ; rm -rf /"
  job off DATASETS=pool/a SCHEDULE=daily ENABLED=no
  job manual DATASETS=pool/a SCHEDULE=disabled
  zfsb cron >/dev/null 2>&1
  local c; c=$(cat "$ZFSB_CFG_DIR/zfs.backups.cron")
  ok "daily"  has "$c" "25 0 * * * /usr/local/sbin/zfsb run daily1 --cron"
  ok "weekly" has "$c" "5 23 * * 6 /usr/local/sbin/zfsb run weekly1"
  ok "hourly" has "$c" "15 * * * * /usr/local/sbin/zfsb run hourly1"
  ok "custom" has "$c" "*/30 1-5 * * * /usr/local/sbin/zfsb run custom1"
  ok "injection-looking cron rejected" hasnt "$c" "rm -rf"
  ok "disabled job omitted" hasnt "$c" "run off"
  ok "manual-only job omitted" hasnt "$c" "run manual"
  ok "update_cron called" has "$(calls)" "update_cron"
}

test_conflicts_detects_other_sanoid_configs() {
  add_ds disk1/ANIME
  job media DATASETS=disk1/ANIME DAILY=2
  printf '[disk1/ANIME]\n\tdaily = 1\n[template_x]\n' > "$SB/buddy.conf"
  ZFSB_CONFLICT_FILES="$SB/buddy.conf" bash "$ENGINE" conflicts > "$SB/out" 2>&1
  ok "conflict reported" grep -q "manages 'disk1/ANIME' (overlaps job 'media')" "$SB/out"
}

test_conflicts_ignore_inactive_leftovers() {
  add_ds disk1/ANIME; add_ds pool/appdata
  job media DATASETS=disk1/ANIME DAILY=2
  job apps DATASETS=pool/appdata DAILY=7
  mkdir -p "$SB/plugins" "$SB/emhttp/pool_appdata" "$SB/scripts/snap"
  printf '[disk1/ANIME]\n\tdaily = 1\n' > "$SB/buddy.conf"
  printf '[pool/appdata]\n\tdaily = 7\n' > "$SB/emhttp/pool_appdata/sanoid.conf"
  printf '#!/bin/bash\n/usr/local/sbin/sanoid --take-snapshots\n' > "$SB/scripts/snap/script"
  touch "$SB/plugins/user.scripts.plg"
  sched() { printf '{"%s": {"script": "%s", "frequency": "%s", "custom": ""}}\n' "$SB/scripts/snap/script" "$SB/scripts/snap/script" "$1" > "$SB/schedule.json"; }
  cf() { ZFSB_CONFLICT_FILES="" ZFSB_PLUGINS_LOG="$SB/plugins" ZFSB_BUDDY_CONF="$SB/buddy.conf" ZFSB_SANOID_CONF="$SB/none" \
         ZFSB_SIO_GLOB="$SB/emhttp/*/sanoid.conf" ZFSB_USERSCRIPTS_SCHEDULE="$SB/schedule.json" bash "$ENGINE" conflicts; }

  sched disabled
  eq "uninstalled BuddyBackup + unscheduled script: no conflicts" "No conflicts found." "$(cf)"
  touch "$SB/plugins/buddybackup.plg"
  ok "installed BuddyBackup is reported" has "$(cf)" "manages 'disk1/ANIME'"
  rm "$SB/plugins/buddybackup.plg"; sched custom
  ok "scheduled sanoid user script makes its config count" has "$(cf)" "manages 'pool/appdata'"
  printf '#!/bin/bash\necho hello\n' > "$SB/scripts/snap/script"
  eq "scheduled script that doesn't run sanoid is ignored" "No conflicts found." "$(cf)"
}

test_plan_is_read_only() {
  add_ds pool/appdata; add_snap pool/appdata daily $((86400*9))
  job apps DATASETS=pool/appdata DAILY=1 REPL_METHOD=zfs REPL_TARGET=backup/x
  zfsb plan apps > "$SB/out" 2>&1
  ok "plan lists datasets" grep -q "pool/appdata" "$SB/out"
  ok "plan simulates" grep -q "would take 1 snapshot" "$SB/out"
  ok "no changes made" bash -c "! grep -E '^zfs (snapshot|destroy|create)' '$ZFSMOCK/calls.log'"
}

# =========================================================================== run
t config_reader_is_strict                  test_config_reader_is_strict
t sanoid_config_recursive_with_excludes    test_sanoid_config_recursive_with_excludes
t sanoid_config_atomic_zfs_recursion       test_sanoid_config_atomic_zfs_recursion
t run_takes_and_prunes_per_retention       test_run_takes_and_prunes_per_retention
t exclude_gets_no_snapshot                 test_exclude_gets_no_snapshot
t media_job_daily_one                      test_media_job_daily_one
t overlapping_jobs_refused                 test_overlapping_jobs_refused
t disabled_job_does_not_count_as_overlap   test_disabled_job_does_not_count_as_overlap
t dry_run_changes_nothing                  test_dry_run_changes_nothing
t invalid_retention_and_missing_dataset    test_invalid_retention_and_missing_dataset
t wake_only_needed_spun_down_disks         test_wake_only_needed_spun_down_disks
t no_wake_for_pool_jobs_or_when_disabled   test_no_wake_for_pool_jobs_or_when_disabled
t spinup_timeout_is_a_warning              test_spinup_timeout_is_a_warning_not_failure
t replication_between_snapshot_and_prune   test_replication_runs_between_snapshot_and_prune
t remote_replication_args                  test_remote_replication_args
t rsync_incremental_and_keep               test_rsync_incremental_and_keep
t convert_folder_to_dataset                test_convert_folder_to_dataset
t convert_dry_run                          test_convert_dry_run
t convert_rolls_back_on_failure            test_convert_rolls_back_on_failure
t convert_runs_before_snapshots_in_job     test_convert_runs_before_snapshots_in_job
t convert_not_enough_space                 test_convert_not_enough_space
t convert_one_folder_at_a_time             test_convert_one_folder_at_a_time
t convert_timeout_rolls_back               test_convert_timeout_rolls_back
t convert_timeout_setting_in_minutes       test_convert_timeout_setting_in_minutes
t convert_skips_in_use_when_stopping_off   test_convert_skips_in_use_when_stopping_disabled
t convert_stop_failure_skips_folder        test_convert_stop_failure_skips_folder
t convert_failure_in_job_is_warning        test_convert_failure_in_job_is_warning
t cron_generation                          test_cron_generation
t conflicts_detects_other_sanoid_configs   test_conflicts_detects_other_sanoid_configs
t conflicts_ignore_inactive_leftovers      test_conflicts_ignore_inactive_leftovers
t plan_is_read_only                        test_plan_is_read_only

echo
echo "passed: $PASS   failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then printf '  %s\n' "${FAILED[@]}"; exit 1; fi
