#!/bin/sh
# live_soundness.sh — does a write to THIS app's tables ever leave one of ITS
# reads stale?
#
# The upstream gate (scripts/live_soundness_check.sh in the compiler repo)
# checks the derivation against a schema written to exercise it. This points
# the same idea at the application: the reads come from model.mere and
# session_pg.mere, the schema from migrate.mere, and the judge is Postgres.
#
# For each (write, read) pair, in one transaction that is rolled back:
# read, write, read. `before != after` is ground truth that the read went
# stale; live_claims.mere is the claim. Only one crossing is a bug -- changed
# and NOT claimed, a reader holding an answer that is no longer true with
# nothing that will ever tell it. Woken-but-unchanged is counted, not failed:
# table granularity costs that.
#
# PGHOST / PGPORT / PGUSER / PGDATABASE select the server, the same way
# config.mere reads them, so this and the app talk to the same database.
#
# THE STATEMENTS ARE IN TWO PLACES and that has already cost once:
# live_claims.mere holds them to make its claim, and writeq/readq below hold
# them to execute. When migration 2 added a NOT NULL slug, fixing only the
# first left the second inserting a row Postgres refused -- which aborted the
# transaction, made the second read return an error, and was reported as two
# unsoundnesses in the application. The gate now stops and says the SQL is its
# own when Postgres refuses it, but the duplication is still here and still
# wrong; one side should be generated from the other.
set -u

MERE=${MERE:-mere}
command -v psql >/dev/null 2>&1 || { echo "live_soundness: SKIP (no psql)"; exit 0; }
command -v "$MERE" >/dev/null 2>&1 || [ -x "$MERE" ] || { echo "live_soundness: SKIP (no mere at $MERE)"; exit 0; }

H=${PGHOST:-127.0.0.1}; P=${PGPORT:-15499}; U=${PGUSER:-postgres}; D=${PGDATABASE:-blog}
psql -h "$H" -p "$P" -U "$U" -d "$D" -X -q -c "SELECT 1" >/dev/null 2>&1 \
  || {
    # SKIP is for a developer without Postgres. In CI it is a lie: this ran
    # green through a whole run where the database step had been skipped
    # because verify.sh failed before it, so five gates reported success
    # without touching their subject. CI sets the variable; there, absence of
    # a database is a failure of the setup, not a reason to pass.
    if [ -n "${CI:-}" ]; then
      echo "live_soundness: FAIL — no database at $H:$P/$D, and CI is set: the setup did not run"
      exit 1
    fi
    echo "live_soundness: SKIP (no database at $H:$P/$D)"; exit 0; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

"$MERE" live_claims.mere > "$tmp/claims" 2>"$tmp/err" \
  || { echo "live_soundness: FAIL — claims program"; head -3 "$tmp/err"; exit 1; }
pairs=$(grep -cE '^w_[a-z_]+ r_[a-z_]+ (yes|no)$' "$tmp/claims")
[ "$pairs" -eq 48 ] || { echo "live_soundness: FAIL — $pairs claims, expected 48"; exit 1; }

# The statements, held here in the order live_claims.mere holds them.
readq() {
  case $1 in
    r_posts_all)   echo "SELECT id, author, title, body, published, created_at FROM posts ORDER BY id DESC" ;;
    r_posts_pub)   echo "SELECT id, author, title, body, published, created_at FROM posts WHERE published = true ORDER BY id DESC" ;;
    r_post_find)   echo "SELECT id, author, title, body, published, created_at FROM posts WHERE id = 1" ;;
    r_comments)    echo "SELECT id, post_id, author, body, created_at FROM comments WHERE post_id = 1 ORDER BY id" ;;
    r_user_byname) echo "SELECT id, username, pw_hash FROM users WHERE username = 'alice'" ;;
    r_session)     echo "SELECT username FROM sessions WHERE sid = 's1'" ;;
  esac
}
writeq() {
  case $1 in
    w_post_create)    echo "INSERT INTO posts (author, title, body, published, slug) VALUES ('a','t','b',true,'s')" ;;
    w_post_update)    echo "UPDATE posts SET title = 'x', body = 'y', published = true WHERE id = 1" ;;
    w_post_delete)    echo "DELETE FROM posts WHERE id = 1" ;;
    w_comment_create) echo "INSERT INTO comments (post_id, author, body) VALUES (1,'a','c')" ;;
    w_user_create)    echo "INSERT INTO users (username, pw_hash) VALUES ('carol','h')" ;;
    w_user_delete)    echo "DELETE FROM users WHERE username = 'alice'" ;;
    w_session_login)  echo "INSERT INTO sessions (sid, username) VALUES ('s9','alice')" ;;
    w_session_logout) echo "DELETE FROM sessions WHERE sid = 's1'" ;;
  esac
}

