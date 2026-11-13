#!/usr/bin/env bash
set -uo pipefail

sync_script=${SYNC_SCRIPT:-/usr/local/bin/folder-sync}
state=${SYNC_STATE_DIR:-/run/folder-sync}
case ${1:-} in
    sync-once) exec "$sync_script" once ;;
    sync-check) exec "$sync_script" check ;;
    sync-only) exec "$sync_script" run ;;
esac

worker='' proxy='' initial=''
stop_children() {
    trap '' TERM INT
    local pid
    for pid in "$worker" "$proxy" "$initial"; do
        [[ -z $pid ]] || kill -TERM "$pid" 2>/dev/null || :
    done
    for pid in "$worker" "$proxy" "$initial"; do
        [[ -z $pid ]] || wait "$pid" 2>/dev/null || :
    done
}
trap 'stop_children; exit 0' TERM INT

# Populate local directories before Traefik performs its first file-provider load.
# Exit 2 means a partial scan; an existing usable local configuration can still serve traffic.
initial_result=0
"$sync_script" once & initial=$!
wait "$initial" || initial_result=$?
initial=
if (( initial_result != 0 && initial_result != 2 )); then exit "$initial_result"; fi

"$sync_script" run & worker=$!
mkdir -p -- "$state"
printf '%s\n' "$worker" > "$state/worker.pid"
if (( $# == 0 )); then set -- traefik; fi
# Keep the upstream entrypoint's command/flag handling; signals are forwarded to both processes.
"${TRAEFIK_ENTRYPOINT:-/entrypoint.sh}" "$@" & proxy=$!
printf '%s\n' "$proxy" > "$state/traefik.pid"

# If either child exits, terminate the other and let Swarm restart the whole service.
# wait -n blocks in the kernel, so supervision needs no polling loop.
result=0
wait -n "$worker" "$proxy" || result=$?
stop_children
(( result != 0 )) || result=1
exit "$result"
