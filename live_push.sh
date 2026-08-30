#!/bin/sh
# live_push.sh -- the live loop in THIS application, over real sockets against
# a real Postgres.
#
# live_soundness.sh judges the DERIVATION: for 48 (write, read) pairs it asks
# Postgres whether the read actually changed and compares that to what
# contrib/db/live claimed. That is the right question and it cannot see this
# one -- whether the channel a browser is attached to is the channel a write
# actually publishes on. Two names that agree inside the program and disagree
# on the wire look identical from in there.
#
# So this subscribes over HTTP, writes over HTTP, and reads what arrives.
#
# THREE ASSERTIONS, and the interesting one is the cascade.
#
#   1. Creating a post reaches the `posts` subscriber.
#   2. Deleting a post reaches the `comments` subscriber -- from a statement
#      that never names that table. Postgres deletes the comments by foreign
#      key, and `live_channels_via` knows because cascades_of read the key out
#      of the same DDL migrate.mere runs. Before that function existed this app
#      told the subscriber nothing while its rows were deleted underneath it.
#   3. Neither write reaches the `me` subscriber, whose read is of `users`. An
#      implementation that published to everyone would satisfy 1 and 2 and is
#      the thing this exists to refuse.
#
# No fixtures: the statements under test are the ones sql.mere sends, which is
# what model.mere and session_pg.mere execute.
set -u

MERE=${MERE:-mere}
CC=${CC:-clang}
PORT=${LIVE_PORT:-8231}
ROOT="$(cd "$(dirname "$0")" && pwd)"

command -v curl >/dev/null 2>&1 || { echo "live_push: SKIP (no curl)"; exit 0; }
command -v "$MERE" >/dev/null 2>&1 || [ -x "$MERE" ] || { echo "live_push: SKIP (no mere at $MERE)"; exit 0; }
H=${PGHOST:-127.0.0.1}; P=${PGPORT:-15499}; U=${PGUSER:-postgres}; D=${PGDATABASE:-blog}
psql -h "$H" -p "$P" -U "$U" -d "$D" -X -q -c "SELECT 1" >/dev/null 2>&1 || {
  if [ -n "${CI:-}" ]; then
    echo "live_push: FAIL -- no Postgres at $H:$P/$D, and CI sets it. A gate that"
    echo "  skips because its database step did not run reports success without"
    echo "  touching its subject."
    exit 1
  fi
  echo "live_push: SKIP (no Postgres at $H:$P/$D)"; exit 0
}

tmp=$(mktemp -d) || exit 1
trap 'kill ${SRV:-0} 2>/dev/null; rm -rf "$tmp"' EXIT INT TERM

"$MERE" -c "$ROOT/app.mere" > "$tmp/app.c" 2>"$tmp/emit.err" || {
  echo "live_push: FAIL -- app.mere did not compile"; sed -n '1,15p' "$tmp/emit.err"; exit 1; }
SSL_INC=""; SSL_LIB=""
if [ -d /opt/homebrew/opt/openssl@3/include ]; then
  SSL_INC="-I/opt/homebrew/opt/openssl@3/include"; SSL_LIB="-L/opt/homebrew/opt/openssl@3/lib"
fi
# shellcheck disable=SC2086
"$CC" -O1 -w $SSL_INC $SSL_LIB "$tmp/app.c" -lssl -lcrypto -o "$tmp/blog" 2>"$tmp/link.err" || {
  echo "live_push: FAIL -- generated C did not link"; sed -n '1,15p' "$tmp/link.err"; exit 1; }

PORT=$PORT "$tmp/blog" > "$tmp/server.log" 2>&1 &
SRV=$!

# Wait for the port rather than sleeping a guessed amount.
i=0
while [ $i -lt 100 ]; do
  curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break
  i=$((i + 1)); sleep 0.1
done
[ $i -lt 100 ] || { echo "live_push: FAIL -- server never accepted on :$PORT"; cat "$tmp/server.log"; exit 1; }

