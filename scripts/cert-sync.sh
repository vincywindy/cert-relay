#!/bin/sh
set -eu
umask 077

SYNC_INTERVAL_SECS=${SYNC_INTERVAL_SECS:-300}
SYNC_MIN_AGE_SECS=${SYNC_MIN_AGE_SECS:-10}
SYNC_IO_TIMEOUT_SECS=${SYNC_IO_TIMEOUT_SECS:-30}
SYNC_MAX_FILE_BYTES=${SYNC_MAX_FILE_BYTES:-1048576}
SYNC_STATE_DIR=${SYNC_STATE_DIR:-/var/lib/traefik-cert-sync}
SYNC_DYNAMIC_FILE=${SYNC_DYNAMIC_FILE:-/etc/traefik/dynamic/cert-sync.yml}
export SYNC_INTERVAL_SECS SYNC_MIN_AGE_SECS SYNC_IO_TIMEOUT_SECS
export SYNC_MAX_FILE_BYTES SYNC_STATE_DIR SYNC_DYNAMIC_FILE

log() { printf 'cert-sync: %s\n' "$*" >&2; }
fatal() { log "$*"; exit 64; }
integer() {
    case "$2" in ''|*[!0-9]*) fatal "$1 must be an integer" ;; esac
    [ "${#2}" -le 8 ] && [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] || fatal "$1 out of range ($3..$4)"
}

validate() {
    integer SYNC_INTERVAL_SECS "$SYNC_INTERVAL_SECS" 1 31536000
    integer SYNC_MIN_AGE_SECS "$SYNC_MIN_AGE_SECS" 0 31536000
    integer SYNC_IO_TIMEOUT_SECS "$SYNC_IO_TIMEOUT_SECS" 1 86400
    integer SYNC_MAX_FILE_BYTES "$SYNC_MAX_FILE_BYTES" 1 16777216
    # Reject control characters in paths; records stay JSON until decoded, preserving spaces and backslashes.
    printf '%s' "${SYNC_PAIRS:-}" | jq -es '
        def path: type == "string" and startswith("/") and
          (test("[[:cntrl:]]") | not) and
          (split("/") | all(. != ".."));
        length == 1 and (.[0] | type == "array" and length > 0 and length <= 256 and
        all(.[]; type == "object" and (keys | sort) == ["cert", "key", "name"] and
          (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")) and
          (.cert | path) and (.key | path)) and
        ((map(.name) | unique | length) == length))
    ' >/dev/null || fatal 'SYNC_PAIRS must be a JSON array of unique {name, cert, key} objects with absolute paths'
    for directory in "$SYNC_STATE_DIR" "$(dirname "$SYNC_DYNAMIC_FILE")"; do
        printf '%s' "$directory" | jq -eRs '
          startswith("/") and . != "/" and
          (test("[[:cntrl:]]") | not) and
          (split("/") | all(. != ".."))
        ' >/dev/null || fatal 'state/dynamic directories must be absolute non-root paths without control characters or ..'
    done
    case "$SYNC_DYNAMIC_FILE" in *.yml|*.yaml) ;; *) fatal 'SYNC_DYNAMIC_FILE must end in .yml or .yaml' ;; esac
    [ ! -L "$SYNC_STATE_DIR" ] && [ ! -L "$SYNC_DYNAMIC_FILE" ] || fatal 'state directory and dynamic file must not be symbolic links'
    mkdir -p "$SYNC_STATE_DIR" "$(dirname "$SYNC_DYNAMIC_FILE")"
}

snapshot() { stat -Lc '%d:%i:%s:%y:%z' "$1"; }

