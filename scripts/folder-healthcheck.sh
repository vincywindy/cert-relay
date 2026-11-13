#!/usr/bin/env bash
set -eu
state=${SYNC_STATE_DIR:-/run/folder-sync}
for name in worker traefik; do
    [[ -r $state/$name.pid ]] || exit 1
    read -r pid < "$state/$name.pid"
    kill -0 "$pid" || exit 1
done
# A scan stuck in NFS I/O must not silently leave Traefik serving old configuration forever.
# Tune grace above the expected longest scan; this only detects progress, not certificate validity.
[[ -r $state/heartbeat ]] || exit 1
read -r last < "$state/heartbeat"
now=$(date +%s)
(( now - last <= ${SYNC_INTERVAL_SECS:-60} + ${SYNC_HEALTH_GRACE_SECS:-300} ))
