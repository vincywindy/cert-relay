#!/usr/bin/env bash
# Run inside the built image with test-only openssl/curl installed.
# Check the actual TLS handshake and HTTP routing, not just file changes or log messages.
set -euo pipefail
scratch=$(mktemp -d)
supervisor=
cleanup() {
    [[ -z $supervisor ]] || { kill -TERM "$supervisor" 2>/dev/null || :; wait "$supervisor" 2>/dev/null || :; }
    rm -rf -- "$scratch"
}
trap cleanup EXIT
mkdir -p "$scratch/source-certs" "$scratch/source-dynamic"
make_cert() {
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=sync.test \
        -set_serial "$1" -keyout "$scratch/source-certs/key.pem" \
        -out "$scratch/source-certs/cert.pem" >/dev/null 2>&1
}
make_cert 1001
cat > "$scratch/source-dynamic/tls.yml" <<YAML
tls:
  certificates:
    - certFile: $scratch/local/certs/cert.pem
      keyFile: $scratch/local/certs/key.pem
YAML
cat > "$scratch/source-dynamic/routes.yml" <<'YAML'
http:
  routers:
    ping:
      rule: Path(`/old`)
      entryPoints: [web]
      service: ping@internal
YAML
export SYNC_PAIRS="$scratch/source-certs|$scratch/local/certs
$scratch/source-dynamic|$scratch/local/dynamic"
export SYNC_RELOAD_FILE=$scratch/local/dynamic/tls.yml
export SYNC_MIN_AGE_SECS=0 SYNC_INTERVAL_SECS=1 SYNC_STATE_DIR=$scratch/state
/usr/local/bin/cert-sync-entrypoint --entrypoints.web.address=127.0.0.1:18080 \
    --entrypoints.websecure.address=127.0.0.1:18443 \
    --providers.file.directory="$scratch/local/dynamic" --providers.file.watch=true \
    --ping=true --ping.manualrouting=true > "$scratch/traefik.log" 2>&1 & supervisor=$!
serial() {
    timeout 5 openssl s_client -connect 127.0.0.1:18443 -servername sync.test </dev/null 2>/dev/null |
        openssl x509 -noout -serial 2>/dev/null
}
await_serial() {
    for ((i=0;i<60;i++)); do
        if [[ $(serial || :) == "serial=$1" ]]; then return 0; fi
        sleep 1
    done
    cat "$scratch/traefik.log"; echo "serial $1 not served"; return 1
}
await_status() {
    for ((i=0;i<30;i++)); do
        if [[ $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:18080/$1" || :) == "$2" ]]; then return 0; fi
        sleep 1
    done
    cat "$scratch/traefik.log"; return 1
}
await_serial 03E9
await_status old 200
make_cert 1002
await_serial 03EA
sed -i 's@/old@/new@' "$scratch/source-dynamic/routes.yml"
await_status new 200
await_status old 404
/usr/local/bin/folder-sync-healthcheck
kill -TERM "$supervisor"
wait "$supervisor"
supervisor=
echo 'PASS actual Traefik certificate reload, dynamic routes reload and graceful supervisor shutdown'

# The supervisor must exit if synchronization dies; a healthy proxy alone is insufficient.
rm "$SYNC_STATE_DIR/worker.pid" "$SYNC_STATE_DIR/traefik.pid"
/usr/local/bin/cert-sync-entrypoint --entrypoints.web.address=127.0.0.1:18080 \
    --providers.file.directory="$scratch/local/dynamic" > "$scratch/restart.log" 2>&1 & supervisor=$!
for ((i=0;i<100;i++)); do
    [[ ! -s $SYNC_STATE_DIR/traefik.pid ]] || break
    sleep 0.1
done
read -r worker < "$SYNC_STATE_DIR/worker.pid"
read -r proxy < "$SYNC_STATE_DIR/traefik.pid"
kill -KILL "$worker"
result=0
wait "$supervisor" || result=$?
supervisor=
(( result != 0 ))
if kill -0 "$proxy" 2>/dev/null; then echo 'proxy survived sync failure'; exit 1; fi
echo 'PASS supervisor terminates Traefik when the sync worker fails'
