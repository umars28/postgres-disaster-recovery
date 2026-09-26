#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"

REPO=${REPO:-2}
S=old-timeline
RP=titik-pitr-salah

marker() { q -c "INSERT INTO events(payload) VALUES ('$1')"; }
has() { [ "$(qs -c "SELECT count(*) FROM events WHERE payload = '$1'")" = 1 ]; }
tl() { "$1" -c "SELECT timeline_id FROM pg_control_checkpoint()"; }

pg_start
workload_stop
q -c "DELETE FROM events WHERE payload IN ('hanya-di-tl-lama', 'di-tl-baru')"

q -c "SELECT pg_create_restore_point('$RP')" >/dev/null
marker hanya-di-tl-lama
wait_archived
old_tl=$(tl q)
log "timeline ${old_tl}: restore point '$RP' lalu commit 'hanya-di-tl-lama'"

log "PITR prod ke '$RP' (keputusan yang ternyata salah)"
dc stop pg >/dev/null
t0=$(now)
dc run --rm --no-deps -T -u postgres pg pgbackrest --stanza=main --repo="$REPO" --delta --process-max=4 --log-level-console=warn \
  --type=name --target="$RP" --target-action=promote restore
pg_start
t1=$(now)
new_tl=$(tl q)
[ "$new_tl" -gt "$old_tl" ] || die "PITR tidak membuat timeline baru"
[ "$(q -c "SELECT count(*) FROM events WHERE payload = 'hanya-di-tl-lama'")" = 0 ] || die "PITR tidak mundur"
marker di-tl-baru
wait_archived
record "$S" prod_pitr_delta_rto_s "$(since "$t0" "$t1")"
log "prod sekarang timeline ${new_tl}, commit 'di-tl-baru'"

log "A: restore default (timeline latest)"
scratch_restore --repo="$REPO"
has di-tl-baru || die "latest: tidak mengikuti timeline baru"
! has hanya-di-tl-lama || die "latest: seharusnya tidak punya data timeline lama"
record "$S" latest_ikut_timeline "TL${new_tl} tanpa hanya-di-tl-lama"

log "B: restore --target-timeline=${old_tl}"
t0=$(now)
scratch_restore --repo="$REPO" --target-timeline="$old_tl"
t1=$(now)
has hanya-di-tl-lama || die "timeline lama: data tidak kembali"
! has di-tl-baru || die "timeline lama: tercampur timeline baru"
record "$S" old_timeline_rto_s "$(since "$t0" "$t1")"
record "$S" old_ikut_timeline "TL${old_tl} punya hanya-di-tl-lama"
scratch_reset
echo
