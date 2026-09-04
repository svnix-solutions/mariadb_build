# mariadb_build

Komodo stack running **MariaDB 11.4** with **phpMyAdmin**, plus a scheduled
logical backup job.

---

## Storage layout

The data directory lives on a **local Docker volume**, never on network
storage — the same reasoning as [postgres_build](https://github.com/svnix-solutions/postgres_build):
databases need reliable `fsync` and file locking, which NFS does not
dependably provide.

The NAS is used for **backups only**.

```
  mariadb_data volume  ──►  local disk   (datadir)
  DBBACKUP_PATH        ──►  NAS over NFS (dumps)
```

---

## Services

| Service | Image | Port | Purpose |
| --- | --- | --- | --- |
| `mariadb` | `mariadb:11.4` | 3306 | the database |
| `phpmyadmin` | `phpmyadmin:5` | 8080 → 80 | web admin UI |
| `backup` | `mariadb:11.4` | — | one-off dump job (compose profile `backup`) |

---

## A note on phpMyAdmin logins

phpMyAdmin has **no user store of its own** — it authenticates directly
against MariaDB. Out of the box that means logging in as `root`, which is
full control of the server for anyone who reaches the UI.

Provision least-privilege accounts before this carries anything real, and put
an authenticating proxy in front of the UI if it is reachable from outside the
host.

---

## Charset

The server runs `utf8mb4` / `utf8mb4_unicode_ci` with
`--character-set-client-handshake=FALSE`.

That last flag is not decoration: it stops a client negotiating its own
charset. Frappe/ERPNext requires it — without it `bench new-site` can create a
`utf8` database that silently mangles emoji and non-Latin text, and you find
out much later.

## Setup

```bash
cp .env.example .env    # then edit it
docker network create db 2>/dev/null || true
docker compose up -d
```

`DBBACKUP_PATH` must point at an **already-mounted** backup volume containing
a sentinel file:

```bash
echo "sentinel" > /mnt/dbbackup/.dbbackup-target
```

Both ports default to `127.0.0.1`. Set `MARIADB_BIND` / `PMA_BIND` to a LAN
address to reach them from other hosts.

---

## Backups

```bash
docker compose --profile backup run --rm backup
```

Output is `mariadb-alldb-<UTC timestamp>.sql.gz`, pruned after
`BACKUP_RETENTION_DAYS`.

`mariadb-dump` runs with `--single-transaction`, so InnoDB is snapshotted
consistently without locking writers, and `--all-databases`, so the `mysql`
schema comes too — accounts and grants restore with the data. The password is
passed via `MYSQL_PWD` so it never appears in the process list.

### What the script guards against

| Guard | Failure it prevents |
| --- | --- |
| `set -o pipefail` | `mariadb-dump` dies mid-stream, `gzip` still exits 0, and you get a **valid archive of half a database** |
| write to `.partial`, `gzip -t`, then rename | an interrupted run leaves a file that looks complete |
| sentinel file check | the NAS is not mounted, and "backups" quietly fill the node's local disk |

> The script runs under **bash**, not `sh`. This image is Ubuntu-based, so
> `/bin/sh` is dash, which has no `pipefail` — and without `pipefail` the first
> guard above silently does nothing.

### Restoring

**Destructive:**

```bash
gunzip -c /mnt/dbbackup/mariadb-alldb-<ts>.sql.gz \
  | docker exec -i mariadb mariadb -u root -p
```

---

## Files

| File | Purpose |
| --- | --- |
| `compose.yaml` | the stack definition |
| `backup.sh` | dump, verify, prune |
| `.env.example` | template for `.env` |
