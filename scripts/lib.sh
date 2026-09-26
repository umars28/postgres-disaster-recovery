set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RUNS=runs
ACK=$RUNS/acked.csv
mkdir -p "$RUNS"

dc() { docker compose "$@"; }
q() { dc exec -T -u postgres pg psql -Atq -v ON_ERROR_STOP=1 "$@"; }
qs() { dc exec -T -u postgres scratch psql -Atq -v ON_ERROR_STOP=1 "$@"; }
pgbr() { dc exec -T -u postgres pg pgbackrest --stanza=main --log-level-console=warn "$@"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
since() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b - a }'; }
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "GAGAL: $*"; exit 1; }

project() { docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$(dc ps -aq pg)"; }

volume_rm() {
  local v
  v=$(docker volume ls -q --filter "label=com.docker.compose.project=$(project)" --filter "label=com.docker.compose.volume=$1")
  [ -z "$v" ] || docker volume rm "$v" >/dev/null
}

wait_promoted() {
  local fn=$1 limit=${2:-900} i=0
  until [ "$($fn -c 'SELECT pg_is_in_recovery()' 2>/dev/null)" = f ]; do
    i=$((i + 1))
    [ "$i" -le "$((limit * 2))" ] || die "$fn tidak promote dalam ${limit}s"
    sleep 0.5
  done
}

pg_start() {
  dc up -d --wait pg
  wait_promoted q
  q -c CHECKPOINT >/dev/null
}

wait_archived() {
  local wal
  wal=$(q -c "SELECT pg_walfile_name(pg_switch_wal())")
  until [ "$(q -c "SELECT last_archived_wal >= '$wal' AND NOT EXISTS (SELECT 1 FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready') FROM pg_stat_archiver")" = t ]; do
    sleep 1
  done
}

scratch_reset() {
  dc rm -fsv scratch >/dev/null 2>&1 || true
  volume_rm scratchdata
}

scratch_restore() {
  scratch_reset
  dc run --rm --no-deps -T -u postgres scratch pgbackrest --stanza=main --process-max=4 --log-level-console=warn "$@" restore
  dc up -d --wait scratch
  wait_promoted qs
}

workload_start() {
  : > "$ACK"
  dc up -d --force-recreate workload
}

workload_stop() {
  dc stop workload >/dev/null 2>&1 || true
}

ack_rpo() {
  local fn=${1:-q}
  {
    echo "CREATE TEMP TABLE acked (id bigint, ts float8);"
    echo "COPY acked FROM STDIN WITH (FORMAT csv);"
    cat "$ACK"
    echo '\.'
    echo "SELECT count(*),
                 count(*) FILTER (WHERE e.id IS NULL),
                 round((max(a.ts) - coalesce(max(a.ts) FILTER (WHERE e.id IS NOT NULL), min(a.ts)))::numeric, 3)
          FROM acked a LEFT JOIN events e USING (id);"
  } | "$fn" -F' '
}

record() {
  local file=$RUNS/chaos.csv
  [ -f "$file" ] || echo "run_at,scenario,metric,value" > "$file"
  echo "$(date -u +%FT%TZ),$1,$2,$3" >> "$file"
  printf '  %-28s %s\n' "$2" "$3"
}
