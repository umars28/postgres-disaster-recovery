#!/usr/bin/env bash
source "$(dirname "$0")/../lib.sh"

REPO=${REPO:-2}
S=pitr-drop-table
RP=sebelum-drop-blobs

marker() { q -c "INSERT INTO events(payload) VALUES ('$1')"; }
has() { [ "$(qs -c "SELECT count(*) FROM events WHERE payload = '$1'")" = 1 ]; }
blobs() { "$1" -c "SELECT count(*) FROM blobs"; }

pg_start
workload_stop
q -c "DELETE FROM events WHERE payload IN ('antara', 'setelah')"
expected=$(blobs q)
[ "$expected" -gt 0 ] || die "tabel blobs kosong, jalankan seed-large.sh"

q -c "SELECT pg_create_restore_point('$RP')" >/dev/null
marker antara
xid=$(q -c BEGIN -c "DROP TABLE blobs" -c "SELECT pg_current_xact_id()" -c COMMIT)
marker setelah
log "restore point '$RP', DROP TABLE blobs di xid $xid"
wait_archived

log "A: restore ke scratch, berhenti tepat sebelum xid $xid"
t0=$(now)
scratch_restore --repo="$REPO" --type=xid --target="$xid" --target-exclusive --target-action=promote
t1=$(now)
[ "$(blobs qs)" = "$expected" ] || die "xid: blobs tidak utuh"
has antara || die "xid: commit sebelum DROP ikut hilang"
! has setelah || die "xid: commit setelah DROP ikut ter-restore"
record "$S" xid_rto_s "$(since "$t0" "$t1")"

log "B: restore ke scratch sampai restore point '$RP'"
t0=$(now)
scratch_restore --repo="$REPO" --type=name --target="$RP" --target-action=promote
t1=$(now)
[ "$(blobs qs)" = "$expected" ] || die "name: blobs tidak utuh"
! has antara || die "name: commit setelah restore point ikut ter-restore"
record "$S" name_rto_s "$(since "$t0" "$t1")"

log "salin blobs dari scratch ke prod, commit lain di prod tetap utuh"
t0=$(now)
dc exec -T -u postgres scratch pg_dump -Fc -t blobs postgres | dc exec -T -u postgres pg pg_restore -d postgres
t1=$(now)
[ "$(blobs q)" = "$expected" ] || die "prod: blobs tidak utuh setelah copy"
[ "$(q -c "SELECT count(*) FROM events WHERE payload IN ('antara', 'setelah')")" = 2 ] || die "prod: commit lain hilang"
scratch_reset

record "$S" copy_back_s "$(since "$t0" "$t1")"
record "$S" blobs_rows "$expected"
echo
