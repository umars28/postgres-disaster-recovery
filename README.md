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
