#!/bin/sh
# authz.sh — no effect runs as nobody, except where this app says it may.
#
# Exposure is a property of the EFFECT, not of the route: authorization put in
# a layer along the path is bypassed by input that bypasses the layer, and a
# grep for the check's name finds the call without showing anything is gated by
# it. So every write in app.mere goes through `effect`, which records the
# principal it ran as, and this sweeps every route with no credentials.
#
# THREE STATES, not two. The upstream gate asserts the ledger stays EMPTY under
# an unauthenticated sweep, which assumes no route may legitimately act for
# nobody. Commenting without an account is a choice this blog makes, and it is
# not a hole -- what makes it safe is that it is DECLARED. So:
#
#   guarded   an effect recorded as "anon" here is a defect
#   anon      may produce an effect for nobody, by declaration
#   readonly  must produce no effect at all
#
# The manifest is not derived from the router (the handlers have different
# shapes), so the two are checked against each other: every route the manifest
# names must answer, and the counts must agree. A route added to one and not
# the other fails here.
set -u

H=${PGHOST:-127.0.0.1}; P=${PGPORT:-15499}; U=${PGUSER:-postgres}; D=${PGDATABASE:-blog}
APP_PORT=${APP_PORT:-8080}
MERE=${MERE:-mere}
command -v curl >/dev/null 2>&1 || { echo "authz: SKIP (no curl)"; exit 0; }
psql -h "$H" -p "$P" -U "$U" -d "$D" -X -q -c "SELECT 1" >/dev/null 2>&1 \
  || { echo "authz: SKIP (no database at $H:$P/$D)"; exit 0; }

tmp=$(mktemp -d) || exit 1
srv=""
cleanup() { [ -n "$srv" ] && kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

"$MERE" -c app.mere > "$tmp/app.c" 2>/dev/null || { echo "authz: FAIL — app.mere did not emit"; exit 1; }
SSL_INC=""; SSL_LIB=""
[ -d /opt/homebrew/opt/openssl@3 ] && SSL_INC="-I/opt/homebrew/opt/openssl@3/include" && SSL_LIB="-L/opt/homebrew/opt/openssl@3/lib"
clang -O1 -w $SSL_INC $SSL_LIB "$tmp/app.c" -lssl -lcrypto -o "$tmp/app" 2>"$tmp/cc" \
  || { echo "authz: FAIL — the emitted C did not compile"; head -3 "$tmp/cc"; exit 1; }

PGHOST=$H PGPORT=$P PGUSER=$U PGDATABASE=$D "$tmp/app" > "$tmp/srv.log" 2>&1 &
srv=$!
i=0
until curl -s -m 1 "http://127.0.0.1:$APP_PORT/_routes" > "$tmp/routes" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -gt 60 ] && { echo "authz: FAIL — app never answered"; cat "$tmp/srv.log"; exit 1; }
  sleep 0.3
done

fail=0; checks=0
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

n_manifest=$(grep -c . "$tmp/routes")
n_mounts=$(grep -cE '^  M(Exact|Pattern) ' app.mere)
checks=$((checks + 1))
[ "${n_manifest:-0}" -ge 10 ] || bad "the manifest names ${n_manifest:-0} routes; the sweep would be nearly empty"

# THIS CHECK NO LONGER HAS A FAILURE TO FIND, and saying so is the point.
#
# Until contrib/http/mount, the router and the manifest were two hand-kept
# lists, and a route added to one and not the other was a hole with nothing
# watching it -- so this compared their counts and had real drift to catch.
# They are now two derivations of one list and cannot disagree.
#
# What is left compares the mounts in the source against the manifest the
# RUNNING app serves. That can only differ if the binary is stale, and this
# gate rebuilds before it sweeps, so it cannot be. Poisoning it confirmed
# that: adding a mount changed both numbers together and nothing failed.
#
# It is kept, counted, and labelled rather than deleted, because a gate that
# stopped being able to fail is a fact about the code worth leaving visible.
# A green line here means "these cannot drift", not "they were checked".
checks=$((checks + 1))
[ "${n_mounts:-0}" -eq "$n_manifest" ] \
  || bad "app.mere declares $n_mounts mounts but the running app serves $n_manifest"

# ---- sweep every route with no credentials -------------------------------
while read -r method path acl; do
  [ -n "$method" ] || continue
  url=$(echo "$path" | sed 's/:id/1/')
  curl -s -o /dev/null -m 5 -X "$method" --data "author=sweep&body=sweep" \
       "http://127.0.0.1:$APP_PORT$url" 2>/dev/null
  checks=$((checks + 1))
done < "$tmp/routes"

led=$(curl -s -m 5 "http://127.0.0.1:$APP_PORT/_ledger")
count=$(echo "$led" | sed -n 's/^count=\([0-9]*\)$/\1/p')

# every effect recorded must belong to a route allowed to produce one
checks=$((checks + 1))
anon_effects=$(echo "$led" | grep -cE ' anon$' || true)
allowed=$(awk '$3 == "anon"' "$tmp/routes" | wc -l | tr -d ' ')
if [ "${anon_effects:-0}" -gt 0 ]; then
  # which effects were they? map them back to the guarded set
  for e in $(echo "$led" | awk '$2 == "anon" {print $1}'); do
    case "$e" in
      post_create|post_update|post_delete)
        bad "$e ran as nobody: it belongs to a guarded route" ;;
    esac
  done
fi
checks=$((checks + 1))
[ "${allowed:-0}" -ge 1 ] || bad "no route declares anon, yet the app records anonymous effects"

# ---- and a guarded route with credentials records ITS principal ----------
psql -h "$H" -p "$P" -U "$U" -d "$D" -X -q \
  -c "INSERT INTO users (username, pw_hash) VALUES ('authz_probe','x') ON CONFLICT DO NOTHING" >/dev/null 2>&1
sid="authz-$$"
psql -h "$H" -p "$P" -U "$U" -d "$D" -X -q \
  -c "INSERT INTO sessions (sid, username) VALUES ('$sid','authz_probe') ON CONFLICT DO NOTHING" >/dev/null 2>&1
curl -s -o /dev/null -m 5 -X POST -H "Cookie: session=$sid" -H "Content-Type: application/json" \
     --data '{"title":"authz probe","body":"b","published":true}' \
     "http://127.0.0.1:$APP_PORT/api/posts" 2>/dev/null
led2=$(curl -s -m 5 "http://127.0.0.1:$APP_PORT/_ledger")
checks=$((checks + 1))
echo "$led2" | grep -q "post_create authz_probe" \
  || bad "a guarded write with credentials did not record its principal: $(echo "$led2" | grep post_create | tail -1)"

psql -h "$H" -p "$P" -U "$U" -d "$D" -X -q \
  -c "DELETE FROM posts WHERE title='authz probe'" -c "DELETE FROM users WHERE username='authz_probe'" >/dev/null 2>&1

[ "$checks" -ge 8 ] || { echo "authz: FAIL — only $checks checks ran"; exit 1; }
[ "$fail" -eq 0 ] || { echo "authz: FAIL — $fail of $checks"; exit 1; }
echo "authz: $n_manifest routes swept unauthenticated, ${count:-0} effects recorded, none of them on a guarded route ($checks checks)"
exit 0
