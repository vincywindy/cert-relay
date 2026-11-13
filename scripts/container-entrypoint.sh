#!/bin/sh
set -eu

[ "$#" -gt 0 ] || set -- traefik
case "${SYNC_ENABLED:-true}" in
    false|0) exec /entrypoint.sh "$@" ;;
    true|1) ;;
    *) echo 'cert-sync: SYNC_ENABLED must be true/false or 1/0' >&2; exit 64 ;;
esac

# Diagnostics and arbitrary commands retain the official image behavior without requiring certificates.
case "$1" in
    --help|-h|--version) exec /entrypoint.sh "$@" ;;
    -*) ;;
    traefik|*/traefik)
        case "${2:-}" in
            --help|-h|--version) exec /entrypoint.sh "$@" ;;
            ''|-*) ;;
            *) exec /entrypoint.sh "$@" ;;
        esac ;;
    *) exec /entrypoint.sh "$@" ;;
esac

traefik_pid=
sync_pid=
shutdown() {
    trap '' TERM INT
    trap - CHLD
    # tini -g gives this supervisor a dedicated process group. Stop timeout/OpenSSL/sleep descendants too.
    kill -TERM 0 2>/dev/null || :
    [ -z "$traefik_pid" ] || kill -TERM "$traefik_pid" 2>/dev/null || :
    [ -z "$sync_pid" ] || kill -TERM "$sync_pid" 2>/dev/null || :
    [ -z "$traefik_pid" ] || wait "$traefik_pid" 2>/dev/null || :
    [ -z "$sync_pid" ] || wait "$sync_pid" 2>/dev/null || :
}
trap 'shutdown; exit 0' TERM INT

# Bootstrap before starting Traefik. Status 2 means failures were covered by previous local versions.
result=0
/usr/local/bin/cert-sync --init || result=$?
case "$result" in 0|2) ;; *) exit "$result" ;; esac

check_worker() {
    [ -n "$sync_pid" ] && [ -n "$traefik_pid" ] || return 0
    if ! kill -0 "$sync_pid" 2>/dev/null; then
        echo 'cert-sync: sync worker exited unexpectedly; stopping container' >&2
        shutdown
        exit 1
    fi
}
# SIGCHLD is event-driven: no polling process is needed. BusyBox wait -n can miss a
# signal-killed job, so explicitly check worker liveness when a direct child exits.
trap check_worker CHLD
/usr/local/bin/cert-sync --loop &
sync_pid=$!
/entrypoint.sh "$@" &
traefik_pid=$!
check_worker

result=0
wait "$traefik_pid" || result=$?
echo "cert-sync: supervised process exited (status=$result); stopping container" >&2
shutdown
[ "$result" -ne 0 ] || result=1
exit "$result"
