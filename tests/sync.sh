#!/bin/sh
set -eu
sync_script=${1:-/usr/local/bin/cert-sync}
root=$(mktemp -d "${TEST_TMPDIR:-/tmp}/cert-sync-test.XXXXXXXX")
trap 'rm -rf -- "$root"' EXIT
source_dir=$root/source\ files
mkdir -p "$source_dir" "$root/local"
export SYNC_STATE_DIR="$root/local/state"
export SYNC_DYNAMIC_FILE="$root/local/dynamic/cert-sync.yml"
export SYNC_MIN_AGE_SECS=10
export SYNC_IO_TIMEOUT_SECS=10

cert() {
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -keyout "$source_dir/$1.key" -out "$source_dir/$1.pem" \
        -subj "/CN=$1.example.test" -days 2 >/dev/null 2>&1
    touch -t 202001010000 "$source_dir/$1.key" "$source_dir/$1.pem"
}
run() {
    result=0
    "$sync_script" --once > "$root/log" 2>&1 || result=$?
    if [ "$result" -ne "$1" ]; then
        cat "$root/log" >&2
        echo "FAIL: expected status $1, got $result" >&2; exit 1
    fi
}
ok() { printf 'PASS: %s\n' "$1"; }
cert one
cert two
export SYNC_PAIRS
SYNC_PAIRS=$(jq -nc --arg src "$source_dir" \
    '[{name:"one",cert:($src+"/one.pem"),key:($src+"/one.key")},
      {name:"two",cert:($src+"/two.pem"),key:($src+"/two.key")}]')
original_pairs=$SYNC_PAIRS
run 0
[ "$(jq '.tls.certificates | length' "$SYNC_DYNAMIC_FILE")" -eq 2 ]
one_path=$(jq -r '.tls.certificates[0].certFile' "$SYNC_DYNAMIC_FILE")
cmp "$one_path" "$source_dir/one.pem"
ok 'multiple groups and source paths containing spaces'

stamp=$(stat -c '%i:%y' "$SYNC_DYNAMIC_FILE")
run 0
[ "$stamp" = "$(stat -c '%i:%y' "$SYNC_DYNAMIC_FILE")" ]
ok 'unchanged pairs do not replace dynamic configuration'

cp "$SYNC_DYNAMIC_FILE" "$root/saved-config"
touch "$source_dir/one.pem"
run 2
cmp "$root/saved-config" "$SYNC_DYNAMIC_FILE"
ok 'recent source keeps the previous version'
touch -t 209901010000 "$source_dir/one.pem"
run 2
cmp "$root/saved-config" "$SYNC_DYNAMIC_FILE"
ok 'future source timestamp is skipped'
touch -t 202001010000 "$source_dir/one.pem"

cp "$source_dir/two.key" "$source_dir/one.key"
touch -t 202001010000 "$source_dir/one.key"
run 2
cmp "$root/saved-config" "$SYNC_DYNAMIC_FILE"
ok 'mismatched certificate/key leaves the active configuration intact'

cert one
run 0
if cmp -s "$root/saved-config" "$SYNC_DYNAMIC_FILE"; then exit 1; fi
[ -s "$one_path" ]
ok 'renewal changes paths and retains old immutable files'

cp "$SYNC_DYNAMIC_FILE" "$root/saved-config"
cp "$source_dir/one.pem" "$root/saved-one"
printf 'broken PEM\n' > "$source_dir/one.pem"
touch -t 202001010000 "$source_dir/one.pem"
cert two
run 2
one_path=$(jq -r '.tls.certificates[0].certFile' "$SYNC_DYNAMIC_FILE")
two_path=$(jq -r '.tls.certificates[1].certFile' "$SYNC_DYNAMIC_FILE")
cmp "$one_path" "$root/saved-one"
cmp "$two_path" "$source_dir/two.pem"
ok 'a broken group does not block renewal of another group'

cp "$root/saved-one" "$source_dir/one.pem"
touch -t 202001010000 "$source_dir/one.pem"
run 0
cp "$SYNC_DYNAMIC_FILE" "$root/saved-config"
mv "$source_dir/one.pem" "$source_dir/one.offline"
run 2
cmp "$root/saved-config" "$SYNC_DYNAMIC_FILE"
ok 'unavailable NFS-style source keeps local certificates'
mv "$source_dir/one.offline" "$source_dir/one.pem"

SYNC_PAIRS=$(printf '%s' "$original_pairs" | jq -c '. + [{name:"missing",cert:"/absent/cert.pem",key:"/absent/key.pem"}]')
run 1
cmp "$root/saved-config" "$SYNC_DYNAMIC_FILE"
ok 'new uninitialized group does not remove previously published configuration'
SYNC_PAIRS=$original_pairs

SYNC_MAX_FILE_BYTES=1 run 2
cmp "$root/saved-config" "$SYNC_DYNAMIC_FILE"
ok 'oversized files are rejected'
SYNC_INTERVAL_SECS=0 run 64
SYNC_PAIRS='' run 64
SYNC_PAIRS='[]' run 64
SYNC_PAIRS="$original_pairs $original_pairs" run 64
SYNC_PAIRS='[{"name":"../escape","cert":"/a","key":"/b"}]' run 64
SYNC_PAIRS=$(printf '%s' "$original_pairs" | jq -c '. + [.[0]]') run 64
ok 'invalid settings and duplicate/unsafe names fail early'

# A competing process cannot concurrently mutate the local release pointers or dynamic config.
exec 8> "$SYNC_STATE_DIR/.sync.lock"
flock -n 8
run 75
flock -u 8
exec 8>&-
ok 'concurrent writers are excluded using a local lock'

# Simulate an NFS read that never returns by interposing cp for just one source.
mkdir "$root/bin"
real_cp=$(command -v cp)
cat > "$root/bin/cp" <<'SH'
#!/bin/sh
case "$*" in *one.pem*) sleep 30 ;; esac
exec "$TEST_REAL_CP" "$@"
SH
chmod +x "$root/bin/cp"
export TEST_REAL_CP="$real_cp"
cert two
PATH="$root/bin:$PATH" SYNC_IO_TIMEOUT_SECS=10 run 2
two_path=$(jq -r '.tls.certificates[1].certFile' "$SYNC_DYNAMIC_FILE")
cmp "$two_path" "$source_dir/two.pem"
ok 'per-group timeout allows the next group to update'

SYNC_PAIRS=$(printf '%s' "$original_pairs" | jq -c '[.[1]]')
run 0
[ "$(jq '.tls.certificates | length' "$SYNC_DYNAMIC_FILE")" -eq 1 ]
[ "$(jq -r '.tls.certificates[0].certFile' "$SYNC_DYNAMIC_FILE")" = "$two_path" ]
ok 'removing a configured group removes its dynamic entry only'

export SYNC_STATE_DIR="$root/empty/state"
export SYNC_DYNAMIC_FILE="$root/empty/dynamic/cert-sync.yml"
SYNC_PAIRS='[{"name":"missing","cert":"/absent/cert.pem","key":"/absent/key.pem"}]'
run 1
[ ! -e "$SYNC_DYNAMIC_FILE" ]
ok 'first boot without usable certificates fails without publishing an empty TLS config'
printf 'All sync behavior tests passed.\n'
