# syntax=docker/dockerfile:1
ARG TRAEFIK_IMAGE=traefik:3.7.18
FROM ${TRAEFIK_IMAGE}

RUN apk add --no-cache openssl jq tini flock bash coreutils findutils \
    && test -x /entrypoint.sh
COPY --chmod=755 scripts/cert-sync.sh /usr/local/bin/cert-sync
COPY --chmod=755 scripts/container-entrypoint.sh /usr/local/bin/cert-sync-entrypoint
COPY --chmod=755 scripts/folder-sync.sh /usr/local/bin/folder-sync
COPY --chmod=755 scripts/folder-entrypoint.sh /usr/local/bin/folder-sync-entrypoint
COPY --chmod=755 scripts/folder-healthcheck.sh /usr/local/bin/folder-sync-healthcheck

# Preserve the official entrypoint. tini forwards signals to the entire process group.
ENTRYPOINT ["/sbin/tini", "-g", "--", "/usr/local/bin/cert-sync-entrypoint"]
CMD ["traefik"]
