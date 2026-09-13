---
name: provision
description: Provision infrastructure in this repo — onboard a new VPS host into CI, or add a new Compose stack (with its CI secrets) to an existing host. Use when adding a VPS, adding or removing a stack, or wiring a new per-stack secret.
---

# Provisioning

Read `CLAUDE.md` first — it is the source of truth for hosts, accounts, and the CI
contract. This skill is the ordered procedure; CLAUDE.md is the state.

Two branches. A new host that also needs stacks is branch A then branch B.

**A new mail domain is neither branch.** Mail is one Stalwart on bpvps1 serving every
domain; a client is rows added to it, not a stack. That checklist is the
`onboard-mail-domain` skill, next to this one.

Steps marked **[human]** cannot be done from here — no API token exists for them.
Do everything else yourself, then hand the human a numbered list of only the
**[human]** steps left, and wait.

---

## Branch A — onboard a new VPS host

`<key>` is the host's short name (`bpvps3`). It is used verbatim as the
`vps/hosts.json` key, the repo dir, and the GitHub Environment name. The SSH alias
is `bp-<key>`.

1. **Buy / identify the VPS.** Blueprint account (bpvps*): `VPS_getVirtualMachinesV1`
   on `hostinger-vps-blueprint`. Teeko account (vps1/2/3): **[human]**, hPanel —
   no token exists for that account.

2. **Run the setup script** against the public IP, while port 22 is still open:
   ```bash
   ssh root@<public-ip> 'TS_AUTHKEY=tskey-auth-... bash -s' < vps/shared/setup-vps.sh
   ```
   It installs Docker + the `DOCKER_MIN_API_VERSION=1.24` drop-in, creates `deploy`,
   prepares `/root/stacks`, and joins the tailnet. **[human]** must generate the auth
   key first (Tailscale console → Settings → Keys, tag `tag:server`) — there is no
   Tailscale API token in `.env`.

3. **[human] Disable key expiry** — Tailscale console → Machines → the new node →
   ⋯ → Disable key expiry. A tag does not do this on its own. With port 22 closed,
   an expired key is console-only recovery.

4. **Authorize the keys** on the new host. `deploy` needs both the CI deploy key
   (org secret `SSH_PRIVATE_KEY`) and your `~/.ssh/infra_ed25519.pub`. Step 2 copies
   whatever root already had; append anything missing.

5. **Firewall** — 80 and 443 from any; 22 from `100.64.0.0/10` only. Restrict rule
   22, never delete it.
   - Blueprint account: group `319466` is **shared by bpvps1 + bpvps2** — editing it
     hits both. Use `VPS_createFirewallRuleV1` / `VPS_syncFirewallV1`, then poll
     `VPS_getActionDetailsV1` until `success` (~100s). `is_synced` flips to true
     while the action is still running — do not trust it.
   - Teeko account: **[human]**, hPanel.

6. **Local SSH alias.** Add `bp-<key>` to `~/.ssh/config` pointing at the `100.x`
   address, user `deploy`, key `~/.ssh/infra_ed25519`. Never a public IP.
   Verify: `ssh bp-<key> 'echo OK $(hostname)'`.

7. **GitHub Environment** named exactly `<key>`, on `Blueprint-Agency/infrastructure`.
   It needs **only** `TAILSCALE_HOST` (the `100.x` address) — `SSH_PRIVATE_KEY`,
   `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`, `CF_DNS_API_TOKEN`, `DOCKERHUB_TOKEN`,
   `ACME_EMAIL`, `BASE_DOMAIN` are org-level and inherited. Override `BASE_DOMAIN` /
   `ACME_EMAIL` per Environment when the host serves a different zone (bpvps1 does).
   Use `curl` + REST API with the `.env` PAT; there is no `gh` CLI.

8. **`vps/hosts.json`** — one entry:
   ```json
   { "key": "<key>", "dir": "vps/<key>", "env_name": "prod", "exclude": "", "app_stacks": "" }
   ```
   `env_name` is the host default written as `ENV_NAME` into every stack's `.env`.
   Add `fanout` only when one repo stack deploys into several dirs on this host —
   each destination then carries its own `env_name`.

9. **Update `CLAUDE.md`** — the VPS Access table, What's Running, and the firewall
   section. Agents read that file, not this one, to know what exists.

Verify: push a stack under `vps/<key>/stacks/`, watch the run, then
`vps/shared/snapshot-host.sh bp-<key>`.

---

## Branch B — add a stack to an existing host

1. **`vps/<host>/stacks/<stack>/docker-compose.yml`.** Copy the closest working
   stack on any host rather than inventing a shape. Traefik labels, the external
   proxy network, and `${ENV_NAME}` in container/volume/network names all follow
   the neighbours.

2. **Secrets → `vps/<host>/stacks/<stack>/ci/`**, never into the workflow. Every
   file under `ci/` is a template with `@@MARKER@@` placeholders; its path under
   `ci/` is its destination path under `/root/stacks/<dir>/`.
   `vps/vps3-prod/stacks/gsc-mcp/ci/` is the canonical example.

   | File under `ci/` | Lands as | For |
   |---|---|---|
   | `.env.<service>`, `*.yaml`, `credentials/sa-key.json` | same path in the stack dir | files the compose mounts |
   | `env.ci` | merged **into** `.env` | keys the compose interpolates |
   | `post-sync.sh` | run in the stack dir before `compose up` | the `mkdir`/`chown`/`chmod` the stack needs |

3. **Add each `@@MARKER@@` to two places**: the `env:` block of the *Sync and deploy*
   step in `.github/workflows/deploy-infra.yml`, and the host's GitHub Environment
   (or org level if genuinely host-independent). An unset or empty marker **fails
   the deploy** — deliberate. Nothing else in the workflow may change; it names no
   stack.

4. **Check `.gitignore` did not swallow the templates.** `.env.*` and
   `credentials/sa-key.json` are ignored globally, with narrow `!**/ci/` negations.
   Confirm with `git status --porcelain vps/<host>/stacks/<stack>/ci/` — silently
   untracked templates ship a CI that renders nothing.

5. **Check host-side ownership** if the stack dir already exists on the host:
   `ssh bp-<host> 'stat -c "%U:%G" /root/stacks/<stack>'` must be `deploy:deploy`.
   `root:root` makes the rsync fail; that is why bpvps1's `stalwart`/`traefik`/
   `wordpress` are still in `exclude`.

6. **Update `CLAUDE.md`** — What's Running, plus any note the next agent needs.

Verify:
```bash
python vps/shared/test_render_ci.py          # renderer self-check
vps/shared/snapshot-host.sh bp-<host>        # before
# push, watch the run
vps/shared/snapshot-host.sh bp-<host>        # after — diff should show only this stack
```

---

## Removing a stack

Delete the repo dir and push. The workflow runs `docker compose down --remove-orphans`
and `rm -rf /root/stacks/<dir>`. **Volumes survive** — remove them by hand on the host
if that is what you want, after checking nothing else mounts them.
