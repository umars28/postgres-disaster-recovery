#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

RUN_SECONDS=${RUN_SECONDS:-90}
REPO=${REPO:-2}
RUNS=runs
ACK=$RUNS/acked.csv
RESULTS=$RUNS/rpo.csv

dc() { docker compose "$@"; }
q() { dc exec -T -u postgres pg psql -Atq -v ON_ERROR_STOP=1 "$@"; }
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

mkdir -p "$RUNS"
: > "$ACK"

log "start pg + cek archiving"
dc up -d --wait pg
q -c CHECKPOINT
dc exec -T -u postgres pg pgbackrest --stanza=main --log-level-console=warn check
project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$(dc ps -q pg)")
archive_timeout=$(q -c "SELECT setting FROM pg_settings WHERE name = 'archive_timeout'")

log "workload jalan ${RUN_SECONDS}s (archive_timeout=${archive_timeout}s)"
dc up -d --force-recreate workload
sleep "$RUN_SECONDS"

pre=$(q -F' ' -c "SELECT last_archived_wal, extract(epoch FROM last_archived_time), extract(epoch FROM now()) FROM pg_stat_archiver")
read -r last_wal last_archived_epoch crash_epoch <<<"$pre"

log "SIGKILL pg, hapus pgdata + repo1 lokal + log"
dc kill -s SIGKILL pg
dc rm -fs pg workload >/dev/null
for v in pgdata pgbackrest pglog; do
  docker volume rm "$(docker volume ls -q --filter "label=com.docker.compose.project=$project" --filter "label=com.docker.compose.volume=$v")" >/dev/null
done

log "restore dari repo${REPO}"
dc run --rm --no-deps -T -u postgres pg pgbackrest --stanza=main --repo="$REPO" --log-level-console=warn restore
dc up -d --wait pg
until [ "$(q -c 'SELECT pg_is_in_recovery()')" = f ]; do sleep 1; done
q -c CHECKPOINT

log "stanza-create untuk repo1 yang kosong + check"
dc exec -T -u postgres pg pgbackrest --stanza=main --log-level-console=warn stanza-create
dc exec -T -u postgres pg pgbackrest --stanza=main --log-level-console=warn check

result=$({
  echo "CREATE TEMP TABLE acked (id bigint, ts float8);"
  echo "COPY acked FROM STDIN WITH (FORMAT csv);"
  cat "$ACK"
  echo '\.'
  echo "SELECT count(*),
               count(*) FILTER (WHERE e.id IS NULL),
               round((max(a.ts) - coalesce(max(a.ts) FILTER (WHERE e.id IS NOT NULL), min(a.ts)))::numeric, 3),
               round(max(a.ts)::numeric, 3)
        FROM acked a LEFT JOIN events e USING (id);"
} | q -F' ')
read -r acked lost rpo last_ack_epoch <<<"$result"

gap=$(awk -v c="$crash_epoch" -v a="$last_archived_epoch" 'BEGIN { printf "%.3f", c - a }')

[ -f "$RESULTS" ] || echo "run_at,archive_timeout_s,acked_rows,lost_rows,rpo_s,crash_minus_last_archive_s,last_archived_wal" > "$RESULTS"
echo "$(date -u +%FT%TZ),$archive_timeout,$acked,$lost,$rpo,$gap,$last_wal" >> "$RESULTS"

cat <<EOF

  archive_timeout            ${archive_timeout}s
  WAL terakhir terarsip      ${last_wal}
  crash - last archive       ${gap}s
  commit ter-ack             ${acked}
  commit ter-ack yang hilang ${lost}
  RPO aktual                 ${rpo}s

EOF
