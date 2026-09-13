# restic, a docker CLI and yq, all from exact tags. Built on the host by `compose up`
# (pull_policy: build), so a change here or under bin/ lands on the next deploy.
#
# No Postgres or MySQL client in here on purpose: dumps run inside the database
# containers via `docker exec`, so their version always matches the server's.
FROM docker:29.6.2-cli AS docker
FROM mikefarah/yq:4.47.2 AS yq

FROM restic/restic:0.18.1
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY --from=yq /usr/bin/yq /usr/local/bin/yq
COPY bin/ /app/bin/
COPY crontab /etc/crontabs/root
# Baked in, NOT bind-mounted. CI's rsync replaces targets.yml by rename, and a single-file
# bind mount stays pinned to the old inode -- while `compose up` sees no config change and
# keeps the container. A deploy that only added a target would reach nothing. As a COPY
# layer, a changed file is a changed image, and compose recreates the container.
COPY targets.yml /app/targets.yml
RUN chmod 755 /app/bin/*.sh
ENTRYPOINT ["/app/bin/entrypoint.sh"]
