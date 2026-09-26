# Runbook PostgreSQL DR

Setiap prosedur di sini sudah dijalankan di lab dan punya script yang bisa diulang. Angka "terbukti" berasal dari DB 6,1 GB, repo terkompresi 1,5 GB, dan `process-max=4`.

Semua command dijalankan dari root repo. Singkatan yang dipakai:

```sh
pg()   { docker compose exec -T -u postgres pg "$@"; }
pgbr() { docker compose exec -T -u postgres pg pgbackrest --stanza=main "$@"; }
```

## 0. Sebelum menyentuh apa pun

1. Tentukan dulu jenis insidennya. Masing-masing punya bagian sendiri di bawah:

   | Gejala | Bagian |
   |---|---|
   | host/volume hilang | 1 |
   | datadir hilang/korup | 2 |
   | alert `PgArchiveFailing` | 3 |
   | data salah hapus/ubah | 4 |
   | PITR sebelumnya salah target | 5 |
   | recovery berhenti `FATAL` | 6 |
   | repo S3 kosong/terhapus | 7 |

2. Kalau server masih hidup tapi datanya pasti hilang, matikan server sekarang. Lihat bagian 2 untuk alasannya.
3. Pilih repo sumber:

   | Repo | Pakai kalau | Catatan |
   |---|---|---|
   | repo1 (lokal) | host dan volume `pgbackrest` masih ada | paling cepat |
   | repo2 (MinIO) | host hilang | default untuk DR |
   | repo3 (MinIO, object lock) | repo2 terhapus/terenkripsi penyerang | lihat bagian 7 |

4. Lihat backup dan rentang WAL yang tersedia:

   ```sh
   pgbr info
   ```

## 1. Server mati total

Deteksi: host dan volume tidak bisa diakses. Data yang belum terarsip ikut hilang.

```sh
docker compose up -d minio
docker compose run --rm --no-deps -T -u postgres pg pgbackrest --stanza=main --repo=2 --process-max=4 restore
docker compose up -d --wait pg
```

Lalu jalankan checklist di bagian 8. `stanza-create` wajib karena repo1 ikut hilang: tanpa itu `archive-push` gagal di repo1 dan archiving macet total.

Terbukti (`scripts/total-loss.sh`):

| archive_timeout | RPO aktual |
|---|---|
| 60s | 33.0s |
| 15s | 1.8s |
| 60s, tepat setelah restart tanpa `CHECKPOINT` | 90.2s, semua commit hilang |

## 2. PGDATA terhapus atau korup saat server jalan

Deteksi:

- koneksi baru gagal dengan `FATAL: could not open file "global/pg_filenode.map"`
- `pg_isready` tetap OK, jadi healthcheck berbasis `pg_isready` tetap hijau. Healthcheck di `compose.yaml` sudah diganti ke `SELECT 1`.

Bahaya: sesi yang sudah terbuka tetap bisa commit dan menerima ack sampai Postgres butuh segment WAL baru, lalu PANIC. Di lab ini berlangsung 22 detik. Semua commit itu ditulis ke file yang sudah di-unlink, jadi pasti hilang.

1. Kill segera:

   ```sh
   docker compose kill -s SIGKILL pg
   ```

2. Restore. Kalau volume `pgbackrest` utuh, pakai repo1:

   ```sh
   docker compose run --rm --no-deps -T -u postgres pg pgbackrest --stanza=main --repo=1 --delta --process-max=4 restore
   docker compose up -d --wait pg
   ```

   `--delta` otomatis nonaktif kalau `PG_VERSION` sudah terhapus. Itu normal.

3. Jalankan checklist di bagian 8.

Terbukti (`scripts/chaos/pgdata-deleted.sh`): deteksi 1.1s, RTO 17.8s dari deteksi sampai bisa ditulis, RPO 31.2s.

## 3. `archive_command` gagal

Deteksi: alert `PgArchiveFailing` (sekitar 30s setelah kegagalan pertama). Log Postgres berisi `archive command failed`. Di dashboard, `pg_stat_archiver_failing = 1`.

Selama insiden ini data belum hilang, karena WAL tertahan di `pg_wal`. Tapi RPO terus membesar. Kalau server mati di saat ini, semua WAL yang tertahan ikut hilang. `pg_wal` juga terus membengkak sampai disk bisa penuh.

