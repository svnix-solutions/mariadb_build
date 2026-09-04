#!/bin/bash
# Nightly logical backup of the whole MariaDB instance to the NAS.
#
# Same correctness guards as the postgres job:
#   - pipefail on, so a mariadb-dump failure mid-stream fails the job instead
#     of leaving a valid gzip of a truncated dump.
#   - Written to .partial and renamed only after gzip -t verifies it.
#   - Sentinel check aborts if the NAS is not mounted, rather than filling the
#     node's local disk.

# bash, not sh: this image is Ubuntu-based so /bin/sh is dash, which has no
# pipefail. Without pipefail a mariadb-dump failure mid-stream would leave a
# valid gzip of a truncated dump.
set -eu
set -o pipefail

DEST="${BACKUP_DEST:-/backup}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
SENTINEL="$DEST/.dbbackup-target"

if [ ! -f "$SENTINEL" ]; then
  echo "FATAL: $SENTINEL is missing." >&2
  echo "The NAS is almost certainly not mounted at $DEST. Refusing to write" >&2
  echo "backups to what is probably the node's local disk." >&2
  exit 1
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$DEST/mariadb-alldb-${TS}.sql.gz"
TMP="${OUT}.partial"

echo "==> mariadb-dump from ${MARIADB_HOST} as ${MARIADB_USER}"
# --single-transaction gives a consistent snapshot of InnoDB tables without
# locking writers. --all-databases includes the mysql schema, so accounts and
# grants are captured too.
mariadb-dump \
  --host="$MARIADB_HOST" \
  --user="$MARIADB_USER" \
  --all-databases \
  --single-transaction \
  --routines \
  --events \
  --triggers \
  --default-character-set=utf8mb4 \
  | gzip -c > "$TMP"

echo "==> verifying archive"
gzip -t "$TMP"

mv "$TMP" "$OUT"
echo "==> wrote $OUT ($(du -h "$OUT" | cut -f1))"

echo "==> pruning dumps older than ${RETENTION_DAYS} days"
find "$DEST" -maxdepth 1 -type f -name 'mariadb-alldb-*.sql.gz' -mtime "+${RETENTION_DAYS}" -print -delete || true
find "$DEST" -maxdepth 1 -type f -name '*.partial' -mtime +1 -print -delete || true

echo "==> backups on the target:"
ls -lh "$DEST"/mariadb-alldb-*.sql.gz 2>/dev/null | tail -20 || echo "(none)"
echo "==> free space:"
df -h "$DEST" | tail -1
