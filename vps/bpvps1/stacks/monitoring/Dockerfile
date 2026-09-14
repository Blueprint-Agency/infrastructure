# The exact Alloy tag is pinned HERE -- bump it deliberately, and CI validates config.alloy
# against the same tag (it reads this line).
FROM grafana/alloy:v1.19.2
# Baked in, NOT bind-mounted. CI's rsync replaces files by rename, and a single-file bind
# mount stays pinned to the old inode -- while `compose up` sees no change and keeps the
# container. As a COPY layer, a changed allowlist is a changed image, and compose recreates
# the container. Same reasoning as the backup stack.
COPY config.alloy metrics.allowlist /etc/alloy/
