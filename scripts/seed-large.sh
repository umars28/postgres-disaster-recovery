#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SCALE=${SCALE:-200}
RANDOM_ROWS=${RANDOM_ROWS:-20000000}

dc() { docker compose "$@"; }
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

dc up -d --wait pg

log "pgbench -i -s ${SCALE}"
dc exec -T -u postgres pg pgbench -i -q -s "$SCALE" --foreign-keys postgres

log "blobs: ${RANDOM_ROWS} baris data acak"
dc exec -T -u postgres pg psql -q -v ON_ERROR_STOP=1 <<SQL
DROP TABLE IF EXISTS blobs;
CREATE TABLE blobs AS
SELECT g AS id,
       md5(random()::text) || md5(random()::text) || md5(random()::text) AS body,
       clock_timestamp() AS created_at
FROM generate_series(1, ${RANDOM_ROWS}) g;
ALTER TABLE blobs ADD PRIMARY KEY (id);
VACUUM ANALYZE;
SQL

dc exec -T -u postgres pg psql -Atc "SELECT pg_size_pretty(pg_database_size('postgres'))"
