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
# DELIBERATELY NOT THE DEFAULTS. app.mere's built-in values are 15499 and 8080;
# these are not, and they reach the app only through the environment. So if
# env_var stopped working the app would bind 8080 and talk to 15499, this
# script would be asking a different port, and every check below would fail.
# The configuration is tested by being used rather than by being asserted.
PGPORT_APP=15501
HTTP_PORT=18080
for t in "$MERE" "$CC" curl initdb pg_ctl createdb; do
  command -v "$t" >/dev/null 2>&1 || { echo "verify: missing $t" >&2; exit 1; }
done

# The app reads these (config.mere). Until mere v0.1.337 the C backend had no
# env_var at all, so these values had to be edited into the source -- which is
# why this script used to have to match constants compiled into the binary.
export PGHOST=127.0.0.1
export PGPORT="$PGPORT_APP"
export PGUSER=postgres
export PGDATABASE=blog
export PORT="$HTTP_PORT"
# Four workers rather than the default eight: enough that a session created on
# one must be found by another, small enough that four Postgres connections is
# not a surprise on a CI runner.
export HTTP_WORKERS=4

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
  echo "verify: port $PGPORT_APP is in use" >&2; exit 1; fi
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

# RUNNING IT TWICE MUST BE A NO-OP. This file used to DROP every table and
# recreate it, so a second run silently destroyed the database -- which is the
# difference between "a schema" and "migrations", and nothing here had named it.
# Checked before the app starts, so a failure here is unambiguous.
"$TMP/migrate" > "$TMP/migrate2.out" 2>&1 || { echo "verify: the second migrate failed"; sed -n '1,5p' "$TMP/migrate2.out"; exit 1; }
grep -q "schema created (0 applied)" "$TMP/migrate2.out" \
  || { echo "verify: the second migrate re-applied something"; sed -n '1,8p' "$TMP/migrate2.out"; exit 1; }
grep -q "already applied" "$TMP/migrate2.out" \
  || { echo "verify: the second migrate did not recognise the applied version"; exit 1; }
grep -q "posts already present" "$TMP/migrate2.out" \
  || { echo "verify: the second migrate re-seeded (or lost) the data"; sed -n '1,8p' "$TMP/migrate2.out"; exit 1; }
echo "verify: migrate is idempotent (second run applied 0, data intact)"

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

# --- the password hash is salted, and the salt is used ----------------------
# THE CHECK THAT DISTINGUISHES SALTED FROM UNSALTED, which "login works" does
# not: an unsalted hash logs in perfectly. Two users given the SAME password
# must end up with DIFFERENT stored hashes. Read straight out of the table,
# because the API deliberately never returns pw_hash.
us1="dave$$"; us2="erin$$"
curl -s -X POST "$B/api/signup" -d "{\"username\":\"$us1\",\"password\":\"same-password\"}" >/dev/null
curl -s -X POST "$B/api/signup" -d "{\"username\":\"$us2\",\"password\":\"same-password\"}" >/dev/null
h1=$(psql -h 127.0.0.1 -p "$PGPORT_APP" -U postgres -d blog -tAc \
      "SELECT pw_hash FROM users WHERE username = '$us1'" 2>/dev/null)
h2=$(psql -h 127.0.0.1 -p "$PGPORT_APP" -U postgres -d blog -tAc \
      "SELECT pw_hash FROM users WHERE username = '$us2'" 2>/dev/null)
if [ -z "$h1" ] || [ -z "$h2" ]; then
  bad pw-salt "could not read the stored hashes back"
elif [ "$h1" = "$h2" ]; then
  bad pw-salt "two users with the same password share a hash -- it is not salted"
else
  ok pw-salt "the same password stores two different hashes"
fi
case "$h1" in
  pbkdf2\$*) ok pw-kdf "stored as pbkdf2 with its iteration count" ;;
  *) bad pw-kdf "unexpected hash format [$(printf '%s' "$h1" | cut -c1-24)]" ;;
esac
# And that verification actually re-derives: both must still be able to log in.
ck4="$TMP/ck4"
curl -s -c "$ck4" -X POST "$B/api/login" -d "{\"username\":\"$us2\",\"password\":\"same-password\"}" >/dev/null
r=$(curl -s -b "$ck4" "$B/api/me")
case "$r" in *"$us2"*) ok pw-verify "and a salted hash still verifies at login" ;;
              *) bad pw-verify "[$r]" ;; esac
