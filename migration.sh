#!/bin/sh
# migration.sh — the migrations run against a database that already has rows.
#
# MIGRATIONS ARE TESTED ON EMPTY DATABASES. verify.sh in this repo creates a
# fresh cluster and runs migrate against it, and that is the one input that
# cannot fail: an empty table accepts ALTER TABLE ... ADD COLUMN x NOT NULL,
# and a populated one refuses it.
#
# So this seeds first, with the shapes a migration written against an empty
# table never meets -- a NULL in a nullable column, an empty title, a duplicate.
# Then it runs migrate and asserts that every pre-existing row is still there
# and has a value for the new column. A migration that drops the rows it cannot
# convert passes its own run, leaves the schema exactly right, and is caught
# here only by counting.
#
# Postgres comes from PGHOST/PGPORT, the same environment config.mere reads.
set -u

H=${PGHOST:-127.0.0.1}; P=${PGPORT:-15499}; U=${PGUSER:-postgres}
MERE=${MERE:-mere}
command -v psql >/dev/null 2>&1 || { echo "migration: SKIP (no psql)"; exit 0; }
psql -h "$H" -p "$P" -U "$U" -d postgres -X -q -c "SELECT 1" >/dev/null 2>&1 \
  || { echo "migration: SKIP (no server at $H:$P)"; exit 0; }

tmp=$(mktemp -d) || exit 1
DB=migtest_$$
cleanup() {
  psql -h "$H" -p "$P" -U "$U" -d postgres -X -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1
  rm -rf "$tmp"
}
trap cleanup EXIT

psql -h "$H" -p "$P" -U "$U" -d postgres -X -q -c "CREATE DATABASE $DB" >/dev/null 2>&1 \
  || { echo "migration: FAIL — could not create $DB"; exit 1; }

"$MERE" -c migrate.mere > "$tmp/m.c" 2>/dev/null || { echo "migration: FAIL — migrate.mere did not emit"; exit 1; }
SSL_INC=""; SSL_LIB=""
[ -d /opt/homebrew/opt/openssl@3 ] && SSL_INC="-I/opt/homebrew/opt/openssl@3/include" && SSL_LIB="-L/opt/homebrew/opt/openssl@3/lib"
clang -O1 -w $SSL_INC $SSL_LIB "$tmp/m.c" -lssl -lcrypto -o "$tmp/migrate" 2>"$tmp/cc" \
  || { echo "migration: FAIL — emitted C did not compile"; head -3 "$tmp/cc"; exit 1; }

run_migrate() { PGHOST=$H PGPORT=$P PGUSER=$U PGDATABASE=$DB "$tmp/migrate" 2>&1; }
q() { psql -h "$H" -p "$P" -U "$U" -d "$DB" -X -q -t -A -c "$1" 2>&1; }

fail=0; checks=0
say() { checks=$((checks + 1)); [ "$2" = "$3" ] || { echo "  FAIL $1: expected [$2] got [$3]"; fail=$((fail + 1)); }; }

# ---- migration 1 only, then seed the shapes ------------------------------
psql -h "$H" -p "$P" -U "$U" -d "$DB" -X -q -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
CREATE TABLE schema_migrations (version integer PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());
SQL
out=$(run_migrate)
echo "$out" | grep -q "schema created" || { echo "migration: FAIL — first run did not create the schema"; echo "$out" | head -5; exit 1; }

# migrate has already applied 2, so the column exists and is NOT NULL. Roll it
# back off BEFORE seeding: the rows have to exist in the pre-migration shape,
# which is the whole point of seeding at all.
psql -h "$H" -p "$P" -U "$U" -d "$DB" -X -q \
  -c "ALTER TABLE posts DROP COLUMN IF EXISTS slug" \
  -c "DELETE FROM schema_migrations WHERE version = 2" >/dev/null 2>&1

psql -h "$H" -p "$P" -U "$U" -d "$DB" -X -q -v ON_ERROR_STOP=1 > "$tmp/seed.log" 2>&1 <<'SQL'
DELETE FROM comments; DELETE FROM posts; DELETE FROM sessions; DELETE FROM users;
INSERT INTO users (username, pw_hash) VALUES ('alice','h');
INSERT INTO posts (id, author, title, body, published) VALUES (101,'alice','first','hello',true);
INSERT INTO posts (id, author, title, body, published) VALUES (102,'alice','second','',false);
INSERT INTO posts (id, author, title, body, published) VALUES (103,'bob','','',true);
INSERT INTO posts (id, author, title, body, published) VALUES (104,'bob','first','dup',false);
SQL
grep -qi error "$tmp/seed.log" && { echo "migration: FAIL — seed"; cat "$tmp/seed.log"; exit 1; }

before=$(q "SELECT count(*) FROM posts")
say "seeded rows" "4" "$before"

# ---- the migration, against rows -----------------------------------------
out=$(run_migrate)
checks=$((checks + 1))
echo "$out" | grep -q "2 applied" || { echo "  FAIL migration 2 did not apply to a POPULATED table"; echo "$out" | sed 's/^/       /' | head -6; fail=$((fail + 1)); }

after=$(q "SELECT count(*) FROM posts")
say "no row lost" "$before" "$after"
say "every pre-existing row got a slug" "0" "$(q "SELECT count(*) FROM posts WHERE slug IS NULL")"
say "and not an empty one" "0" "$(q "SELECT count(*) FROM posts WHERE slug = ''")"
say "the constraint is on" "NO" "$(q "SELECT is_nullable FROM information_schema.columns WHERE table_name='posts' AND column_name='slug'")"
say "the untitled row was converted, not dropped" "post-103" "$(q "SELECT slug FROM posts WHERE id = 103")"

# ---- running it again is a no-op -----------------------------------------
out2=$(run_migrate)
checks=$((checks + 1))
echo "$out2" | grep -q "2 already applied" || { echo "  FAIL a second run did not treat migration 2 as applied"; fail=$((fail + 1)); }
say "and changed nothing" "$before" "$(q "SELECT count(*) FROM posts")"

[ "$checks" -ge 9 ] || { echo "migration: FAIL — only $checks checks ran"; exit 1; }
[ "$fail" -eq 0 ] || { echo "migration: FAIL — $fail of $checks"; exit 1; }
echo "migration: $checks checks against a POPULATED database ($before rows) — every row survived and was converted"
exit 0