# Rows the pairs need. Seeded inside the same rolled-back transaction as the
# pair itself would be fragile, so they are put here once and the pairs roll
# back over them.
psql -h "$H" -p "$P" -U "$U" -d "$D" -X -q >/dev/null 2>&1 <<SQL
INSERT INTO users (username, pw_hash) VALUES ('alice','h') ON CONFLICT DO NOTHING;
INSERT INTO sessions (sid, username) VALUES ('s1','alice') ON CONFLICT DO NOTHING;
INSERT INTO posts (id, author, title, body, published) VALUES (1,'alice','seed','b',true) ON CONFLICT DO NOTHING;
INSERT INTO comments (post_id, author, body) VALUES (1,'alice','seed') ON CONFLICT DO NOTHING;
SQL

unsound=0; wasteful=0; exact=0; checked=0
: > "$tmp/report"
while read -r w r claim; do
  case "$w" in w_*) ;; *) continue ;; esac
  rq=$(readq "$r"); wq=$(writeq "$w")
  [ -n "$rq" ] && [ -n "$wq" ] || { echo "live_soundness: FAIL — unknown pair $w/$r (the lists have drifted)"; exit 1; }
  out=$(psql -h "$H" -p "$P" -U "$U" -d "$D" -X -q -t -A <<SQL
BEGIN;
$rq;
SELECT '---MARK---';
$wq;
$rq;
ROLLBACK;
SQL
)
  before=$(echo "$out" | sed -n '1,/---MARK---/p' | sed '$d')
  after=$(echo "$out" | sed -n '/---MARK---/,$p' | sed '1d')
  # A statement of this gate's own that Postgres refused aborts the transaction,
  # so the second read returns an error and "the result changed" -- reported as
  # an unsoundness in the application when the defect is in this file. It
  # happened: migration 2 added a NOT NULL slug and the seeded INSERT went stale.
  case "$out" in
    *ERROR:*) echo "live_soundness: FAIL — this gate's own SQL was refused on $w -> $r:"
              echo "$out" | grep -m2 'ERROR:' | sed 's/^/    /'
              echo "    The statements here have drifted from the schema. Fix them, not the app."
              exit 1 ;;
  esac
  checked=$((checked + 1))
  [ "$before" = "$after" ] && changed=no || changed=yes
  if [ "$changed" = yes ] && [ "$claim" = no ]; then
    unsound=$((unsound + 1))
    echo "  UNSOUND  $w -> $r : the result changed and nothing would have said so" >> "$tmp/report"
  elif [ "$changed" = no ] && [ "$claim" = yes ]; then
    wasteful=$((wasteful + 1))
    echo "  wasteful $w -> $r" >> "$tmp/report"
  else
    exact=$((exact + 1))
  fi
done < "$tmp/claims"

[ "$checked" -eq 48 ] || { echo "live_soundness: FAIL — executed $checked of 48"; exit 1; }
[ -s "$tmp/report" ] && cat "$tmp/report"
echo "live_soundness: $checked pairs of THIS app against its own database — $exact exact, $wasteful wasteful, $unsound unsound"
[ "$unsound" -eq 0 ] || exit 1
exit 0
