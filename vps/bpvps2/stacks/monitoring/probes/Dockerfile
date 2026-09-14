# Textfile probes (#25): a docker CLI, psql-free (queries run inside each database container),
# curl + jq for tailscaled's LocalAPI, bash + openssl + dig for the mail dialog. Exact tags.
# Built on the host by `compose up` (pull_policy: build): a change here lands on the next deploy.
FROM docker:29.6.2-cli AS docker

FROM alpine:3.22.1
RUN apk add --no-cache bash curl jq openssl bind-tools
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY bin/ /app/bin/
COPY crontab /etc/crontabs/root
RUN chmod 755 /app/bin/*.sh
ENTRYPOINT ["/app/bin/entrypoint.sh"]