1. Baca error spesifiknya:

   ```sh
   docker compose logs pg --since 10m | grep -A3 'archive-push'
   ```

2. Penyebab yang sudah diuji:

   | Error | Penyebab | Perbaikan |
   |---|---|---|
   | `stop file exists` | `pgbackrest stop` lupa di-start | `pgbr start` |
   | `unable to load info file ... archive.info` | stanza belum ada di repo (repo baru/kosong) | `pgbr stanza-create` |
   | timeout ke `minio:9000` | object storage mati/terputus | pulihkan konektivitas |

3. Pastikan antrean habis dan archiving pulih:

   ```sh
   pg psql -Atc "SELECT count(*) FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready'"
   pgbr check
   ```

   Antrean bisa butuh sampai sekitar 60 detik sebelum mulai berkurang. Kemungkinan besar itu jeda retry archiver Postgres setelah beberapa kali gagal berturut-turut.

4. Kalau `pg_wal` hampir penuh dan perbaikan belum mungkin dilakukan, jangan hapus file di `pg_wal`. Tambah disk. Menghapus WAL yang belum terarsip memutus rantai PITR.

Terbukti (`scripts/chaos/archive-broken.sh`), outage 188s:

- deteksi 1.5s
- puncak antrean 19 segment, `.ready` tertua 178s, `pg_wal` 336 MB
- antrean habis 51s setelah `pgbackrest start`
- 0 dari 1.213 commit hilang (diverifikasi dengan restore ke scratch)

## 4. Data salah hapus atau salah ubah (`DROP`, `DELETE`, migrasi rusak)

Jangan PITR di prod. PITR di prod ikut membuang semua commit sah yang terjadi setelah insiden. Restore ke `scratch`, lalu salin balik objek yang rusak saja.

1. Cari target recovery:
   - xid: dari log aplikasi atau `pg_current_xact_id()` yang tercatat. Untuk DDL, lihat `log_statement`.
   - restore point: kalau dibuat sebelum migrasi, lewat `SELECT pg_create_restore_point('nama')`. Biasakan membuat restore point sebelum setiap migrasi.
   - waktu: `--type=time --target="2026-09-26 15:20:00+00"`. Paling tidak presisi.

2. Restore ke scratch:

   ```sh
   docker compose run --rm --no-deps -T -u postgres scratch pgbackrest --stanza=main --repo=2 --process-max=4 \
     --type=xid --target=<xid> --target-exclusive --target-action=promote restore
   docker compose up -d --wait scratch
   ```

   Ganti argumen target ke `--type=name --target=<restore-point>` bila memakai restore point.

   Detail penting:
   - `--target-exclusive` berhenti sebelum xid itu. Tanpa flag ini, transaksi perusaknya ikut diterapkan.
   - `--target-action=promote` wajib. Default-nya `pause`, dan scratch akan menunggu selamanya dalam mode read-only.

3. Periksa hasilnya di scratch, lalu salin balik:

   ```sh
   docker compose exec -T -u postgres scratch pg_dump -Fc -t <tabel> postgres \
     | docker compose exec -T -u postgres pg pg_restore -d postgres
   ```

   Untuk `DELETE` sebagian, jangan menimpa tabel. Salin ke tabel sementara lalu `INSERT ... SELECT ... WHERE NOT EXISTS`.

4. Buang scratch:

   ```sh
   docker compose rm -fsv scratch
   docker volume rm postgres-rpo-rto_scratchdata
   ```

Terbukti (`scripts/chaos/pitr-drop-table.sh`), `DROP TABLE blobs` dengan 20 juta baris:

- restore ke xid: 18.5s
- restore ke restore point: 18.9s
- salin balik: 103.9s

Commit sebelum dan sesudah `DROP` di prod tetap utuh. Di kasus ini RTO nyata ditentukan oleh langkah salin balik, bukan oleh restore.

## 5. PITR sebelumnya salah target / butuh data dari timeline lama

Setiap PITR yang di-promote membuat timeline baru. Restore default (`recovery_target_timeline=latest`) selalu mengikuti timeline terbaru. Data yang ada di timeline lama sesudah titik percabangan tidak akan kembali.

1. Cari timeline lama dan titik percabangannya:

   ```sh
   docker compose exec -T -u postgres pg bash -c 'cd /var/lib/postgresql/data && tail -n1 pg_wal/*.history'
   ```

   Dari lab, baris terakhir `0000000A.history` adalah `9  7/DC4013E8  at restore point "titik-pitr-salah"`. Artinya timeline 10 bercabang dari timeline 9 di LSN itu, jadi timeline lamanya 9.