# Each group gets its own timeout. There are no source-side writes or locks, including on NFS.
sync_pair() {
    name=$1 cert=$2 key=$3
    pair_dir=$SYNC_STATE_DIR/$name
    mkdir -p "$pair_dir/releases"
    stage=$(mktemp -d "$pair_dir/.stage.XXXXXXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT

    now=$(date +%s)
    for source in "$cert" "$key"; do
        [ -f "$source" ] || { log "$name: source missing or not a regular file"; return 2; }
        modified=$(stat -Lc '%Y' "$source") || return 2
        size=$(stat -Lc '%s' "$source") || return 2
        # Future timestamps are unstable too; NFS server/client clock skew must not bypass the guard.
        [ "$((now - modified))" -ge "$SYNC_MIN_AGE_SECS" ] || { log "$name: source not stable yet"; return 2; }
        [ "$size" -gt 0 ] && [ "$size" -le "$SYNC_MAX_FILE_BYTES" ] || { log "$name: source size out of bounds"; return 2; }
    done
    cert_before=$(snapshot "$cert") || return 2
    key_before=$(snapshot "$key") || return 2
    cp -L -- "$cert" "$stage/fullchain.pem" || return 2
    cp -L -- "$key" "$stage/privkey.pem" || return 2
    [ "$cert_before" = "$(snapshot "$cert")" ] && [ "$key_before" = "$(snapshot "$key")" ] || {
        log "$name: source changed while copying"; return 2;
    }
    for source in "$cert" "$key"; do
        modified=$(stat -Lc '%Y' "$source") || return 2
        [ "$((now - modified))" -ge "$SYNC_MIN_AGE_SECS" ] || return 2
    done
    chmod 600 "$stage/fullchain.pem" "$stage/privkey.pem"

    current=
    if [ -f "$pair_dir/current" ]; then current=$(cat "$pair_dir/current"); fi
    if [ -n "$current" ] && cmp -s "$stage/fullchain.pem" "$current/fullchain.pem" &&
        cmp -s "$stage/privkey.pem" "$current/privkey.pem"; then
        return 0
    fi

    # Validate the PEM bundle, leaf expiry and matching public keys (both RSA and EC).
    # -passin pass: rejects encrypted keys without ever waiting for an interactive password.
    openssl crl2pkcs7 -nocrl -certfile "$stage/fullchain.pem" -out /dev/null || return 2
    openssl x509 -in "$stage/fullchain.pem" -noout -checkend 0 >/dev/null || return 2
    openssl pkey -in "$stage/privkey.pem" -passin pass: -check -noout >/dev/null || return 2
    openssl x509 -in "$stage/fullchain.pem" -pubkey -noout > "$stage/cert.pub" || return 2
    openssl pkey -in "$stage/privkey.pem" -passin pass: -pubout > "$stage/key.pub" || return 2
    cmp -s "$stage/cert.pub" "$stage/key.pub" || { log "$name: certificate/private key mismatch"; return 2; }
    rm -f "$stage/cert.pub" "$stage/key.pub"

    # Versioned paths publish a pair as one unit. Never overwrite PEM files used by the active config.
    version=$pair_dir/releases/$(date +%s)-${stage##*.stage.}
    mv -- "$stage" "$version"
    printf '%s\n' "$version" > "$pair_dir/.current.tmp"
    mv -f -- "$pair_dir/.current.tmp" "$pair_dir/current"
    log "$name: new certificate version prepared"
}

sync_round() (
    validate
    # Lock only LOCAL state. The kernel releases this lock on crashes; NFS need not support flock.
    exec 9> "$SYNC_STATE_DIR/.sync.lock"
    flock -n 9 || { log 'another synchronizer is using this local state directory'; exit 75; }
    round=$(mktemp -d "$SYNC_STATE_DIR/.round.XXXXXXXXXX")
    config_tmp=
    trap 'rm -rf -- "$round"; [ -z "$config_tmp" ] || rm -f -- "$config_tmp"' EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    printf '%s' "$SYNC_PAIRS" | jq -c '.[]' > "$round/pairs"
    : > "$round/certificates"
    errors=0 missing=0
    while IFS= read -r record; do
        name=$(printf '%s' "$record" | jq -r '.name')
        cert=$(printf '%s' "$record" | jq -r '.cert')
        key=$(printf '%s' "$record" | jq -r '.key')
        result=0
        # BusyBox timeout may leave its watchdog alive briefly after success; it must not inherit our lock.
        timeout -s TERM -k 5 "$SYNC_IO_TIMEOUT_SECS" "$0" --pair "$name" "$cert" "$key" 9>&- || result=$?
        if [ "$result" -ne 0 ]; then
            errors=$((errors + 1))
            log "$name: skipped (status=$result); retaining previous local version if available"
        fi
        current_file=$SYNC_STATE_DIR/$name/current
        current=
        if [ -f "$current_file" ]; then current=$(cat "$current_file"); fi
        # Only our own immutable release paths may enter the generated Traefik configuration.
        case "$current" in "$SYNC_STATE_DIR/$name/releases/"*) ;; *) current= ;; esac
        if [ -z "$current" ] || [ ! -s "$current/fullchain.pem" ] || [ ! -s "$current/privkey.pem" ]; then
            missing=$((missing + 1)); continue
        fi
        jq -nc --arg cert "$current/fullchain.pem" --arg key "$current/privkey.pem" \
            '{certFile:$cert,keyFile:$key}' >> "$round/certificates"
    done < "$round/pairs"
    if [ "$missing" -ne 0 ]; then
        log "$missing group(s) have no usable local version; existing dynamic configuration left intact"
        exit 1
    fi
    # JSON is valid YAML. jq safely escapes paths rather than interpolating raw YAML strings.
    jq -s '{tls:{certificates:.}}' "$round/certificates" > "$round/config"
    if ! cmp -s "$round/config" "$SYNC_DYNAMIC_FILE"; then
        # Stage next to the destination with an ignored extension: rename is atomic on the local filesystem.
        # BusyBox mktemp requires the X suffix at the end; the random extension is not YAML/TOML.
        config_tmp=$(mktemp "$(dirname "$SYNC_DYNAMIC_FILE")/.cert-sync.XXXXXXXXXX")
        cp -- "$round/config" "$config_tmp"
        chmod 600 "$config_tmp"
        mv -f -- "$config_tmp" "$SYNC_DYNAMIC_FILE"
        config_tmp=
        log 'published dynamic certificate configuration'
    fi
    log "scan complete: skipped_groups=$errors"
    [ "$errors" -eq 0 ] || exit 2
)

case "${1:---once}" in
    --pair)
        [ "$#" -eq 4 ] || fatal 'internal --pair requires name, cert, key'
        sync_pair "$2" "$3" "$4"
        ;;
    --once|--init) sync_round ;;
    --loop)
        validate
        while :; do
            sleep "$SYNC_INTERVAL_SECS" &
            sleeper=$!
            trap 'kill "$sleeper" 2>/dev/null || :; exit 0' TERM INT
            wait "$sleeper"
            # A child owns each round's EXIT cleanup and lock; ordinary source failures are retried next round.
            result=0
            "$0" --once || result=$?
            case "$result" in
                0|1|2) ;;
                *) log "sync worker failed (status=$result)"; exit "$result" ;;
            esac
        done
        ;;
    *) fatal 'usage: cert-sync [--once|--init|--loop]' ;;
esac
