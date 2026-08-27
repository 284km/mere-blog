#!/bin/sh
# verify.sh -- mere-blog driven over real HTTP against a real Postgres.
#
# WHAT THE ORACLES ARE. Two external programs, neither written here: curl
# speaks the HTTP, and PostgreSQL stores the rows. Nothing is compared against
# a recording of this app's own past output, which could catch a change and
# never a mistake. What is asserted is documented behaviour -- the status codes
# the README's milestone list promises, and the EFFECTS: a post that was
# created can be read back, an updated one comes back changed, a deleted one is
# gone, and a second user is refused.
#
# THE DATABASE IS THROWAWAY. `initdb` into a temp directory and a cluster on
# the port app.mere names, started and stopped by this script. It never touches
# an existing Postgres, and there is no state to carry between runs -- which is
# the failure a shared development database quietly causes.
#
# THE PORTS ARE THE APP'S, NOT THIS SCRIPT'S. app.mere hardcodes 15499 for
# Postgres and 8080 for HTTP, so both are asked about first and named if busy.
# A gate that fails because something else was listening should say so rather
# than look like the app is broken.
#
#   MERE=/path/to/mere sh verify.sh
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
MERE="${MERE:-mere}"
CC="${CC:-clang}"
PGPORT_APP=15499
HTTP_PORT=8080
for t in "$MERE" "$CC" curl initdb pg_ctl createdb; do
  command -v "$t" >/dev/null 2>&1 || { echo "verify: missing $t" >&2; exit 1; }
done

TMP="$(mktemp -d)"
pgdata="$TMP/pg"
app_pid=""
cleanup() {
  [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null
  [ -d "$pgdata" ] && pg_ctl -D "$pgdata" -m immediate stop >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

busy() { curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/" 2>/dev/null; }
if nc -z 127.0.0.1 "$PGPORT_APP" 2>/dev/null; then
  echo "verify: port $PGPORT_APP is in use, and app.mere hardcodes it" >&2; exit 1; fi
if nc -z 127.0.0.1 "$HTTP_PORT" 2>/dev/null; then
  echo "verify: port $HTTP_PORT is in use, and app.mere hardcodes it" >&2; exit 1; fi

# OpenSSL: contrib/http brings a TLS client in, so the emitted C includes
# <openssl/ssl.h> whether or not this app opens a TLS socket. The README's
# build line omits the flags; this finds them rather than assuming a machine
# where they are already on the default search path.
SSL_INC=""; SSL_LIB=""
for p in "$(brew --prefix openssl@3 2>/dev/null)" /usr/include/openssl /usr/local/opt/openssl@3; do
  [ -n "$p" ] && [ -d "$p/include" ] && { SSL_INC="-I$p/include"; SSL_LIB="-L$p/lib"; break; }
done

build() {  # build <src.mere> <out>
  "$MERE" -c "$ROOT/$1" > "$TMP/$2.c" 2>"$TMP/$2.emit" \
    || { echo "verify: mere -c failed on $1"; sed -n '1,3p' "$TMP/$2.emit"; exit 1; }
  # shellcheck disable=SC2086
  "$CC" -O2 -w $SSL_INC $SSL_LIB "$TMP/$2.c" -lssl -lcrypto -o "$TMP/$2" 2>"$TMP/$2.cc" \
    || { echo "verify: the emitted C did not compile ($1)"; sed -n '1,3p' "$TMP/$2.cc"; exit 1; }
}

initdb -D "$pgdata" -U postgres --auth=trust > "$TMP/initdb.log" 2>&1 \
  || { echo "verify: initdb failed"; sed -n '1,3p' "$TMP/initdb.log"; exit 1; }
pg_ctl -D "$pgdata" -o "-p $PGPORT_APP -k $pgdata -c listen_addresses=127.0.0.1" \
       -l "$pgdata/server.log" start > "$TMP/pgstart.log" 2>&1 \
  || { echo "verify: postgres did not start"; sed -n '1,5p' "$pgdata/server.log"; exit 1; }
i=0
until psql -h 127.0.0.1 -p "$PGPORT_APP" -U postgres -l >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 100 ] && { echo "verify: postgres never accepted"; exit 1; }; sleep 0.1
done
createdb -h 127.0.0.1 -p "$PGPORT_APP" -U postgres blog || { echo "verify: createdb failed"; exit 1; }

build migrate.mere migrate
"$TMP/migrate" > "$TMP/migrate.out" 2>&1 || { echo "verify: migrate failed"; sed -n '1,5p' "$TMP/migrate.out"; exit 1; }
grep -q "schema created" "$TMP/migrate.out" || { echo "verify: migrate did not create the schema"; cat "$TMP/migrate.out"; exit 1; }

build app.mere blog
"$TMP/blog" > "$TMP/blog.log" 2>&1 &
app_pid=$!
# The shell announces a job it kills; the kill is this script's own cleanup.
disown "$app_pid" 2>/dev/null || true
i=0
until curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$HTTP_PORT/api/posts" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -gt 100 ] && { echo "verify: the app never started serving"; sed -n '1,5p' "$TMP/blog.log"; exit 1; }; sleep 0.1
done

B="http://127.0.0.1:$HTTP_PORT"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %-18s %s\n' "$1" "$2"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %-18s %s\n' "$1" "$2"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

ck1="$TMP/ck1"; ck2="$TMP/ck2"
u1="alice$$"; u2="bob$$"

# --- M6: auth ---------------------------------------------------------------
r=$(curl -s -c "$ck1" -X POST "$B/api/signup" -d "{\"username\":\"$u1\",\"password\":\"secret123\"}")
case "$r" in *"\"username\":\"$u1\""*) ok signup "created and logged in" ;; *) bad signup "[$r]" ;; esac

