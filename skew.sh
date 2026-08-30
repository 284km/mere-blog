#!/bin/sh
# skew.sh -- what this server does about a client from another deploy.
#
# boundary.sh records WHICH pairings of shipped wire shapes work; `v1 -> v2 :
# fail` is in boundary/EXPECTED today. It cannot say what the server DOES about
# a client on the failing side, and until wire.mere the answer was nothing: the
# client sent no version, the server read none, and the failure happened inside
# the browser's JSON decode where the server could not respond to it, log it,
# or count it.
#
# FIVE CASES, and the last two are the ones that matter.
#
#   1. declared, inside the window        -> served
#   2. declared, older than the window    -> 409 with a machine-readable signal
#   3. declared, newer than the window    -> 409 (a client from a deploy this
#                                            server has not caught up to)
#   4. NOT declared                       -> served, exactly as before
#   5. an ordinary failure                -> NOT 409
#
# Case 4 is a hole, and it is asserted rather than left ambiguous: a build
# already sitting in a browser cache cannot be made to declare anything, so the
# first deploy of a version header is the one it cannot protect. Writing that
# down as a checked behaviour is different from leaving it unstated.
#
# Case 5 is what stops the signal from being useless. A client that reloads on
# 409 must not reload on a bad request, or one bug becomes an infinite reload
# loop -- so a malformed body has to come back 400/422 and carry no `action`.
set -u

MERE=${MERE:-mere}
CC=${CC:-clang}
PORT=${SKEW_PORT:-8311}
ROOT="$(cd "$(dirname "$0")" && pwd)"

command -v curl >/dev/null 2>&1 || { echo "skew: SKIP (no curl)"; exit 0; }
command -v "$MERE" >/dev/null 2>&1 || [ -x "$MERE" ] || { echo "skew: SKIP (no mere at $MERE)"; exit 0; }
H=${PGHOST:-127.0.0.1}; P=${PGPORT:-15499}; U=${PGUSER:-postgres}; D=${PGDATABASE:-blog}
psql -h "$H" -p "$P" -U "$U" -d "$D" -X -q -c "SELECT 1" >/dev/null 2>&1 || {
  if [ -n "${CI:-}" ]; then
    echo "skew: FAIL -- no Postgres at $H:$P/$D, and CI sets it."; exit 1
  fi
  echo "skew: SKIP (no Postgres at $H:$P/$D)"; exit 0
}

tmp=$(mktemp -d) || exit 1
trap 'kill ${SRV:-0} 2>/dev/null; rm -rf "$tmp"' EXIT INT TERM

# The window comes from the program, not from here. A gate holding its own copy
# of min/current would pass while the server used different ones.
MIN=$(sed -n 's/^let wire_min = \([0-9]*\).*/\1/p' "$ROOT/wire.mere")
CUR=$(sed -n 's/^let wire_current = \([0-9]*\).*/\1/p' "$ROOT/wire.mere")
HDR=$(sed -n 's/^let wire_header = "\([^"]*\)".*/\1/p' "$ROOT/wire.mere")
[ -n "$MIN" ] && [ -n "$CUR" ] && [ -n "$HDR" ] || {
  echo "skew: FAIL -- could not read the window out of wire.mere"; exit 1; }

"$MERE" -c "$ROOT/app.mere" > "$tmp/app.c" 2>"$tmp/emit.err" || {
  echo "skew: FAIL -- app.mere did not compile"; sed -n '1,15p' "$tmp/emit.err"; exit 1; }
SSL_INC=""; SSL_LIB=""
if [ -d /opt/homebrew/opt/openssl@3/include ]; then
  SSL_INC="-I/opt/homebrew/opt/openssl@3/include"; SSL_LIB="-L/opt/homebrew/opt/openssl@3/lib"
fi
# shellcheck disable=SC2086
"$CC" -O1 -w $SSL_INC $SSL_LIB "$tmp/app.c" -lssl -lcrypto -o "$tmp/blog" 2>"$tmp/link.err" || {
  echo "skew: FAIL -- generated C did not link"; sed -n '1,15p' "$tmp/link.err"; exit 1; }

