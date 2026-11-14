#!/usr/bin/env bash
# 用法：PGHOST=... PGPORT=... PGUSER=postgres ./run_tests.sh
# 需求：PostgreSQL 15+ 與 PostGIS 3。會建立並刪除資料庫 silo_test。
set -euo pipefail
cd "$(dirname "$0")"
DB=silo_test
dropdb --if-exists "$DB"
for r in anon authenticated service_role; do psql -qtAc "drop role if exists $r" postgres >/dev/null 2>&1 || true; done
createdb "$DB"
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f 00_supabase_mock.sql
for f in ../migrations/*.sql; do
  echo "== 套用 $(basename "$f")"
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f"
done
for t in [1-9]*.sql; do
  echo "== 執行測試 $t"
  psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$t"
done
dropdb "$DB"
