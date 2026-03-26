# DABV — Docker Automated Backup for Volumes

## Scopo
Script Bash che backuppa named Docker volumes montandoli read-only in un container Alpine temporaneo e creando archivi tar.gz. Supporta stop pre-backup per volumi sensibili.

## File
- `backup-volumes.sh` — script principale (backup + setup wizard integrato)
- `README.md` — documentazione utente
- `volumes.yaml` — config generata da `--setup` (non in repo, creata on-site)

## Modalità operative
```bash
bash backup-volumes.sh --setup     # wizard interattivo → genera volumes.yaml
DRY_RUN=on bash backup-volumes.sh  # simulazione senza modifiche
bash backup-volumes.sh             # backup production
```

## Flusso principale
**Setup phase (`--setup`):**
1. Scansiona tutti named volumes Docker
2. Per ogni volume: estrae container, image, flags DB images (postgres/mysql/mongo/redis...)
3. Prompt user: include? stop before backup?
4. Scrive `volumes.yaml`

**Backup phase:**
1. Legge `volumes.yaml` via parser YAML puro bash (no yq required)
2. Per ogni volume: (se `stop: yes`) docker stop → `docker run alpine tar czf` con volume montato read-only → docker start
3. Verifica 3-step
4. Retention cleanup con `-mtime +"$((RETENTION_DAYS - 1))"`
5. Notifiche

## Verifica 3-step
1. `gzip -t` — integrità archivio
2. `tar tzf` — struttura tar leggibile
3. Confronto size vs backup precedente — warning se calo > `SIZE_DROP_WARN`%

## Config `volumes.yaml`
```yaml
volumes:
  - name: loki_data
    container: loki-loki-1
    stop: yes
  - name: grafana_data
    container: monitoring-grafana-1
    stop: no
```

## Variabili script
```bash
DRY_RUN="off"
CONFIG_FILE="/srv/docker/dabv/volumes.yaml"
BACKUP_ROOT="/srv/docker/dabv/backups"
RETENTION_DAYS=7
STOP_TIMEOUT=60
SIZE_DROP_WARN=20

# SMTP via swaks, Telegram, ntfy (stessa struttura di DABS)
```

## Output struttura
```
BACKUP_ROOT/
├── <volume-name>/
│   └── dump-YYYYMMDD_HHMMSS.tar.gz
└── log/
    └── backup-volumes_YYYYMMDD.log
```

## Dipendenze (auto-installate se root, altrimenti errore)
`swaks`, `curl`, `gzip` — non richiede root se user è nel gruppo `docker`

## Note importanti
- Backuppa **solo named volumes** (no bind mounts — by design)
- Il container Alpine viene creato/rimosso ad ogni run (no stato persistente)
- Il mount è sempre read-only: nessun rischio di corruzione durante tar
- Parser YAML bash puro: nessuna dipendenza esterna per la config
- Docker disponibilità verificata una sola volta (`docker ps`) all'avvio — nessun check ridondante

## Integrazione nell'ecosistema
Viene lanciato da **KCR** come action schedulata:
```json
{
  "server_name": "prod",
  "commands": ["bash /srv/docker/dabv/backup-volumes.sh"]
}
```

## Coerenza con l'ecosistema
- Retention: usa `-mtime +"$((RETENTION_DAYS - 1))"` — identico a DABS
- Notifiche: struttura `send_telegram` / `send_ntfy` / `build_text_summary` — identica a DABS
- Email: via `swaks` — identico a DABS (KDD usa `msmtp`)

## Non implementato (by design o low-priority)
- Bind mounts support
- Pattern di esclusione file dentro il volume
- Parallel backup (sequenziale per safety)