PORT=$PORT "$tmp/blog" > "$tmp/server.log" 2>&1 &
SRV=$!
i=0
while [ $i -lt 100 ]; do
  curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break
  i=$((i + 1)); sleep 0.1
done
[ $i -lt 100 ] || { echo "skew: FAIL -- server never accepted on :$PORT"; cat "$tmp/server.log"; exit 1; }
BASE="http://127.0.0.1:$PORT"

fail=0
code() { curl -s -m 5 -o "$tmp/body" -w '%{http_code}' "$@"; }

# 1. inside the window
c=$(code -H "$HDR: $CUR" "$BASE/api/posts")
[ "$c" = "200" ] || { echo "skew: FAIL -- a client declaring $CUR (inside $MIN..$CUR) got $c, not 200"; fail=1; }

# 2 and 3. outside it, in both directions
for v in $((MIN - 1)) $((CUR + 1)); do
  c=$(code -H "$HDR: $v" "$BASE/api/posts")
  if [ "$c" != "409" ]; then
    echo "skew: FAIL -- a client declaring $v (outside $MIN..$CUR) got $c, not 409"
    fail=1
  else
    grep -q '"action":"reload"' "$tmp/body" || {
      echo "skew: FAIL -- the 409 for version $v carries no machine-readable action:"
      head -c 200 "$tmp/body"; echo; fail=1; }
    grep -q "\"min\":$MIN" "$tmp/body" && grep -q "\"current\":$CUR" "$tmp/body" || {
      echo "skew: FAIL -- the 409 for version $v does not name the window the server holds"
      head -c 200 "$tmp/body"; echo; fail=1; }
  fi
done

# 4. undeclared -- served, and asserted so the hole is a recorded behaviour
c=$(code "$BASE/api/posts")
[ "$c" = "200" ] || {
  echo "skew: FAIL -- an undeclared client got $c, not 200. Builds that predate"
  echo "  the header cannot declare anything; refusing them turns the first"
  echo "  deploy of this feature into an outage."; fail=1; }

# 5. an ordinary failure must not look like skew.
#
# THE CHECK HAS TO REACH THE CODE IT IS ABOUT. Without logging in first, a POST
# to /api/posts is refused as unauthenticated and never reaches the body parse
# -- so this assertion passed while the branch it names was never executed.
# Found by poisoning that branch and watching the gate stay green.
U0="skew$$"
curl -s -m 5 -X POST -H "$HDR: $CUR" -d "{\"username\":\"$U0\",\"password\":\"secret123\"}" "$BASE/api/signup" >/dev/null 2>&1
COOKIE=$(curl -s -m 5 -i -X POST -H "$HDR: $CUR" -d "{\"username\":\"$U0\",\"password\":\"secret123\"}" "$BASE/api/login" \
         | grep -i '^set-cookie' | sed 's/[Ss]et-[Cc]ookie: //' | cut -d';' -f1 | tr -d '\r')
[ -n "$COOKIE" ] || { echo "skew: FAIL -- could not log in, so case 5 cannot reach the body parse"; exit 1; }
c=$(code -H "$HDR: $CUR" -H "Cookie: $COOKIE" -H "Content-Type: application/json" -X POST --data 'not json' "$BASE/api/posts")
case "$c" in
  4*) ;;
  *) echo "skew: FAIL -- a malformed body from a logged-in client returned $c;"
     echo "  case 5 is not reaching the body parse it is about."; fail=1 ;;
esac
if [ "$c" = "409" ]; then
  echo "skew: FAIL -- a malformed body came back 409, which a client that reloads"
  echo "  on 409 would turn into an infinite reload loop."
  fail=1
fi
if grep -q '"action":"reload"' "$tmp/body" 2>/dev/null; then
  echo "skew: FAIL -- an ordinary failure carries the reload action"; fail=1
fi

# The HTML side must be untouched: a reader with no header and no JavaScript
# is not part of this at all.
c=$(code "$BASE/")
[ "$c" = "200" ] || { echo "skew: FAIL -- the index returned $c for a plain reader"; fail=1; }

[ $fail -eq 0 ] || exit 1
echo "skew: window $MIN..$CUR — inside served, both sides outside refused with a reload signal, undeclared served, ordinary failures not confused with skew"
