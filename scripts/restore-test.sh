#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=${REPO:-2}
PROCESS_MAX=${PROCESS_MAX:-1}
PUSHGATEWAY=${PUSHGATEWAY:-http://127.0.0.1:19091}
RESULTS=runs/rto.csv

dc() { docker compose "$@"; }
qs() { dc exec -T -u postgres scratch psql -Atq -v ON_ERROR_STOP=1 "$@"; }
qp() { dc exec -T -u postgres pg psql -Atq -v ON_ERROR_STOP=1 "$@"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
since() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b - a }'; }
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

success=0 restore_s=0 recovery_s=0 sanity_s=0 rto_s=0 rows=0 lag_s=0 backup_label=unknown

cleanup() {
  dc rm -fsv scratch >/dev/null 2>&1 || true
  docker volume rm "$(docker volume ls -q --filter "label=com.docker.compose.project=$project" --filter label=com.docker.compose.volume=scratchdata)" >/dev/null 2>&1 || true
}

report() {
  cleanup
  local ts
  ts=$(date +%s)
  {
    echo "restore_test_success $success"
    echo "restore_test_rto_seconds $rto_s"
    echo "restore_test_duration_seconds{phase=\"restore\"} $restore_s"
    echo "restore_test_duration_seconds{phase=\"recovery\"} $recovery_s"
    echo "restore_test_duration_seconds{phase=\"sanity\"} $sanity_s"
    echo "restore_test_rows $rows"
    echo "restore_test_data_lag_seconds $lag_s"
    echo "restore_test_last_run_timestamp_seconds $ts"
    if [ "$success" = 1 ]; then echo "restore_test_last_success_timestamp_seconds $ts"; fi
  } | curl -fsS --data-binary @- "$PUSHGATEWAY/metrics/job/restore_test/repo/repo$REPO" || log "push ke pushgateway gagal"
  [ -f "$RESULTS" ] || echo "run_at,repo,backup,success,rto_s,restore_s,recovery_s,sanity_s,rows,data_lag_s" > "$RESULTS"
  echo "$(date -u +%FT%TZ),repo$REPO,$backup_label,$success,$rto_s,$restore_s,$recovery_s,$sanity_s,$rows,$lag_s" >> "$RESULTS"
  cat <<EOF

  repo / backup      repo${REPO} / ${backup_label}
  sukses             ${success}
  restore            ${restore_s}s
  recovery+promote   ${recovery_s}s
  RTO                ${rto_s}s
  sanity check       ${sanity_s}s
  baris events       ${rows}
  tertinggal dari pg ${lag_s}s

EOF
}

mkdir -p runs
dc up -d --wait pg
project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$(dc ps -q pg)")
trap report EXIT
cleanup

backup_label=$(dc exec -T -u postgres pg pgbackrest --stanza=main --repo="$REPO" --output=json info \
  | perl -MJSON::PP -e 'my $i = decode_json(join "", <STDIN>); print $i->[0]{backup}[-1]{label} // "none"')

t0=$(now)
log "restore ${backup_label} dari repo${REPO} ke container scratch"
dc run --rm --no-deps -T -u postgres scratch pgbackrest --stanza=main --repo="$REPO" --process-max="$PROCESS_MAX" --log-level-console=warn restore
t1=$(now)
restore_s=$(since "$t0" "$t1")

log "recovery sampai ujung archive lalu promote"
dc up -d --wait scratch
until [ "$(qs -c 'SELECT pg_is_in_recovery()')" = f ]; do sleep 0.5; done
t2=$(now)
recovery_s=$(since "$t1" "$t2")
rto_s=$(since "$t0" "$t2")
prod_max=$(qp -c "SELECT coalesce(extract(epoch FROM max(created_at)), 0) FROM events")

log "sanity check"
dc exec -T -u postgres scratch pg_amcheck --install-missing --heapallindexed --all
read -r rows restored_max <<<"$(qs -F' ' -c "SELECT count(*), coalesce(extract(epoch FROM max(created_at)), 0) FROM events")"
[ "$rows" -gt 0 ]
lag_s=$(since "$restored_max" "$prod_max")
qs -c "CREATE TEMP TABLE t AS SELECT 1; INSERT INTO t VALUES (2)" >/dev/null
t3=$(now)
sanity_s=$(since "$t2" "$t3")

success=1
