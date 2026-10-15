# hermes-deploy

Run [Hermes Agent](https://github.com/NousResearch/hermes-agent) on your own VPS with one command, and be
able to move it to another host in minutes. It is a thin wrapper around the official Docker image, not a fork:
a `compose.yaml` and one script, `manage.sh`, that handles install, backup, restore and updates.

The reason it exists: the agent's identity, memory, sessions and credentials live in one data directory. If
the VPS disappears (free tiers do that), a container restart doesn't bring the agent back, a backup does.

Unofficial; not affiliated with Nous Research.

## Quick start

```bash
git clone https://github.com/zyrridian/hermes-deploy hermes-deploy
cd hermes-deploy
./manage.sh install
```

`install` is safe to re-run. It will:

1. Install Docker if it's missing (asks first; uses Docker's official `get.docker.com` script).
2. Create `.env` from `.env.example`.
3. Pull the Hermes image and pin the exact digest in `.env`, so redeploys are reproducible.
4. Run the interactive setup wizard (model API key, chat platform) if the agent isn't configured yet.
5. Start the agent and check that it stays up.
6. Offer to schedule a daily backup via cron.

Use SSH rather than a provider's browser console: those consoles can mangle pasted characters like `:` and `@`.

**Requirements:** Linux with bash and curl, root or sudo for the Docker install, 2 vCPU / 4 GB RAM recommended
(1 GB works without browser tools, 2 GB+ with them), a few GB of disk.

## Commands

| Command | What it does |
| --- | --- |
| `./manage.sh install [--yes] [--restore FILE]` | Everything above; with `--restore`, restores a backup instead of running the wizard |
| `./manage.sh status` | Container state, image pin, exposed ports, disk, last backup |
| `./manage.sh logs` | Follow logs |
| `./manage.sh start \| stop \| restart` | Control the container |
| `./manage.sh backup [--hot]` | Archive all agent state (see below) |
| `./manage.sh restore FILE [--yes] [--no-start]` | Restore an archive |
| `./manage.sh update [--rollback]` | Back up, pull, re-pin, verify; roll back if unhealthy |
| `./manage.sh setup` | Re-run the setup wizard |
| `./manage.sh hermes <args>` | Run the `hermes` CLI in the container, e.g. `./manage.sh hermes profile create work` |

## Backups

`./manage.sh backup` writes `backups/hermes-<UTC time>.tar.gz` (plus a `.sha256`) containing the whole data
directory: `.env` with your API keys, config, memory, sessions, skills. It stops the agent for a few
seconds so the SQLite database is consistent; `--hot` skips that at the cost of possible inconsistency.
The last 14 backups are kept (`BACKUP_KEEP`).

Because archives contain your keys, **encrypt them** before copying them anywhere:

```bash
age-keygen -o ~/hermes-backup-key.txt      # keep this file OFF the server
# put the printed public key in .env:
BACKUP_AGE_RECIPIENT=age1...
```

To copy backups off the machine, configure an [rclone](https://rclone.org) remote and set
`BACKUP_RCLONE_REMOTE=myremote:hermes-backups` in `.env`.

## Moving to another provider

```bash
# old host
./manage.sh backup                         # then copy the archive (and .sha256) to the new host

# new host
git clone https://github.com/zyrridian/hermes-deploy hermes-deploy && cd hermes-deploy
export BACKUP_AGE_IDENTITY=~/hermes-backup-key.txt      # only for encrypted archives
./manage.sh install --restore path/to/hermes-<time>.tar.gz.age
```

Then stop the agent on the old host: two gateways on the same data or bot token will fight each other.
Existing data on the target is moved to `data.pre-restore-<time>`, never deleted.
Try a restore on a throwaway VM once so you know it works before you need it.

## Updating

`HERMES_TRACK` in `.env` (default `nousresearch/hermes-agent:stable`) is the tag that `update` follows;
use an `X.Y.Z` tag to move only when you decide to. `./manage.sh update` takes a backup, pulls the tag, pins
the new digest, restarts, and goes back to the previous image automatically if the new one doesn't stay up.
`./manage.sh update --rollback` reverts by hand. Caveat: newer Hermes versions migrate `config.yaml` on start,
so if a rollback misbehaves, restore the pre-update backup.

## Security

- The API port (8642) is published on `127.0.0.1` only, and the dashboard is off. Reach them through an SSH tunnel
  (`ssh -L 8642:127.0.0.1:8642 you@host`) or an authenticated reverse proxy. Hermes refuses a non-loopback
  dashboard without an auth provider; don't work around that.
- The Docker socket is never mounted into the container; access to it is host-root access.
- `.env`, `data/`, `backups/` and keys are git-ignored.
- This repo does not touch SSH or the firewall. Use key-only SSH and a firewall (e.g. `ufw`) as you normally would.

## Customizing

Docker Compose automatically merges a `compose.override.yaml` next to `compose.yaml`, so local changes
(enable the dashboard, add a bind mount, use a derived image with extra packages) don't touch tracked files.
`HERMES_DATA_DIR`, `BACKUP_DIR`, `HERMES_MEM_LIMIT` and friends are documented in `.env.example`.

## Troubleshooting

- **Permission denied on `data/`:** the container owns it (UID 10000). That's expected; `backup`/`restore` work through
  the container. For a bind mount owned by another user, set `PUID`/`PGID` in `compose.override.yaml`.
- **`status` says the image isn't pinned:** run `./manage.sh update` or `install` once.
- **Container restarts in a loop:** `./manage.sh logs`. The usual cause is no model/API key; run `./manage.sh setup`.
- **After `install` added you to the docker group:** log out and back in, then re-run `./manage.sh install`.

## Scope

One agent per host, Docker Compose only.

Status: backup and restore are covered by an automated round-trip test (`test/roundtrip.sh`, run in CI).
`install` and `update` drive the official image's documented interfaces; try them on a throwaway VPS first.

## License

MIT. See [LICENSE](LICENSE) and [CONTRIBUTING.md](CONTRIBUTING.md).
