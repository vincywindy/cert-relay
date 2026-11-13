#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script=$root/scripts/folder-sync.sh
scratch=$(mktemp -d)
worker=
cleanup() {
    [[ -z $worker ]] || { kill "$worker" 2>/dev/null || :; wait "$worker" 2>/dev/null || :; }
    # mktemp supplies this private test-only directory; never derive deletion paths from user sync pairs.
    rm -rf -- "$scratch"
}
trap cleanup EXIT
export SYNC_MIN_AGE_SECS=0 SYNC_INTERVAL_SECS=3600 SYNC_IO_TIMEOUT_SECS=10
export SYNC_STATE_DIR=$scratch/state SYNC_RELOAD_FILE=
mkdir -p "$scratch/src certs/sub dir" "$scratch/src config" "$scratch/dst config" "$scratch/dst certs"
export SYNC_PAIRS="$scratch/src certs|$scratch/dst certs
$scratch/src config|$scratch/dst config"
count=0
pass() { ((count+=1)); printf 'PASS %s\n' "$*"; }
run() { bash "$script" once >"$scratch/log" 2>&1 || { cat "$scratch/log"; return 1; }; }
partial() {
    local result=0
    bash "$script" once >"$scratch/log" 2>&1 || result=$?
    [[ $result == 2 ]] || { cat "$scratch/log"; echo "expected partial exit 2, got $result"; exit 1; }
}

printf 'cert-v1' > "$scratch/src certs/sub dir/fullchain.pem"
printf 'http: {}\n' > "$scratch/src config/routes.yml"
printf 'keep me' > "$scratch/dst config/local-only.yml"
mkdir "$scratch/src config/empty"
run
cmp "$scratch/src certs/sub dir/fullchain.pem" "$scratch/dst certs/sub dir/fullchain.pem"
cmp "$scratch/src config/routes.yml" "$scratch/dst config/routes.yml"
[[ -d $scratch/dst\ config/empty && -f $scratch/dst\ config/local-only.yml ]]
pass 'multiple pairs, nested paths/spaces, empty directories and no deletion'

before=$(stat -c '%i|%y' "$scratch/dst config/routes.yml")
run
[[ $(stat -c '%i|%y' "$scratch/dst config/routes.yml") == "$before" ]]
grep -q 'copied=0' "$scratch/log"
pass 'unchanged scan does not replace files'

printf 'cert-v2' > "$scratch/src certs/sub dir/fullchain.pem"
touch -r "$scratch/dst certs/sub dir/fullchain.pem" "$scratch/src certs/sub dir/fullchain.pem"
run
grep -q 'cert-v2' "$scratch/dst certs/sub dir/fullchain.pem"
pass 'content mode detects different bytes with equal size and mtime'

printf 'cert-v3' > "$scratch/src certs/sub dir/fullchain.pem"
touch -r "$scratch/dst certs/sub dir/fullchain.pem" "$scratch/src certs/sub dir/fullchain.pem"
SYNC_COMPARE=metadata run
grep -q 'cert-v2' "$scratch/dst certs/sub dir/fullchain.pem"
run
pass 'metadata mode explicitly trades exact content detection for fewer reads'

printf young > "$scratch/src config/young.yml"
SYNC_MIN_AGE_SECS=10 partial
[[ ! -e $scratch/dst\ config/young.yml ]]
touch -d '1 minute ago' "$scratch/src config/young.yml"
SYNC_MIN_AGE_SECS=10 partial
[[ -f $scratch/dst\ config/young.yml ]]
pass '10 second source stability window and later retry'

printf changed > "$scratch/src config/young.yml"
touch -d '1 minute ago' "$scratch/src config/young.yml"
touch "$scratch/dst config/young.yml"
SYNC_MIN_AGE_SECS=10 partial
grep -q '^young$' "$scratch/dst config/young.yml"
run
pass 'recently modified target is protected'

touch -d 'tomorrow' "$scratch/src config/future.yml"
partial
[[ ! -e $scratch/dst\ config/future.yml ]]
rm "$scratch/src config/future.yml"
pass 'future timestamp is skipped'

mkdir "$scratch/outside"
printf external > "$scratch/outside/file"
ln -s "$scratch/outside" "$scratch/src config/link"
ln -s "$scratch/outside/file" "$scratch/dst config/blocked.yml"
printf overwrite > "$scratch/src config/blocked.yml"
printf independent > "$scratch/src config/good.yml"
mkfifo "$scratch/src config/pipe"
partial
grep -q external "$scratch/outside/file"
[[ ! -e $scratch/dst\ config/link && ! -e $scratch/dst\ config/pipe ]]
grep -q independent "$scratch/dst config/good.yml"
rm "$scratch/src config/link" "$scratch/dst config/blocked.yml" "$scratch/src config/blocked.yml" "$scratch/src config/pipe"
pass 'symlinks and FIFOs skipped; other files continue'

