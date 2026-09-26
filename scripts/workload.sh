#!/usr/bin/env bash
set -euo pipefail

until pg_isready -q; do sleep 1; done

psql -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS events (
  id bigserial PRIMARY KEY,
  payload text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
SQL

psql -Atq -F, >> "${ACK_LOG:-/runs/acked.csv}" <<SQL
INSERT INTO events(payload) VALUES (md5(random()::text)) RETURNING id, extract(epoch FROM created_at)
\watch ${WORKLOAD_INTERVAL:-0.2}
SQL
