#!/usr/bin/env bash
# A single worker streams directory entries; file contents stay in cmp/cp's bounded buffers.
set -uo pipefail
umask 077

log() { printf '%s\n' "$*" >&2; }
die() { log "event=fatal $*"; exit 1; }
uint() {
    local name=$1 default=$2 min=$3 max=$4 value
    value=${!name:-$default}
    [[ $value =~ ^[0-9]{1,9}$ ]] || die "$name must be an integer"
    value=$((10#$value))
    (( value >= min && value <= max )) || die "$name must be in $min..$max"
    printf -v "$name" '%s' "$value"
}

# Reject every existing symlink component, including links in ancestors of a missing destination.
# This is accidental-redirection protection, not a sandbox against hostile concurrent directory swaps.
no_links() {
    local path=$1 part current=
    local -a parts
    IFS=/ read -r -a parts <<< "$path"
    for part in "${parts[@]}"; do
        [[ -z $part ]] && continue
        current+=/$part
        [[ ! -L $current ]] || return 1
    done
}

normalize() {
    [[ $1 == /* && $1 != *$'\n'* && $1 != *$'\r'* && $1 != *'|'* ]] || return 1
    no_links "$1" || return 1
    realpath -m -- "$1"
}

overlaps() { [[ $1 == "$2" || $1 == "$2/"* || $2 == "$1/"* || $1 == / || $2 == / ]]; }

load_config() {
    uint SYNC_INTERVAL_SECS 60 1 31536000
    uint SYNC_MIN_AGE_SECS 10 0 31536000
    uint SYNC_MAX_DEPTH 128 1 256
    uint SYNC_FILE_DELAY_MS 0 0 60000
    uint SYNC_IO_TIMEOUT_SECS 30 1 86400
    uint SYNC_LOG_LIMIT 20 0 10000
    SYNC_COMPARE=${SYNC_COMPARE:-content}
    [[ $SYNC_COMPARE == content || $SYNC_COMPARE == metadata ]] || die 'SYNC_COMPARE must be content or metadata'
    [[ -n ${SYNC_PAIRS:-} ]] || die 'SYNC_PAIRS is required (one source|target per line)'
    sources=() targets=()
    local line source target i j
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line ]] && continue
        [[ $line == *'|'* ]] || die 'each SYNC_PAIRS line must be source|target'
        source=${line%%|*}; target=${line#*|}
        [[ -n $source && -n $target && $target != *'|'* ]] || die 'invalid folder pair'
        source=$(normalize "$source") || die "invalid/symlink source: $source"
        target=$(normalize "$target") || die "invalid/symlink target: $target"
        sources+=("$source"); targets+=("$target")
    done <<< "$SYNC_PAIRS"
    (( ${#sources[@]} > 0 && ${#sources[@]} <= 256 )) || die 'configure 1..256 pairs'
    for ((i=0; i<${#targets[@]}; i++)); do
        for source in "${sources[@]}"; do
            overlaps "$source" "${targets[i]}" && die 'source/target trees overlap, including across pairs'
        done
        for ((j=i+1; j<${#targets[@]}; j++)); do
            overlaps "${targets[i]}" "${targets[j]}" && die 'target trees overlap'
        done
    done
    SYNC_RELOAD_FILE=${SYNC_RELOAD_FILE:-}
    if [[ -n $SYNC_RELOAD_FILE ]]; then
        SYNC_RELOAD_FILE=$(normalize "$SYNC_RELOAD_FILE") || die 'invalid SYNC_RELOAD_FILE'
        # The reload file must be an existing application-owned YAML/TOML, never a certificate or arbitrary file.
        case $SYNC_RELOAD_FILE in *.yml|*.yaml|*.toml) ;; *) die 'SYNC_RELOAD_FILE must end in .yml/.yaml/.toml';; esac
        for source in "${sources[@]}"; do
            overlaps "$source" "$SYNC_RELOAD_FILE" && die 'reload file must not be inside any source'
        done
    fi
    SYNC_STATE_DIR=${SYNC_STATE_DIR:-/run/folder-sync}
    [[ $SYNC_STATE_DIR == /* ]] || die 'SYNC_STATE_DIR must be absolute'
    no_links "$SYNC_STATE_DIR" || die 'state directory must not contain symlinks'
    SYNC_STATE_DIR=$(realpath -m -- "$SYNC_STATE_DIR") || die 'cannot resolve state directory'
    for source in "${sources[@]}" "${targets[@]}"; do
        overlaps "$source" "$SYNC_STATE_DIR" && die 'state directory must be separate from synchronized trees'
    done
    mkdir -p -- "$SYNC_STATE_DIR" || die 'cannot create state directory'
    # The lock lives locally, so NFS lock support is not required. Instances sharing targets must share this lock.
    [[ ! -L $SYNC_STATE_DIR/lock ]] || die 'invalid lock file'
    exec 9>"$SYNC_STATE_DIR/lock" || die 'cannot open worker lock'
    flock -n 9 || die 'another worker is using this state directory'
    printf -v file_delay '%d.%03d' "$((SYNC_FILE_DELAY_MS / 1000))" "$((SYNC_FILE_DELAY_MS % 1000))"
}

temp_file='' child='' find_pid=''
cleanup() {
    [[ -z $temp_file ]] || rm -f -- "$temp_file"
}
shutdown() {
    [[ -z $child ]] || kill -TERM "$child" 2>/dev/null || :
    [[ -z $find_pid ]] || kill -TERM "$find_pid" 2>/dev/null || :
    exit 0
}
trap cleanup EXIT
trap shutdown TERM INT

# timeout bounds ordinary stalled utilities; Linux uninterruptible NFS I/O still depends on mount recovery.
io_run() {
    timeout --signal=TERM --kill-after=2 "$SYNC_IO_TIMEOUT_SECS" "$@" 9>&- &
    child=$!
    local result=0
    wait "$child" || result=$?
    child=
    return "$result"
}

snapshot() { timeout --signal=TERM --kill-after=2 "$SYNC_IO_TIMEOUT_SECS" stat -c '%Y|%s|%y|%z|%d|%i' -- "$1" 9>&-; }
old_enough() {
    local mtime=${1%%|*} now
    now=$(date +%s) || return 1
    [[ $mtime =~ ^-?[0-9]+$ ]] || return 1
    (( now - mtime >= SYNC_MIN_AGE_SECS ))
}
size_time() { local data=${1#*|}; printf '%s' "${data%|*|*|*}"; }

warn() {
    local kind=$1 path=$2 reason=$3
    if [[ $kind == skipped ]]; then ((skipped+=1)); else ((errors+=1)); fi
    if (( warnings < SYNC_LOG_LIMIT )); then
        printf 'event=%s path=%q reason=%q\n' "$kind" "$path" "$reason" >&2
    fi
    ((warnings+=1))
}

sync_file() {
    local source=$1 target=$2 before after dest_before=absent dest_after result parent
    [[ -f $source && ! -L $source ]] || { warn skipped "$source" 'not a regular file'; return; }
    if ! no_links "$source" || ! no_links "$target"; then
        warn skipped "$source" 'symlink component'; return
    fi
    before=$(snapshot "$source") || { warn errors "$source" 'source stat failed'; return; }
    old_enough "$before" || { warn skipped "$source" 'source too recent or future timestamp'; return; }
    if [[ -e $target ]]; then
        [[ -f $target ]] || { warn errors "$target" 'destination is not a regular file'; return; }
        dest_before=$(snapshot "$target") || { warn errors "$target" 'target stat failed'; return; }
        old_enough "$dest_before" || { warn skipped "$target" 'target too recent or future timestamp'; return; }
        result=1
        if [[ $SYNC_COMPARE == metadata ]]; then
            [[ $(size_time "$before") == "$(size_time "$dest_before")" ]] && result=0
        else
            io_run cmp -s -- "$source" "$target"; result=$?
        fi
        if (( result > 1 )); then warn errors "$source" 'comparison failed/timed out'; return; fi
        if (( result == 0 )); then ((unchanged+=1)); return; fi
    fi
    parent=${target%/*}
    io_run mkdir -p -- "$parent" || { warn errors "$target" 'cannot create destination directory'; return; }
    no_links "$parent" || { warn errors "$target" 'destination directory changed'; return; }
    temp_file=$(mktemp "$parent/.folder-sync-tmp.XXXXXXXXXX") || { warn errors "$target" 'cannot create temporary file'; return; }
    # Preserve timestamps only: no source owner, ACL or privilege bits are imported into the destination.
    # Private keys stay private through umask 077; Traefik must run as the same UID or have explicit access.
    if ! io_run cp --preserve=timestamps -- "$source" "$temp_file"; then
        warn errors "$source" 'copy failed/timed out'; discard_temp; return
    fi
    # NFS can defer reporting errors until fsync. Do not publish a copy that failed its flush.
    if ! io_run sync -- "$temp_file"; then
        warn errors "$target" 'flush failed/timed out'; discard_temp; return
    fi
    after=$(snapshot "$source") || after=failed
    dest_after=absent
    if [[ -e $target || -L $target ]]; then dest_after=$(snapshot "$target") || dest_after=failed; fi
    if [[ $before != "$after" || $dest_before != "$dest_after" ]] || ! no_links "$source" || ! no_links "$target"; then
        warn skipped "$source" 'source or target changed during copy'; discard_temp; return
    fi
    # A sibling temp + rename prevents partial individual files, even when the target is NFS.
    # This is not a transaction spanning two files or folder pairs; publish dependent bundles upstream.
    if ! io_run mv -fT -- "$temp_file" "$target"; then
        warn errors "$target" 'atomic replacement failed'; discard_temp; return
    fi
    temp_file=
    ((copied+=1))
    reload_pending=1
    : > "$SYNC_STATE_DIR/reload-pending"
}

discard_temp() { rm -f -- "$temp_file"; temp_file=; }

scan_pair() {
    local source=$1 target=$2 entry relative destination scan_fd scan_status=0
    if ! no_links "$source" || ! no_links "$target"; then
        warn errors "$source" 'symlink in folder pair'; return
    fi
    [[ -d $source ]] || { warn errors "$source" 'source directory unavailable'; return; }
    io_run mkdir -p -- "$target" || { warn errors "$target" 'target directory unavailable'; return; }
    # Stream NUL-delimited paths instead of loading a whole tree into RAM. Depth limits bound traversal state.
    exec {scan_fd}< <(find -P "$source" -mindepth 1 -maxdepth "$((SYNC_MAX_DEPTH + 1))" \
        -name '.folder-sync-*' -prune -o -print0 9>&-)
    find_pid=$!
    while IFS= read -r -d '' entry <&"$scan_fd"; do
        relative=${entry#"$source"/}; destination=$target/$relative
        if [[ $relative == *$'\n'* || $relative == *$'\r'* ]]; then
            warn skipped "$entry" 'newline in filename is not supported'; continue
        fi
        local slashes=${relative//[^\/]/}
        if (( ${#slashes} >= SYNC_MAX_DEPTH )); then
            warn skipped "$entry" 'maximum depth exceeded'; continue
        fi
        if [[ -L $entry ]]; then
            warn skipped "$entry" 'symbolic link ignored'
        elif [[ -d $entry ]]; then
            if ! no_links "$destination" || ! io_run mkdir -p -- "$destination"; then
                warn errors "$destination" 'cannot create directory'
            fi
        elif [[ -f $entry ]]; then
            sync_file "$entry" "$destination"
            if (( SYNC_FILE_DELAY_MS > 0 )); then io_run sleep "$file_delay" || :; fi
        else
            warn skipped "$entry" 'special/disappeared file ignored'
        fi
    done
    exec {scan_fd}<&-
    wait "$find_pid" || scan_status=$?
    find_pid=
    (( scan_status == 0 )) || warn errors "$source" 'directory scan failed/timed out; will retry'
}

reload() {
    [[ -n $SYNC_RELOAD_FILE && $reload_pending == 1 ]] || return 0
    local before after
    if [[ ! -f $SYNC_RELOAD_FILE ]] || ! no_links "$SYNC_RELOAD_FILE"; then
        warn errors "$SYNC_RELOAD_FILE" 'reload file missing/unsafe; retry next round'; return
    fi
    before=$(snapshot "$SYNC_RELOAD_FILE") || { warn errors "$SYNC_RELOAD_FILE" 'reload stat failed'; return; }
    # Replacing a complete existing config produces a local directory event, including when only PEMs changed.
    # No placeholder TLS config is generated: existing user routes/options must remain intact.
    temp_file=$(mktemp "${SYNC_RELOAD_FILE%/*}/.folder-sync-reload.XXXXXXXXXX") || {
        warn errors "$SYNC_RELOAD_FILE" 'cannot create reload temp'; return;
    }
    if ! io_run cp --preserve=timestamps -- "$SYNC_RELOAD_FILE" "$temp_file" || ! io_run sync -- "$temp_file"; then
        warn errors "$SYNC_RELOAD_FILE" 'reload staging failed'; discard_temp; return
    fi
    after=$(snapshot "$SYNC_RELOAD_FILE") || after=failed
    if [[ $before != "$after" ]] || ! no_links "$SYNC_RELOAD_FILE"; then
        warn skipped "$SYNC_RELOAD_FILE" 'reload file changed concurrently'; discard_temp; return
    fi
    if ! io_run mv -fT -- "$temp_file" "$SYNC_RELOAD_FILE"; then
        warn errors "$SYNC_RELOAD_FILE" 'reload replacement failed'; discard_temp; return
    fi
    temp_file=; reload_pending=0
    rm -f -- "$SYNC_STATE_DIR/reload-pending"
    log 'event=reload_requested'
}

scan() {
    copied=0 unchanged=0 skipped=0 errors=0 warnings=0
    local i
    for ((i=0; i<${#sources[@]}; i++)); do scan_pair "${sources[i]}" "${targets[i]}"; done
    reload
    log "event=scan copied=$copied unchanged=$unchanged skipped=$skipped errors=$errors"
    # Heartbeat records completed scans, including partial failures; actual errors remain visible in logs.
    date +%s > "$SYNC_STATE_DIR/heartbeat"
    (( errors == 0 && skipped == 0 ))
}

load_config
reload_pending=0
[[ ! -e $SYNC_STATE_DIR/reload-pending ]] || reload_pending=1
case ${1:-run} in
    check) log "event=config_valid pairs=${#sources[@]}" ;;
    once) scan || exit 2 ;;
    run)
        log "event=start pairs=${#sources[@]} compare=$SYNC_COMPARE interval_secs=$SYNC_INTERVAL_SECS min_age_secs=$SYNC_MIN_AGE_SECS"
        while :; do
            scan || :
            # Completion-relative scheduling cannot overlap scans and avoids catch-up storms after slow NFS.
            sleep "$SYNC_INTERVAL_SECS" 9>&- & child=$!
            wait "$child" || :
            child=
        done
        ;;
    *) die 'usage: sync.sh [run|once|check]' ;;
esac
