# blog-redirect (bpvps1)

`blog.kaiteki.my` after the blog moved to `kaiteki.my/blog`. One nginx container that
301s every legacy URL to its new home. No data and no secrets, so nothing to back up.

## What it maps

`blog-redirects.conf` is **generated** by kaiteki-web: `pnpm blog:redirects`
(`scripts/blog-redirects.mts`, rules in `scripts/blog-redirect-rules.mjs`). Don't edit it
by hand. Regenerate it there and copy it here. It needs the old WordPress API, so the
generator could only run while WordPress was still up. If WordPress is gone, edit the
generated file as a last resort and say so in the commit.

| Legacy URL | Goes to |
|---|---|
| 155 posts (152 moved verbatim, 3 rewritten earlier) | `kaiteki.my/blog/<slug>` (same slug except the 3) |
| 7 slugs posts still linked to after a rename | the post that took the name |
| 51 doorway pages (`skin-specialist-in-<area>`) | the nearest `/locations/<branch>` |
| 8 Malay posts, 2 other WP pages | `kaiteki.my/blog` (not migrated) |
| 53 category archives | `kaiteki.my/blog/category/<one of our 5>` |
| every image the migration moved | its `cdn.kaiteki.my/blog/...` copy |
| 2 injected spam posts (kmspico, office activator) | **410 Gone**, never a 301 |
| any other `/wp-content/...` | 410 |
| everything else (`/`, feeds, authors, `?p=`) | `kaiteki.my/blog` |

Both `/slug/` and `/slug` match. `/healthz` answers 200 for the container healthcheck.

## Cutover (2026-10)

Order matters. The posts have to be live before anything points at them.

1. kaiteki-web PR merged and deployed. Check a few: `curl -sI https://kaiteki.my/blog/pico-laser`
   should return 200, and the cover image URL in the page should return 200 from `cdn.kaiteki.my`.
2. No extra backup is taken first (decided at cutover). The last nightly restic snapshot,
   and the untouched volume, are the copies.
3. Merge this stack. CI deploys it. Its router has priority 1000, so it takes
   `blog.kaiteki.my` from WordPress as soon as it starts. Check:
   `curl -sI https://blog.kaiteki.my/pico-laser/` should return 301 to `https://kaiteki.my/blog/pico-laser`.
4. Stop WordPress. **Stop, do not delete.** The stack dir is root-owned, so run compose
   from a container, the same way as for stalwart:
   ```bash
   ssh bp-bpvps1 'docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
     -v /root/stacks/wordpress:/root/stacks/wordpress -w /root/stacks/wordpress \
     docker:cli compose stop'
   ```
5. Check every rule from a laptop: `scripts/check-blog-redirects.sh` (in this dir).

## What was kept, and where

- **Database:** the `wordpress_wp-db-data` volume is still on bpvps1, untouched. The nightly
  restic snapshots (target `wordpress`) stop with the retirement. `restic forget` only runs
  for a target when it is backed up, so the last ones (7 daily, 4 weekly, up to 6 monthly)
  stay in R2 indefinitely.
- **Files:** `/root/stacks/wordpress/wp-content` (698 MB, uploads, theme and plugins) is still
  on disk. It was never in restic. Hostinger's weekly VM backup is its only other copy.
  Every image a published post used is also in R2 under `cdn.kaiteki.my/blog/`.

Deleting either is a separate decision. Nothing in this repo needs them any more.

## Rollback

Start WordPress again (step 4 with `up -d` in place of `stop`), then remove this stack:
`ssh bp-bpvps1 'cd /root/stacks/blog-redirect && docker compose down'`. WordPress gets the
hostname back as soon as the higher-priority router is gone.