BASE="http://127.0.0.1:$PORT"
USER="livepush$$"
curl -s -m 5 -X POST -d "{\"username\":\"$USER\",\"password\":\"secret123\"}" "$BASE/api/signup" >/dev/null 2>&1
COOKIE=$(curl -s -m 5 -i -X POST -d "{\"username\":\"$USER\",\"password\":\"secret123\"}" "$BASE/api/login" \
         | grep -i '^set-cookie' | sed 's/[Ss]et-[Cc]ookie: //' | cut -d';' -f1 | tr -d '\r')
[ -n "$COOKIE" ] || { echo "live_push: FAIL -- could not log in, so no write can be made"; exit 1; }

# grep -c prints 0 and EXITS 1 with no match, so `$(grep -c ... || echo 0)`
# yields the two-line string "0\n0" and every comparison against it is a shell
# error rather than a comparison.
count() { [ -f "$1" ] || { echo 0; return; }; grep -c '^data:' "$1" 2>/dev/null | head -1 | tr -dc '0-9'; echo; }

fail=0

# ---- 1. create reaches `posts`, and not `me` -----------------------------
SUBS=""
curl -s -N -m 8 "$BASE/live/posts" > "$tmp/c_posts.txt" 2>/dev/null & SUBS="$SUBS $!"
curl -s -N -m 8 "$BASE/live/me"    > "$tmp/c_me.txt"    2>/dev/null & SUBS="$SUBS $!"
sleep 2
PID=$(curl -s -m 5 -X POST -H "Cookie: $COOKIE" \
        -d '{"title":"live push","body":"b","published":true}' "$BASE/api/posts" \
      | sed 's/.*"id":\([0-9]*\).*/\1/')
case "$PID" in ''|*[!0-9]*) echo "live_push: FAIL -- the create did not return an id"; exit 1 ;; esac
sleep 3
for pid in $SUBS; do wait "$pid" 2>/dev/null; done

[ "$(count "$tmp/c_posts.txt")" -ge 1 ] || {
  echo "live_push: FAIL -- creating a post did not reach the 'posts' subscriber"; fail=1; }
[ "$(count "$tmp/c_me.txt")" -eq 0 ] || {
  echo "live_push: FAIL -- creating a post reached the 'me' subscriber, whose read is of users"
  echo "  (a broadcaster that publishes to everyone fails exactly here)"; fail=1; }

# ---- 2. delete reaches `comments` by cascade -----------------------------
curl -s -m 5 -X POST -d '{"author":"a","body":"c"}' "$BASE/api/posts/$PID/comments" >/dev/null 2>&1
SUBS=""
curl -s -N -m 8 "$BASE/live/comments" > "$tmp/c_com.txt" 2>/dev/null & SUBS="$SUBS $!"
curl -s -N -m 8 "$BASE/live/me"       > "$tmp/c_me2.txt" 2>/dev/null & SUBS="$SUBS $!"
sleep 2
code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X DELETE -H "Cookie: $COOKIE" "$BASE/api/posts/$PID")
[ "$code" = "204" ] || { echo "live_push: FAIL -- the delete returned $code, not 204"; fail=1; }
sleep 3
for pid in $SUBS; do wait "$pid" 2>/dev/null; done

[ "$(count "$tmp/c_com.txt")" -ge 1 ] || {
  echo "live_push: FAIL -- deleting a post did not reach the 'comments' subscriber."
  echo "  Postgres deleted the comments by foreign key; nothing told the client."
  echo "  This is what live_channels (without _via) does: the statement never"
  echo "  names 'comments', so table-granularity matching cannot see it."; fail=1; }
[ "$(count "$tmp/c_me2.txt")" -eq 0 ] || {
  echo "live_push: FAIL -- deleting a post reached the 'me' subscriber"; fail=1; }

[ $fail -eq 0 ] || exit 1
echo "live_push: create reached 'posts', delete reached 'comments' by cascade, 'me' got neither"
