# DABV — Docker Automated Backup for Volumes

**Project Status**: Active | **Version**: 1.0 | **Maintained**: Yes

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
- Database data directories covered by KDD (`postgres_data`, `mysql_data`, `mongo_data`) — add them to `EXCLUDED_VOLUMES`

---

## How It Works

1. For each job in `VOLUME_JOBS`, DABV checks if the volume exists
2. If `stop_required = yes`, it stops the container before backup and restarts it after
3. A temporary `alpine` container mounts the volume read-only and writes a `.tar.gz` to the backup directory
4. The archive is verified: gzip integrity, tar structure, and size trend vs previous backup
5. Old backups and logs are pruned according to `RETENTION_DAYS`
6. An HTML email report is sent, plus optional Telegram and ntfy notifications

---

## Quick Start

### 1. Find your volumes

```bash
# List all named volumes
docker volume ls

# Find which container uses a specific volume
docker ps --format '{{.Names}}' | xargs -I{} docker inspect {} \
  --format '{{.Name}}: {{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}'
```

### 2. Configure the script

Copy `backup-volumes.sh` to your server (e.g. `/srv/docker/dabv/`) and edit the top section:

```bash
VOLUME_JOBS=(
    "loki_data|loki-loki-1|yes"
    "grafana_data|monitoring-grafana-1|no"
    "gitea_data|gitea-server-1|no"
)

EXCLUDED_VOLUMES=("postgres_data" "mysql_data" "mongo_data")
```

Each job is `"volume_name|container_name|stop_required"`:

| Field | Description |
|-------|-------------|
| `volume_name` | Exact name from `docker volume ls` |
| `container_name` | Container to stop/start — from `docker ps --format '{{.Names}}'`. Use `none` if stop not needed |
| `stop_required` | `yes` = stop before backup, `no` = backup while running |

### 3. Test with dry run

```bash
# Set DRY_RUN="on" at the top of the script, then:
sudo bash /srv/docker/dabv/backup-volumes.sh
```

Dry run scans and reports without creating any files or stopping any containers.

### 4. Run via KCR

In Komodo, add a KCR Action that calls the script:

```json
{
  "server_name": "prod-server-01",
  "commands": ["sudo bash /srv/docker/dabv/backup-volumes.sh"]
}
```

---

## Stop vs Hot backup

| Mode | When to use |
|------|-------------|
| `stop_required: yes` | Service writes actively to the volume and a mid-write snapshot would be inconsistent (e.g. Loki, databases not covered by KDD) |
| `stop_required: no` | Volume contains static or append-only data, or the service tolerates a hot snapshot (e.g. Grafana dashboards, config files, static assets) |

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
| `VOLUME_JOBS` | List of volumes to back up | `()` |
| `EXCLUDED_VOLUMES` | Volumes to always skip | `()` |
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

## Changelog

### v1.0
- Initial release
- Named volume backup via temporary Alpine container (read-only mount)
- Stop/hot backup modes per volume
- Three-step verification: gzip integrity, tar structure, size trend
- Retention for backups and logs
- HTML email report with Volume / Mode / Size / Backup / Verify columns
- Telegram and ntfy push notifications

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