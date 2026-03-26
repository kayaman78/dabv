# DABV — Docker Automated Backup for Volumes

**Project Status**: Active | **Version**: 1.1 | **Maintained**: Yes

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-Debian%20%2F%20Ubuntu-blue)](https://ubuntu.com/)
[![Type](https://img.shields.io/badge/type-bash%20script-lightgrey)](https://www.gnu.org/software/bash/)

Bash script that backs up named Docker volumes to compressed archives on the host. Runs via [KCR](https://github.com/kayaman78/kcr), supports hot and stop-first backup modes, verifies every archive, and sends email and push notifications.

> Part of the **KDD ecosystem** — see also [KDD](https://github.com/kayaman78/kdd) for MySQL/PostgreSQL/MongoDB and [DABS](https://github.com/kayaman78/dabs) for SQLite.

---

## When to use this

Docker volumes are not filesystem paths — you cannot back them up directly with rsync or restic. DABV handles them by spinning up a temporary Alpine container, mounting the volume read-only, and writing a compressed tar archive to a host directory of your choice. From there, restic or any other tool can pick it up normally.

**Use DABV for named Docker volumes** like:
- Loki, Grafana, Prometheus data
- Application config volumes
- Any service where data lives in a `volumes:` block without a bind mount path

**Do not use DABV for:**
- Bind mounts (host directories — restic handles those directly)
- Database data directories covered by KDD (`postgres_data`, `mysql_data`, `mongo_data`) — simply skip them during `--setup`

---

## How It Works

1. On first run, `--setup` scans all named Docker volumes and writes `volumes.yaml`
2. For each volume in the config, DABV checks it exists in Docker
3. If `stop: yes`, it stops the container before backup and restarts it after — always, even on failure
4. A temporary `alpine` container mounts the volume read-only and writes a `.tar.gz` to the backup directory
5. The archive is verified: gzip integrity, tar structure, and size trend vs previous backup
6. Old backups and logs are pruned according to `RETENTION_DAYS`
7. An HTML email report is sent, plus optional Telegram and ntfy notifications

---

## Quick Start

### 1. Deploy the script

Copy `backup-volumes.sh` to your server and set `CONFIG_FILE`, `BACKUP_ROOT`, and notification settings at the top:

```bash
mkdir -p /srv/docker/dabv
cp backup-volumes.sh /srv/docker/dabv/
```

No root required — the script runs as any user in the `docker` group. Dependencies (`swaks`, `curl`, `gzip`) must be installed beforehand if not running as root.

### 2. Run setup

```bash
bash /srv/docker/dabv/backup-volumes.sh --setup
```

The wizard scans all named Docker volumes on the host. For each one it shows the volume name, the container using it, and the image. Volumes from known database images (postgres, mysql, mariadb, mongo, redis, timescaledb, postgis) are flagged with a warning — you still decide. Two questions per volume:

- **Include in backup?** `[Y/n]`
- **Stop container before backup?** `[Y/n]` — default is **yes**

At the end it writes `volumes.yaml` to `CONFIG_FILE`.

### 3. Review the config

```bash
cat /srv/docker/dabv/volumes.yaml
```

```yaml
# DABV volume config — generated 2025-01-15 10:30
# Re-run: bash backup-volumes.sh --setup
volumes:
  - name: loki_data
    container: loki-loki-1
    stop: yes
  - name: grafana_data
    container: monitoring-grafana-1
    stop: no
  - name: myapp_uploads
    container: myapp-app-1
    stop: yes
```

Edit this file directly anytime to add, remove, or change entries without re-running setup.

### 4. Test with dry run

```bash
DRY_RUN=on bash /srv/docker/dabv/backup-volumes.sh
```

Reads the config and logs what it would do — no archives created, no containers stopped.

### 5. Schedule via KCR

In Komodo, add a KCR Action:

```json
{
  "server_name": "prod-server-01",
  "commands": ["bash /srv/docker/dabv/backup-volumes.sh"]
}
```

---

## Stop vs Hot backup

| Mode | When to use |
|------|-------------|
| `stop: yes` | Service writes actively to the volume and a mid-write snapshot would be inconsistent (e.g. Loki, databases not covered by KDD) |
| `stop: no` | Volume contains static or append-only data, or the service tolerates a hot snapshot (e.g. Grafana dashboards, config files, static assets) |

When in doubt, use `yes`. The downtime is brief — only as long as the tar operation.

---

## Restic Integration

DABV writes archives to `BACKUP_ROOT` (default: `/srv/docker/dabv/backups`). Point restic at the parent directory to include everything in one pass:

```bash
restic backup /srv/docker \
  --exclude /srv/docker/dabv/backups/log \
  --exclude /var/lib/docker/volumes
```

This way:
- KDD dump files are picked up under `/srv/docker/kdd/dump`
- DABS archives are picked up under `/srv/docker/dabs/backups`
- DABV archives are picked up under `/srv/docker/dabv/backups`
- Raw Docker volume directories under `/var/lib/docker/volumes` are excluded — DABV already archived them cleanly

---

## Directory Structure

```
/srv/docker/dabv/
├── backup-volumes.sh
└── backups/
    ├── loki_data/
    │   ├── dump-20250115_030001.tar.gz
    │   └── dump-20250116_030001.tar.gz
    ├── grafana_data/
    │   └── dump-20250116_030001.tar.gz
    └── log/
        ├── backup-volumes_20250115.log
        └── backup-volumes_20250116.log
```

---

## Configuration Reference

| Parameter | Description | Default |
|-----------|-------------|---------|
| `DRY_RUN` | `on` = simulate without writing | `off` |
| `BACKUP_ROOT` | Where archives are stored | `/srv/docker/dabv/backups` |
| `RETENTION_DAYS` | Days to keep backups and logs | `7` |
| `STOP_TIMEOUT` | Seconds to wait for container stop | `60` |
| `SIZE_DROP_WARN` | % size drop that triggers a verify warning | `20` |
| `CONFIG_FILE` | Path to the YAML config generated by `--setup` | `/srv/docker/dabv/volumes.yaml` |
| `SMTP_SERVER` | SMTP host | — |
| `SMTP_PORT` | SMTP port | `587` |
| `SMTP_USER` | SMTP username (empty = unauthenticated) | — |
| `SMTP_PASS` | SMTP password | — |
| `EMAIL_FROM` | Sender address | — |
| `EMAIL_TO` | Recipient address | — |
| `EMAIL_SUBJECT_PREFIX` | Email subject prefix | `Volume Backup` |
| `TELEGRAM_ENABLED` | Enable Telegram notifications | `false` |
| `TELEGRAM_TOKEN` | Bot token | — |
| `TELEGRAM_CHAT_ID` | Chat or channel ID | — |
| `NTFY_ENABLED` | Enable ntfy notifications | `false` |
| `NTFY_URL` | ntfy server URL | — |
| `NTFY_TOPIC` | ntfy topic | — |
| `NOTIFY_ATTACH_LOG` | Attach log to push notifications | `false` |

---

## Updating

The script logic and your configuration live in the same file (`backup-volumes.sh`). Your volume list lives separately in `volumes.yaml` and is never touched by an update.

**1. Save your current configuration**

Your settings are at the top of the script (everything above the `KNOWN DATABASE IMAGES` block). Copy that section before replacing the file.

**2. Replace the script**

```bash
curl -sL https://raw.githubusercontent.com/kayaman78/dabv/main/backup-volumes.sh \
  -o /srv/docker/dabv/backup-volumes.sh
```

**3. Re-apply your settings**

Paste your configuration block back at the top of the new script. Your `volumes.yaml` is untouched.

---

### Updating from Komodo (recommended)

Create a KCR Action to handle the download step on each server:

```json
{
  "server_name": "your-server",
  "commands": [
    "cp /srv/docker/dabv/backup-volumes.sh /srv/docker/dabv/backup-volumes.sh.bak",
    "curl -sL https://raw.githubusercontent.com/kayaman78/dabv/main/backup-volumes.sh -o /srv/docker/dabv/backup-volumes.sh.new"
  ]
}
```

Download the new version alongside the old one, diff them to see only what changed (see the [Changelog](#changelog)), and apply the code changes manually — your configuration block and `volumes.yaml` stay untouched.

> **Tip**: Duplicate this Action for each server you manage, changing only `server_name`.

---

## Changelog

### v1.1
- Fixed missing `gzip` dependency — `gzip -t` is used in backup verification but was not checked or auto-installed
- Removed redundant `docker` availability check that ran after it was already confirmed working
- Added `gzip` to the dependency list in documentation

### v1.0
- Initial release
- Named volume backup via temporary Alpine container (read-only mount)
- Interactive `--setup` wizard: scans volumes, flags DB images, writes `volumes.yaml`
- Stop/hot backup mode per volume — default stop, configurable per entry
- Three-step verification: gzip integrity, tar structure, size trend
- Retention for backups and logs
- HTML email report with Volume / Mode / Size / Backup / Verify columns
- Telegram and ntfy push notifications
- No root required if user is in the `docker` group and deps are pre-installed

---

## Related Projects

| Tool | Purpose |
|------|---------|
| [KDD](https://github.com/kayaman78/kdd) | MySQL / MariaDB / PostgreSQL / MongoDB backup via Komodo Action |
| [DABS](https://github.com/kayaman78/dabs) | SQLite backup for databases on the Docker host |
| [KCR](https://github.com/kayaman78/kcr) | Komodo Action template to run shell commands on remote servers |

---

## License

MIT — see [LICENSE](LICENSE)