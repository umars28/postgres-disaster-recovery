# postgres-disaster-recovery

Lab PostgreSQL 16 + pgBackRest untuk mengukur RPO dan RTO secara nyata, bukan dari asumsi.

| Repo | Lokasi | Catatan |
|---|---|---|
| repo1 | volume lokal `pgbackrest` | ikut hilang saat server mati total |
| repo2 | MinIO `pgbackrest` (TLS, AES-256) | offsite |
| repo3 | MinIO `pgbackrest-locked` (object lock COMPLIANCE) | tahan ransomware |

## Setup

```sh
./tls.sh
printf 'PGBR_CIPHER_PASS=...\nPGBR_CIPHER_PASS_REPO3=...\n' > .env
docker compose up -d --wait
docker compose exec -u postgres pg pgbackrest --stanza=main stanza-create
for r in 1 2 3; do docker compose exec -u postgres pg pgbackrest --stanza=main --repo=$r --type=full backup; done
```

## Fase 3 — server mati total

`scripts/workload.sh` meng-insert satu baris per `WORKLOAD_INTERVAL` detik (default 0.2) dan mencatat setiap commit yang sudah di-ack ke `runs/acked.csv` di sisi klien. Log klien ini jadi sumber kebenaran: apa yang dijanjikan ke aplikasi, lepas dari apa yang selamat di server.

`scripts/total-loss.sh`:

1. jalankan workload selama `RUN_SECONDS` (default 90)
2. `SIGKILL` pg, lalu hapus volume `pgdata`, `pgbackrest` (repo1), dan `pglog`, sehingga WAL yang belum terarsip hilang bersama server
3. restore dari `REPO` (default 2) ke volume baru, lalu tunggu promote
4. `stanza-create` untuk repo1 yang kosong dan `check` supaya archiving di primary baru jalan lagi
5. cocokkan `runs/acked.csv` dengan tabel `events` hasil restore

```sh
./scripts/total-loss.sh
ARCHIVE_TIMEOUT=15 ./scripts/total-loss.sh
```

Hasil ditambahkan ke `runs/rpo.csv`.

### Hasil

| archive_timeout | commit ter-ack | hilang | RPO aktual | crash − last archive |
|---|---|---|---|---|
| 60s, tanpa `CHECKPOINT` setelah start | 452 | 452 | 90.2s | 91.6s |
| 60s | 466 | 165 | 33.0s | 32.8s |
| 15s | 452 | 9 | 1.8s | 1.4s |

RPO ≈ jarak antara crash dan segment WAL terakhir yang berhasil diarsip. Batas atasnya `archive_timeout`, bukan nol, karena segment yang sedang ditulis baru dikirim ke repo setelah di-switch.

### Temuan: `archive_timeout` tidak jalan setelah start/restore

Baris pertama tabel di atas: selama 90 detik tidak ada satu pun segment yang di-switch, padahal `archive_timeout=60`. Saat diamati lebih lama, switch pertama baru terjadi bersamaan dengan `checkpoint starting: time`, sekitar 300 detik (`checkpoint_timeout`) setelah start. Sesudah itu `archive_timeout` bekerja normal.

Checkpointer menghitung durasi tidurnya ketika recovery masih berlangsung. Pada kondisi itu `archive_timeout` tidak ikut dihitung, sehingga dia tidur penuh `checkpoint_timeout` dan tidak ada yang membangunkannya. Artinya, di menit-menit pertama setelah restart atau restore, RPO sebenarnya bisa sampai `checkpoint_timeout`.

Mitigasi yang sudah terbukti: jalankan `CHECKPOINT` begitu server siap menerima koneksi. Checkpointer terbangun dan menghitung ulang timeout-nya; switch berikutnya terjadi sekitar 60 detik kemudian. `total-loss.sh` melakukan ini di awal dan setelah restore.

## Fase 4 — restore test otomatis, metrik, alert

`scripts/restore-test.sh` me-restore backup terbaru dari `REPO` (default 2) ke container `scratch` yang terpisah dari prod (volume sendiri, `archive_mode=off` supaya tidak pernah mendorong WAL ke stanza yang sama), lalu:

1. recovery sampai ujung archive dan promote, dengan waktu tiap fase dicatat
2. sanity check: `pg_amcheck --heapallindexed` ke semua database, tabel `events` tidak kosong, dan tulis percobaan
3. push metrik ke Pushgateway, tambah baris di `runs/rto.csv`, lalu buang container dan volumenya