export SYNC_RELOAD_FILE=$scratch/dst\ config/routes.yml
before=$(stat -c '%i' "$SYNC_RELOAD_FILE")
printf cert-v4 > "$scratch/src certs/sub dir/fullchain.pem"
run
[[ $(stat -c '%i' "$SYNC_RELOAD_FILE") != "$before" ]]
cmp "$SYNC_RELOAD_FILE" "$scratch/src config/routes.yml"
grep -q event=reload_requested "$scratch/log"
before=$(stat -c '%i' "$SYNC_RELOAD_FILE")
run
[[ $(stat -c '%i' "$SYNC_RELOAD_FILE") == "$before" ]]
pass 'certificate-only update replaces existing dynamic config, unchanged scan does not trigger reload'

export SYNC_RELOAD_FILE=$scratch/dst\ config/missing.yml
printf cert-v5 > "$scratch/src certs/sub dir/fullchain.pem"
partial
[[ -e $SYNC_STATE_DIR/reload-pending ]]
printf 'http: {}\n' > "$SYNC_RELOAD_FILE"
run
[[ ! -e $SYNC_STATE_DIR/reload-pending ]]
pass 'failed reload remains pending and retries without new source changes'
export SYNC_RELOAD_FILE=

if SYNC_PAIRS="$scratch/src config|$scratch/src config/nested" bash "$script" check 2>/dev/null; then exit 1; fi
if SYNC_PAIRS="$scratch/src config|$scratch/dst config
$scratch/dst config|$scratch/other" bash "$script" check 2>/dev/null; then exit 1; fi
if SYNC_INTERVAL_SECS=oops bash "$script" check 2>/dev/null; then exit 1; fi
pass 'overlaps, cross-pair loops and invalid environment rejected'

printf preserve > "$scratch/dst config/fail.yml"
printf new > "$scratch/src config/fail.yml"
mkdir "$scratch/bin"
cat > "$scratch/bin/cp" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$scratch/bin/cp"
PATH="$scratch/bin:$PATH" partial
grep -q preserve "$scratch/dst config/fail.yml"
[[ -z $(find "$scratch/dst config" -name '.folder-sync-tmp.*' -print -quit) ]]
run
pass 'failed copy retains original target and removes temporary files'

real_cp=$(command -v cp)
cat > "$scratch/bin/cp" <<SH
#!/bin/bash
"$real_cp" "\$@" || exit
printf concurrent >> "$scratch/src config/fail.yml"
SH
chmod +x "$scratch/bin/cp"
printf newer > "$scratch/src config/fail.yml"
PATH="$scratch/bin:$PATH" partial
grep -qx new "$scratch/dst config/fail.yml"
run
pass 'source changing during copy is not published'

rm "$scratch/bin/cp"
cat > "$scratch/bin/sync" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$scratch/bin/sync"
printf before-flush > "$scratch/dst config/fail.yml"
printf after-flush > "$scratch/src config/fail.yml"
PATH="$scratch/bin:$PATH" partial
grep -qx before-flush "$scratch/dst config/fail.yml"
rm "$scratch/bin/sync"
run
pass 'flush failure preserves the previous target (deferred NFS write-error simulation)'

cat > "$scratch/bin/cmp" <<'SH'
#!/bin/sh
sleep 5
SH
chmod +x "$scratch/bin/cmp"
SYNC_IO_TIMEOUT_SECS=1 PATH="$scratch/bin:$PATH" partial
grep -q 'reason=comparison' "$scratch/log"
rm "$scratch/bin/cmp"
pass 'comparison timeout skips files instead of replacing them'

bash "$script" run > "$scratch/daemon.log" 2>&1 & worker=$!
for ((i=0;i<100;i++)); do
    if grep -q 'event=scan' "$scratch/daemon.log"; then break; fi
    sleep 0.1
done
grep -q 'event=scan' "$scratch/daemon.log"
if bash "$script" check 2>/dev/null; then echo 'lock failure'; exit 1; fi
kill -TERM "$worker"
wait "$worker"
worker=
bash "$script" check
pass 'single-worker lock, interruptible sleep and graceful shutdown'

printf '\n%s integration cases passed\n' "$count"
