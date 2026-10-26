#!/usr/bin/env bash
# Runs every test against a throw-away local Postgres 16:
#   1. database security + money tests (tests/security_tests.sql)
#   2. manual funding, admin add-listing, plan lengths/renewals/moves/creators/bulk, and 50x stress/attack tests
#   3. end-to-end browser test of both apps (tests/e2e.mjs)
# Usage: PGHOST=/path/to/socket PGPORT=5433 bash tests/run-all.sh
set -u
cd "$(dirname "$0")/.."
P="psql -h $PGHOST -p $PGPORT -U postgres -v ON_ERROR_STOP=1 -q -X"
build() { $P -d postgres -c "drop database if exists $1" -c "create database $1" >/dev/null 2>&1
  for f in tests/supabase_stub.sql database/001_schema.sql database/002_storage.sql database/003_seed_services.sql database/006_orders_money.sql database/007_growth_admin.sql database/009_withdrawal_fee_tiers.sql database/010_fee_list_and_account_close.sql database/011_speed.sql database/012_balance_speed.sql database/014_admin_tools.sql database/015_manual_funding_inquiries.sql database/016_admin_add_listing.sql database/017_plans_renewals_creators.sql database/019_security_hardening.sql; do
    $P -d "$1" -f "$f" >/dev/null 2>&1 || { echo "LOAD FAILED: $f"; exit 1; }; done
  # The SQL suites peek at tables as a signed-in user to check results, so they get the
  # old (pre-019) read rights back. The browser tests (e2e, sf) run WITHOUT them: that proves
  # both apps work with direct table reads switched off.
  [ "${2:-}" = "peek" ] && $P -d "$1" -f tests/test_table_reads.sql >/dev/null 2>&1; true; }

echo "== Database security & money tests"
build sec peek
psql -h $PGHOST -p $PGPORT -U postgres -d sec -q -X -f tests/security_tests.sql 2>&1 | grep -E '^ (PASS|FAIL) ' | sed 's/^ //'
psql -h $PGHOST -p $PGPORT -U postgres -d sec -q -X -t -A -c "select count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed' from t.results"

echo; echo "== Manual funding, admin alerts, inquiries"
build mf peek
psql -h $PGHOST -p $PGPORT -U postgres -d mf -q -X -f tests/manual_funding_tests.sql >/dev/null 2>&1
psql -h $PGHOST -p $PGPORT -U postgres -d mf -q -X -t -A -c "select count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed' from t.results"
psql -h $PGHOST -p $PGPORT -U postgres -d mf -q -X -t -A -c "select 'FAIL ' || name || ' ' || coalesce(detail,'') from t.results where not ok"

echo; echo "== Admin adds a listing with proof (live at once)"
build al peek
psql -h $PGHOST -p $PGPORT -U postgres -d al -q -X -f tests/admin_listing_tests.sql >/dev/null 2>&1
psql -h $PGHOST -p $PGPORT -U postgres -d al -q -X -t -A -c "select count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed' from t.results"
psql -h $PGHOST -p $PGPORT -U postgres -d al -q -X -t -A -c "select 'FAIL ' || name || ' ' || coalesce(detail,'') from t.results where not ok"

echo; echo "== Stress: every money path and admin function attacked 50 times"
build st peek
psql -h $PGHOST -p $PGPORT -U postgres -d st -q -X -f tests/stress_tests.sql >/dev/null 2>&1
psql -h $PGHOST -p $PGPORT -U postgres -d st -q -X -t -A -c "select count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed' from t.results"
psql -h $PGHOST -p $PGPORT -U postgres -d st -q -X -t -A -c "select 'FAIL ' || name || ' ' || coalesce(detail,'') from t.results where not ok"

echo; echo "== Plan lengths, renewals, auto-renew, moves, creators, bulk messages (017)"
build pr peek
psql -h $PGHOST -p $PGPORT -U postgres -d pr -q -X -f tests/plans_renewals_tests.sql >/dev/null 2>&1
psql -h $PGHOST -p $PGPORT -U postgres -d pr -q -X -t -A -c "select count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed' from t.results"
psql -h $PGHOST -p $PGPORT -U postgres -d pr -q -X -t -A -c "select 'FAIL ' || name || ' ' || coalesce(detail,'') from t.results where not ok"

echo; echo "== Stress 017: every new money path with random inputs, books checked after each block"
build s17 peek
psql -h $PGHOST -p $PGPORT -U postgres -d s17 -q -X -f tests/stress_017.sql >/dev/null 2>&1
psql -h $PGHOST -p $PGPORT -U postgres -d s17 -q -X -t -A -c "select count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed' from t.results"
psql -h $PGHOST -p $PGPORT -U postgres -d s17 -q -X -t -A -c "select 'FAIL ' || name || ' ' || coalesce(detail,'') from t.results where not ok"

echo; echo "== 019 hardening: no direct table reads, new-bank warning, search flood cap"
build h19
psql -h $PGHOST -p $PGPORT -U postgres -d h19 -q -X -f tests/hardening_019.sql >/dev/null 2>&1
psql -h $PGHOST -p $PGPORT -U postgres -d h19 -q -X -t -A -c "select count(*) filter (where ok) || ' passed, ' || count(*) filter (where not ok) || ' failed' from t.results"
psql -h $PGHOST -p $PGPORT -U postgres -d h19 -q -X -t -A -c "select 'FAIL ' || name || ' ' || coalesce(detail,'') from t.results where not ok"

echo; echo "== End-to-end (both apps, real SQL, real Edge Function code, fake Flutterwave)"
build e2e
fuser -k 8787/tcp >/dev/null 2>&1; sleep 1
PGDATABASE=e2e node --experimental-strip-types tests/local-supabase.mjs > /tmp/subsplit-server.log 2>&1 &
SERVER=$!; sleep 2
NODE_PATH=$(npm root -g) node tests/e2e.mjs
kill $SERVER 2>/dev/null

echo; echo "== Stress: the real payment functions attacked 50 times (fake Flutterwave)"
build sf
fuser -k 8790/tcp >/dev/null 2>&1; sleep 1
PGDATABASE=sf PORT=8790 node --experimental-strip-types tests/local-supabase.mjs > /tmp/subsplit-sf.log 2>&1 &
SF=$!; sleep 2
PGDATABASE=sf PORT=8790 node tests/stress_functions.mjs | grep -E '^FAIL|passed'
kill $SF 2>/dev/null
