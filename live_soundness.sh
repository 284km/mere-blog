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
# THE STATEMENTS ARE IN ONE PLACE, and getting there is the point. They used to
# be in three: sql.mere had none, model.mere and session_pg.mere sent them,
# live_claims.mere copied them to make its claim, and this file copied them
# again to execute it. When migration 2 added a NOT NULL slug, only the first
# was fixed; the other two went stale and this gate reported the drift as two
# unsoundnesses in the application.
#
# sql.mere now holds every statement, model.mere and session_pg.mere send those
# strings, live_claims.mere claims about those strings and prints them bound to
# sample values, and this file executes what it printed. A claim can no longer
# be made about a statement the app does not issue.
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

# THE STATEMENTS COME FROM THE PROGRAM, not from here. They used to be copied
# into two shell functions "held in the order live_claims.mere holds them",
# which is a promise no one could check: when migration 2 added a NOT NULL
# slug, the copies went stale and this gate reported the drift as unsoundness
# in the application.
#
# live_claims.mere now prints `sql <name> <statement>` for every read and write
# it makes a claim about, with its sample values already bound, so what runs
# below is the statement the claim was about. sql.mere is the one place either
# is written.
sed -n 's/^sql \([a-z_0-9]*\) //p' "$tmp/claims" > /dev/null 2>&1
stmt() {
  sed -n "s/^sql $1 //p" "$tmp/claims" | head -1
}

# A name with no statement is drift, and drift must stop the gate rather than
# quietly skip a pair -- `checked` would still reach 48 only if every pair ran.
# Rows the pairs need. Seeded inside the same rolled-back transaction as the
# pair itself would be fragile, so they are put here once and the pairs roll
# back over them.
#
# THE SEED IS CHECKED, because when it fails this gate accuses its subject.
# These inserts used to run under `>/dev/null 2>&1`, and they passed only
# because migrate.mere's own seed had already put post 1 there -- `ON CONFLICT
# DO NOTHING` turned the missing NOT NULL slug into a no-op instead of an
# error. Delete the rows and the gate reports "2 unsound", which reads as a
# defect in the application and is a defect in this file. A gate that can
# blame the wrong party for its own broken setup is worse than one that skips.
seed_err="$tmp/seed.err"
psql -h "$H" -p "$P" -U "$U" -d "$D" -X -q -v ON_ERROR_STOP=1 >/dev/null 2>"$seed_err" <<SQL
INSERT INTO users (username, pw_hash) VALUES ('alice','h') ON CONFLICT DO NOTHING;
INSERT INTO sessions (sid, username) VALUES ('s1','alice') ON CONFLICT DO NOTHING;
INSERT INTO posts (id, author, title, body, published, slug) VALUES (1,'alice','seed','b',true,'seed') ON CONFLICT DO NOTHING;
INSERT INTO comments (post_id, author, body) VALUES (1,'alice','seed') ON CONFLICT DO NOTHING;
SQL
if [ -s "$seed_err" ]; then
  echo "live_soundness: FAIL -- the gate's own seed did not apply, so the pairs below"
  echo "  would be judged against rows that are not there. This is this file's bug,"
  echo "  not the application's:"
  sed 's/^/    /' "$seed_err" | head -5
  exit 1
fi

# And the rows are confirmed present, because ON CONFLICT DO NOTHING makes a
# seed that inserted nothing indistinguishable from one that inserted
# everything. The pairs need post 1 and its comment to exist.
have=$(psql -h "$H" -p "$P" -U "$U" -d "$D" -X -q -t -A -c \
  "SELECT (SELECT count(*) FROM posts WHERE id = 1) || '/' || (SELECT count(*) FROM comments WHERE post_id = 1) || '/' || (SELECT count(*) FROM users WHERE username = 'alice') || '/' || (SELECT count(*) FROM sessions WHERE sid = 's1')")
case "$have" in
  1/*/1/1) ;;
  *) echo "live_soundness: FAIL -- rows the pairs need are missing (posts1/comments1/alice/s1 = $have)"
     echo "  Every pair would compare an empty read against an empty read."
     exit 1 ;;
esac

unsound=0; wasteful=0; exact=0; checked=0
: > "$tmp/report"
while read -r w r claim; do
  case "$w" in w_*) ;; *) continue ;; esac
  rq=$(stmt "$r"); wq=$(stmt "$w")
  [ -n "$rq" ] && [ -n "$wq" ] || { echo "live_soundness: FAIL — no statement emitted for $w or $r (live_claims.mere and this gate disagree about the names)"; exit 1; }
  # `2>&1` IS THE WHOLE GUARD. psql writes ERROR: to stderr, and this captured
  # stdout only, so the branch below -- written to stop this gate blaming the
  # application for a statement Postgres refused -- never once fired. Poison
  # the SQL and the gate reported "2 unsound" in the app, which is the exact
  # misattribution the branch exists to prevent, and which the header of this
  # file describes as having already happened.
  out=$(psql -h "$H" -p "$P" -U "$U" -d "$D" -X -q -t -A 2>&1 <<SQL
BEGIN;
$rq;
SELECT '---MARK---';
$wq;
SELECT '---MARK2---';
$rq;
ROLLBACK;
SQL
)
  # TWO MARKS, because the statements are now the app's and the app's writes
  # say RETURNING. With one mark those returned rows land inside the compared
  # region and every pair reads as "changed" -- a gate that reports the write's
  # own output as a stale read.
  before=$(echo "$out" | sed -n '1,/---MARK---/p' | sed '$d')
  after=$(echo "$out" | sed -n '/---MARK2---/,$p' | sed '1d')
  # A statement of this gate's own that Postgres refused aborts the transaction,
  # so the second read returns an error and "the result changed" -- reported as
  # an unsoundness in the application when the defect is in this file. It
  # happened: migration 2 added a NOT NULL slug and the seeded INSERT went stale.
  # A refusal now means the APPLICATION's statement does not match the schema,
  # because these are the strings sql.mere sends. That inverts what this branch
  # used to say. It is also the migration-2 bug exactly: post_create stopped
  # naming the NOT NULL slug and the app could not post, while this gate --
  # holding its own copy without the slug either -- stayed green. Running the
  # app's own SQL is what makes that visible from here.
  case "$out" in
    *ERROR:*) echo "live_soundness: FAIL — Postgres refused a statement the APPLICATION sends, on $w -> $r:"
              echo "$out" | grep -m2 'ERROR:' | sed 's/^/    /'
              echo "    This is sql.mere against the migrated schema. Fix the statement or the migration."
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