c=$(code -X POST "$B/api/login" -d "{\"username\":\"$us2\",\"password\":\"wrong\"}")
[ "$c" = 401 ] && ok pw-wrong "a wrong password is still refused" || bad pw-wrong "got $c"

# --- sessions outlive the process (mere v0.1.340) ---------------------------
# THE CHECK THAT ONLY THE DATABASE-BACKED STORE PASSES. The old store was a
# process-local Map: correct-looking under a sequential server, lost on restart,
# and impossible to share between two processes. A concurrent server made it
# worse -- concurrent SET/GET on a lock-free array lose writes -- but that is a
# race, and a race is not what a gate can assert. THIS is: log in, restart the
# server, and present the same cookie.
ck3="$TMP/ck3"
u3="carol$$"
# AT LEAST 8 CHARACTERS: validate.mere refuses shorter ones. The first draft of
# this block used "pw", so signup failed, and the two checks below reported "the
# session did not survive" about a session that had never been created -- a
# harness bug wearing the failure message of the thing under test.
curl -s -c "$ck3" -X POST "$B/api/signup" \
  -d "{\"username\":\"$u3\",\"password\":\"restart-me\"}" >/dev/null
r=$(curl -s -b "$ck3" "$B/api/me")
case "$r" in *"$u3"*) ok session-pre "signed up and logged in" ;;
              *) bad session-pre "[$r]" ;; esac

kill "$app_pid" 2>/dev/null; app_pid=""
"$TMP/blog" > "$TMP/blog2.log" 2>&1 &
app_pid=$!
disown "$app_pid" 2>/dev/null || true
i=0
until curl -s -o /dev/null --max-time 1 "$B/api/posts" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -gt 200 ] && { echo "verify: the app did not come back up"; sed -n '1,5p' "$TMP/blog2.log"; exit 1; }; sleep 0.1
done
r=$(curl -s -b "$ck3" "$B/api/me")
case "$r" in *"$u3"*) ok session-restart "the same cookie still works after a restart" ;;
              *) bad session-restart "the session did not survive [$r]" ;; esac

# And that several workers agree about it: eight requests at once, each of which
# may land on a different worker with its own database connection.
conc_ok=1
i=0; mepids=""
while [ $i -lt 8 ]; do
  ( curl -s -b "$ck3" "$B/api/me" > "$TMP/me$i" ) &
  mepids="$mepids $!"
  i=$((i + 1))
done
# WAIT ON THE CLIENTS, NOT ON EVERY CHILD. A bare `wait` also waits for the app,
# which never exits, so the job ran until GitHub cancelled it at sixty minutes --
# every check above it had already passed and none of them were reported.
#
# This is the SECOND time today: scripts/http_concurrency_check.sh in the
# compiler repo had the identical bug and was fixed hours earlier. Fixing the
# instance did not fix the pattern, because nothing looks for it. A bare `wait`
# in a script that starts a long-lived server is the shape.
for p in $mepids; do wait "$p" 2>/dev/null || true; done
i=0
while [ $i -lt 8 ]; do
  grep -q "$u3" "$TMP/me$i" 2>/dev/null || conc_ok=0
  i=$((i + 1))
done
[ "$conc_ok" -eq 1 ] \
  && ok session-workers "eight concurrent requests all see the session" \
  || bad session-workers "some worker did not see the session"

# --- the database goes away and comes back ----------------------------------
# MEASURED FIRST, WITH A REAL RESTART, and what it found was worse than an
# outage: the app answered `GET /api/posts` with `[]` and a 200. The log said
# "terminating connection due to administrator command" and the API said
# success. A dead database looked like an empty one, which a client cannot tell
# from the truth and a cache would happily store.
#
# Two things had to change. contrib/db's pg layer fails on a FATAL rather than
# returning the rows it managed to read (none), and each worker holds its
# connection in a slot it can replace, so a failure drops it and the next
# request redials.
#
# The shape to expect: one failure per worker -- each discovers its own dead
# connection once -- and then service. Not zero failures; a request already in
# flight when the server went cannot be saved.
pg_ctl -D "$pgdata" -o "-p $PGPORT_APP -k $pgdata -c listen_addresses=127.0.0.1" \
  -w -l "$TMP/pg2.log" restart >/dev/null 2>&1 \
  || { echo "verify: could not restart Postgres"; exit 1; }
