# restic plus a docker CLI, both from exact tags. Built on the host by `compose up`
# (pull_policy: build), so a change here or under bin/ lands on the next deploy.
#
# No Postgres client in here on purpose: pg_dump and pg_restore run inside the database
# containers via `docker exec`, so their version always matches the server's.
FROM docker:29.6.2-cli AS docker

FROM restic/restic:0.18.1
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY bin/ /app/bin/
COPY crontab /etc/crontabs/root
RUN chmod 755 /app/bin/*.sh
ENTRYPOINT ["/app/bin/entrypoint.sh"]
