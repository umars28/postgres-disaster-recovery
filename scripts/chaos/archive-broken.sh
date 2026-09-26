#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"

OUTAGE_SECONDS=${OUTAGE_SECONDS:-180}
S=archive-broken
STATE="SELECT (last_failed_time IS NOT NULL AND (last_failed_time > last_archived_time OR last_archived_time IS NULL))::int,
              (SELECT count(*) FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready'),
              (SELECT coalesce(round(extract(epoch FROM now() - min(modification))), 0) FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready'),
              (SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir())
       FROM pg_stat_archiver"

pg_start
workload_start >/dev/null 2>&1
wait_archived

log "pgbackrest stop: maintenance selesai tapi lupa start"
pgbr stop
t0=$(now)
until [ "$(q -c "$STATE" | cut -d'|' -f1)" = 1 ]; do
  q -c "SELECT pg_switch_wal()" >/dev/null
  sleep 1
done
t_detect=$(now)
log "archive_command gagal terdeteksi"

end=$(( $(date +%s) + OUTAGE_SECONDS ))
max_ready=0
while [ "$(date +%s)" -lt "$end" ]; do
  q -c "SELECT pg_switch_wal()" >/dev/null
  IFS='|' read -r _ ready oldest walsize <<<"$(q -c "$STATE")"
  [ "$ready" -gt "$max_ready" ] && max_ready=$ready
  sleep 10
done
log "selama outage: ${ready} segment antre, .ready tertua ${oldest}s, pg_wal ${walsize}"

log "pgbackrest start"
pgbr start
t_fix=$(now)
until [ "$(q -c "$STATE" | cut -d'|' -f2)" = 0 ]; do sleep 1; done
t_drain=$(now)
pgbr check

log "bukti tidak ada commit hilang: stop workload, restore ke scratch"
workload_stop
wait_archived
scratch_restore --repo=2
read -r acked lost _ <<<"$(ack_rpo qs)"
scratch_reset

echo
record "$S" detect_s "$(since "$t0" "$t_detect")"
record "$S" outage_s "$(since "$t0" "$t_fix")"
record "$S" max_segment_antre "$max_ready"
record "$S" rpo_saat_fix_s "$oldest"
record "$S" pg_wal_saat_fix "$walsize"
record "$S" drain_s "$(since "$t_fix" "$t_drain")"
record "$S" commit_ter_ack "$acked"
record "$S" commit_hilang "$lost"
echo