Kalau langkah mana pun gagal, tetap ada push `restore_test_success 0`.

```sh
PROCESS_MAX=4 ./scripts/restore-test.sh
```

Contoh jadwal harian: `0 3 * * * cd /path/repo && PROCESS_MAX=4 ./scripts/restore-test.sh >> runs/restore-test.log 2>&1`

| Komponen | URL | Isi |
|---|---|---|
| Grafana | http://127.0.0.1:3000 | dashboard `PostgreSQL DR — RPO / RTO` |
| Prometheus | http://127.0.0.1:9090/alerts | alert di `monitoring/alerts.yml` |
| Pushgateway | http://127.0.0.1:19091 | metrik `restore_test_*` |

`postgres-exporter` membaca `pg_stat_archiver` dan `pg_ls_archive_statusdir()` lewat `monitoring/queries.yaml`. Alert di-unit test:

```sh
docker run --rm -v "$PWD/monitoring:/m:ro" -w /m --entrypoint promtool prom/prometheus:v3.5.0 test rules alerts.test.yml
```

| Alert | Kondisi |
|---|---|
| `PgArchiveFailing` | kegagalan `archive_command` terakhir lebih baru dari keberhasilan terakhir, selama 30s |
| `PgRpoBudgetExceeded` | perkiraan RPO > 120s selama 1m |
| `PgExporterDown` | metrik archiving tidak terbaca |
| `RestoreTestFailed` / `RestoreTestStale` | restore test gagal / tidak ada yang sukses dalam 24 jam |
| `RtoBudgetExceeded` | RTO restore test > 300s |

Uji `PgArchiveFailing`: `docker compose pause minio`. Sekitar 60 detik kemudian (io timeout pgBackRest) `failing` jadi 1 dan `.ready` mulai menumpuk. Setelah `unpause`, antrean habis dalam satu siklus.

### Hasil dengan data besar

`scripts/seed-large.sh` mengisi `pgbench -s 200` + 20 juta baris acak di `blobs` (total 6,1 GB, 1,5 GB setelah dikompresi di repo). Data acak dipakai karena filler pgbench hampir 100% bisa dikompresi, sehingga membuat restore terlihat terlalu cepat.

| Skenario | WAL sejak backup | restore | recovery | RTO |
|---|---|---|---|---|
| full, `process-max=1` | ~0 | 35.7s | 2.0s | 37.7s |
| full, `process-max=4` | ~0 | 10.6s | 2.0s | 12.6s |
| full + 5 menit pgbench | 11 GB | 11.9s | 123.9s | 135.8s |
| diff backup setelah load | ~0 | 11.0s | 2.1s | 13.1s |
| diff + 5 menit pgbench, `archive-async` | 7.9 GB | 14.8s | 83.4s | 98.2s |

Base backup 6 GB bukan penentu RTO. Yang menentukan adalah volume WAL yang harus di-replay. Replay berjalan sekitar 90 MB/s, dan angka itu tidak berubah dengan prefetch `archive-get` paralel, karena redo di proses startup Postgres single-threaded. Satu-satunya cara memperkecilnya adalah memperpendek jendela WAL: backup diff/incr lebih sering. Aturan praktisnya: `RTO ≈ ukuran_backup / throughput_restore + WAL_sejak_backup / 90 MB/s`.

### Temuan: `archive_timeout` bukan batas RPO saat load tinggi

Dengan `archive-push` sinkron, archiver hanya sanggup sekitar 1 segment/detik (±16 MB/s, satu per satu ke 3 repo). Saat bulk load dan pgbench ±4.100 tps, antrean `.ready` mencapai 120–157 segment, yang berarti RPO sebenarnya beberapa menit.

Selama itu `last_archived_time` tetap segar karena archiver terus bekerja. Jadi "umur archive terakhir" tidak bisa dipakai sebagai metrik RPO. Metrik `pg_stat_archiver_rpo_estimate_seconds` mengambil nilai terbesar antara umur archive terakhir dan umur file `.ready` tertua.

Dengan `archive-async=y` + `process-max=4` untuk `archive-push`, pada load yang sama antrean maksimal 3 segment dengan umur tertua ≤1s. Harganya tps turun sekitar 16% (3.482 vs 4.158), karena kompresi paralel bersaing CPU di host yang sama.