i=0
until pg_isready -h 127.0.0.1 -p "$PGPORT_APP" -q 2>/dev/null; do
  i=$((i + 1)); [ "$i" -gt 100 ] && { echo "verify: Postgres did not come back"; exit 1; }; sleep 0.1
done

fails=0; recovered=0; i=0
while [ $i -lt 20 ]; do
  c=$(code "$B/api/posts")
  if [ "$c" = "200" ]; then recovered=1; break; fi
  fails=$((fails + 1))
  i=$((i + 1))
done
[ "$recovered" = "1" ] \
  && ok db-recover "the app came back on its own after $fails failed requests" \
  || bad db-recover "still failing 20 requests after Postgres returned"
[ "$fails" -le "$HTTP_WORKERS" ] \
  && ok db-recover-cost "and it cost at most one request per worker ($fails of $HTTP_WORKERS)" \
  || bad db-recover-cost "$fails failures for $HTTP_WORKERS workers -- more than one each"

# The content is back, not just the status: a 200 with an empty list is exactly
# the failure this section exists to catch.
r=$(curl -s "$B/api/posts")
case "$r" in *'"title"'*) ok db-recover-rows "and the rows are really there" ;;
              *) bad db-recover-rows "200 with no rows [$(printf '%s' "$r" | cut -c1-40)]" ;; esac

# --- the app terminates TLS itself (mere v0.1.338) --------------------------
# It used to serve cleartext, because a Mere program could dial a TLS
# connection but not answer one. This restarts the same binary with a
# certificate and asks curl -- WITHOUT -k, so the certificate presented has to
# be the one we generated.
if command -v openssl >/dev/null 2>&1; then
  kill "$app_pid" 2>/dev/null; app_pid=""
  openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 2 -nodes -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
  TLS_PORT=$((HTTP_PORT + 1))
  PORT="$TLS_PORT" TLS_CERT="$TMP/cert.pem" TLS_KEY="$TMP/key.pem" \
    "$TMP/blog" > "$TMP/blogtls.log" 2>&1 &
  app_pid=$!
  disown "$app_pid" 2>/dev/null || true
  S="https://localhost:$TLS_PORT"
  CA="--cacert $TMP/cert.pem --resolve localhost:$TLS_PORT:127.0.0.1"

  c=$(curl -s $CA --retry 40 --retry-delay 1 --retry-connrefused --max-time 8 \
        -o /dev/null -w '%{http_code}' "$S/api/posts")
  [ "$c" = 200 ] && ok tls-api "the API answers over a verified TLS connection" \
                 || bad tls-api "got $c"

  # A file route as well as a JSON one: http_send_file writes straight to the
  # connection instead of returning a body, so it is the path most likely to
  # be left writing cleartext while every JSON response still looks right.
  r=$(curl -s $CA --max-time 8 "$S/admin")
  case "$r" in *"mere-blog admin"*) ok tls-file "http_send_file's bytes survive TLS" ;;
                *) bad tls-file "[$(printf '%s' "$r" | cut -c1-60)]" ;; esac

  # And the negative, so the two above mean something: a client that does not
  # trust our CA must be refused.
  c=$(curl -s --resolve "localhost:$TLS_PORT:127.0.0.1" --max-time 8 \
        -o /dev/null -w '%{http_code}' "$S/api/posts" 2>/dev/null || true)
  [ "$c" = 200 ] && bad tls-verify "an untrusted client still got 200" \
                 || ok tls-verify "a client without our CA is refused ($c)"

  grep -q "serving https on :$TLS_PORT" "$TMP/blogtls.log" \
    && ok tls-config "the port and certificate came from the environment" \
    || bad tls-config "[$(head -3 "$TMP/blogtls.log" | tr '\n' ' ')]"
else
  echo "  SKIP  tls               openssl not found — four TLS checks did not run"
fi

echo "verify: $pass passed, $fail failed  (oracles: $(curl --version | head -1 | cut -d' ' -f1-2), $(psql --version))"
[ "$fail" -eq 0 ]