2. Restore ke scratch dengan timeline eksplisit:

   ```sh
   docker compose run --rm --no-deps -T -u postgres scratch pgbackrest --stanza=main --repo=2 --process-max=4 \
     --target-timeline=<tl-lama> restore
   docker compose up -d --wait scratch
   ```

3. Salin data yang dibutuhkan seperti di bagian 4.

Backup yang dipakai harus berada di timeline yang menjadi leluhur target. Kalau tidak, pgBackRest menolak dengan `backup timeline X ... is not in the history of target timeline Y`. Pilih backup yang lebih lama dengan `--set=<label>`.

Terbukti (`scripts/chaos/old-timeline.sh`):

- PITR prod dengan `--delta`: 34–39s
- restore default: mengikuti TL baru, data TL lama tidak ada
- `--target-timeline=<lama>`: data kembali dalam 32–35s, tanpa tercampur commit TL baru

## 6. Recovery berhenti dengan `FATAL: recovery ended before configured recovery target was reached`

Penyebab: target (waktu, xid, atau nama) berada di luar WAL yang terarsip untuk timeline itu. Contohnya waktu di masa depan, atau xid dari timeline lain. Postgres berhenti dan tidak promote. Server tidak akan hidup sampai konfigurasi recovery diganti.

1. Lihat `last completed transaction was at log time ...` di log. Itu titik terjauh yang bisa dicapai.
2. Restore ulang dengan target ≤ titik itu, atau tanpa target (ujung archive):

   ```sh
   docker compose run --rm --no-deps -T -u postgres pg pgbackrest --stanza=main --repo=<n> --delta \
     --type=time --target="<≤ last completed>" --target-action=promote restore
   ```

Ditemui di lab: target time 10 detik melewati transaksi terakhir. Setelah repo S3 dikosongkan, satu-satunya jalan pulang adalah repo1 dengan `--target-timeline=2`, karena history timeline 3 tidak memuat timeline 1.

## 7. Repo S3 dihapus (ransomware / salah hapus)

- repo2 (tanpa object lock): kalau bucket versioned, pulihkan versi lama. Kalau tidak, repo2 hilang, pakai repo3.
- repo3 (object lock COMPLIANCE): `aws s3 rm` hanya membuat delete marker, versi aslinya tidak bisa dihapus selama masa retensi. Hapus delete marker-nya:

  ```sh
  docker compose run --rm -T aws s3api list-object-versions --bucket pgbackrest-locked \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}, Quiet: `true`}' 2>/dev/null > dm.json
  docker compose run --rm -T -v "$PWD/dm.json:/dm.json:ro" aws s3api delete-objects \
    --bucket pgbackrest-locked --delete file:///dm.json
  rm dm.json
  pgbr --repo=3 info
  ```

  Di macOS, simpan `dm.json` di folder yang di-share ke Docker, jangan di `/tmp`.
- Gejala sebelum dipulihkan: `stanza-create` menolak dengan `backup directory and/or archive directory not empty`. MinIO tetap menampilkan prefix yang isinya hanya delete marker.

Terbukti di lab: 987 delete marker dihapus, `repo3: ok`.

## 8. Checklist setelah restore apa pun

```sh
pg psql -Atc "SELECT pg_is_in_recovery()"
pg psql -Atc CHECKPOINT
pgbr stanza-create
pgbr check
pgbr --repo=2 --type=full --process-max=4 backup
PROCESS_MAX=4 ./scripts/restore-test.sh
```

| Langkah | Alasan |
|---|---|
| `pg_is_in_recovery()` harus `f` | server sudah promote |
| `CHECKPOINT` | tanpa ini `archive_timeout` tidak jalan sampai `checkpoint_timeout` (300s) pertama setelah start/promote, sehingga RPO di menit-menit awal membengkak |
| `stanza-create` | aman diulang; wajib kalau ada repo yang kosong |
| `check` | memaksa switch WAL dan memastikan archiving ke semua repo jalan |
| full/diff backup baru | setelah PITR server ada di timeline baru, dan replay WAL adalah komponen terbesar RTO |
| `restore-test.sh` | membuktikan backup baru bisa dipakai |
