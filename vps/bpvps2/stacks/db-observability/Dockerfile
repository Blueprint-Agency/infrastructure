# The same Alloy tag as the monitoring stack -- bump both together. CI validates config.alloy
# against this line (vps/shared/validate-alloy.sh). Database Observability needs >= 1.17.0.
FROM grafana/alloy:v1.19.2
# Baked in, not bind-mounted, for the monitoring stack's reason: CI's rsync replaces files by
# rename, a single-file bind mount stays on the old inode, and `compose up` would see no
# change. As a COPY layer, a changed config is a changed image and the container is recreated.
COPY config.alloy /etc/alloy/
