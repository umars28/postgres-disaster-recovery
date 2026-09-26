#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"

RUN_SECONDS=${RUN_SECONDS:-30}
REPO=${REPO:-1}
S=pgdata-deleted

pg_start
workload_start >/dev/null 2>&1
sleep "$RUN_SECONDS"

log "rm -rf PGDATA saat server jalan"
t0=$(now)
dc exec -T pg bash -c 'rm -rf /var/lib/postgresql/data/*' || true

until ! q -c 'SELECT 1' >/dev/null 2>&1; do sleep 0.2; done
t_detect=$(now)
health=$(docker inspect -f '{{.State.Health.Status}}' "$(dc ps -aq pg)")

log "terdeteksi, kill supaya sesi lama berhenti meng-ack commit yang pasti hilang"
dc kill -s SIGKILL pg >/dev/null
t_kill=$(now)
workload_stop

log "restore dari repo${REPO}"
dc run --rm --no-deps -T -u postgres pg pgbackrest --stanza=main --repo="$REPO" --process-max=4 --log-level-console=warn restore
pg_start
t_up=$(now)
pgbr check

read -r acked lost rpo <<<"$(ack_rpo)"

echo
record "$S" detect_s "$(since "$t0" "$t_detect")"
record "$S" health_saat_deteksi "$health"
record "$S" rto_s "$(since "$t_detect" "$t_up")"
record "$S" commit_ter_ack "$acked"
record "$S" commit_hilang "$lost"
record "$S" rpo_s "$rpo"
echo