r=$(curl -s -b "$ck1" "$B/api/me")
case "$r" in *"\"username\":\"$u1\""*) ok session "the cookie identifies the user" ;; *) bad session "[$r]" ;; esac

r=$(curl -s -X POST "$B/api/signup" -d "{\"username\":\"$u1\",\"password\":\"secret123\"}")
case "$r" in *taken*) ok signup-dup "a second signup with the same name is refused" ;; *) bad signup-dup "[$r]" ;; esac

# --- M2/M3: CRUD ------------------------------------------------------------
r=$(curl -s -b "$ck1" -X POST "$B/api/posts" -d '{"title":"T1","body":"B1","published":true}')
id=$(printf '%s' "$r" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
# Two questions, not one glob: a single pattern with both fields in it would
# also be asserting the order they appear in, which is the encoder's business
# and not this gate's. It failed on exactly that when written the other way.
case "$r" in *"\"title\":\"T1\""*) t=1 ;; *) t=0 ;; esac
case "$r" in *"\"author\":\"$u1\""*) a=1 ;; *) a=0 ;; esac
if [ "$t" = 1 ] && [ "$a" = 1 ]; then
  ok create "the post came back with the session's author"
else
  bad create "title=$t author=$a [$r]"
fi

r=$(curl -s "$B/api/posts/$id")
case "$r" in *"\"title\":\"T1\""*) ok show "created, then readable" ;; *) bad show "[$r]" ;; esac

r=$(curl -s -b "$ck1" -X PUT "$B/api/posts/$id" -d '{"title":"T2","body":"B2","published":false}')
case "$r" in *"\"title\":\"T2\""*) ok update "the fields changed" ;; *) bad update "[$r]" ;; esac
r=$(curl -s "$B/api/posts/$id")
case "$r" in *"\"title\":\"T2\""*) ok update-persisted "and the change is in the database" ;; *) bad update-persisted "[$r]" ;; esac

r=$(curl -s -b "$ck1" -X POST "$B/api/posts/$id/comments" -d '{"author":"bob","body":"hi"}')
case "$r" in *"\"body\":\"hi\""*) ok comment "created" ;; *) bad comment "[$r]" ;; esac
r=$(curl -s "$B/api/posts/$id")
case "$r" in *"\"comments\":[{"*"\"body\":\"hi\""*) ok comment-joined "and comes back with its post" ;; *) bad comment-joined "[$r]" ;; esac

# --- M6: ownership. A second user must be refused, not merely unauthenticated.
curl -s -c "$ck2" -X POST "$B/api/signup" -d "{\"username\":\"$u2\",\"password\":\"secret123\"}" >/dev/null
c=$(code -b "$ck2" -X PUT "$B/api/posts/$id" -d '{"title":"X","body":"X","published":true}')
[ "$c" = 403 ] && ok other-update "403, not 200 and not 401" || bad other-update "got $c"
c=$(code -b "$ck2" -X DELETE "$B/api/posts/$id")
[ "$c" = 403 ] && ok other-delete "403" || bad other-delete "got $c"
r=$(curl -s "$B/api/posts/$id")
case "$r" in *"\"title\":\"T2\""*) ok other-noop "and the post is untouched" ;; *) bad other-noop "[$r]" ;; esac

c=$(code -X DELETE "$B/api/posts/$id")
[ "$c" != 204 ] && ok anon-delete "an anonymous delete does not succeed ($c)" || bad anon-delete "204 with no session"

c=$(code -b "$ck1" -X DELETE "$B/api/posts/$id")
[ "$c" = 204 ] && ok owner-delete "204" || bad owner-delete "got $c"
c=$(code "$B/api/posts/$id")
[ "$c" = 404 ] && ok gone "404 afterwards" || bad gone "got $c"

# --- logout ends the session -----------------------------------------------
curl -s -b "$ck1" -c "$ck1" -X POST "$B/api/logout" >/dev/null
r=$(curl -s -b "$ck1" "$B/api/me")
case "$r" in *"login required"*) ok logout "the session is over" ;; *) bad logout "[$r]" ;; esac

echo "verify: $pass passed, $fail failed  (oracles: $(curl --version | head -1 | cut -d' ' -f1-2), $(psql --version))"
[ "$fail" -eq 0 ]
