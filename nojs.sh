#!/bin/sh
# nojs.sh — the comment flow completes with no JavaScript.
#
# The admin UI is a Wasm client that talks to /api/* with fetch. With scripting
# off there was nothing anyone could do on this site but read, and "the blog
# works without JS" was untested and untrue until the index grew a form.
#
# curl runs no JavaScript by construction, so this IS a browser with scripting
# off. THE REQUEST IS READ OUT OF THE PAGE: the method, the action and the field
# names come from the form the server rendered. A request written into this
# script would pass against a page whose form is broken or names fields the
# handler never reads, which is the thing being checked.
set -u

H=${PGHOST:-127.0.0.1}; P=${PGPORT:-15499}; U=${PGUSER:-postgres}; D=${PGDATABASE:-blog}
APP=${APP:-/tmp/mere_blog_nojs}
APP_PORT=${APP_PORT:-8080}
MERE=${MERE:-mere}
command -v curl >/dev/null 2>&1 || { echo "nojs: SKIP (no curl)"; exit 0; }
psql -h "$H" -p "$P" -U "$U" -d "$D" -X -q -c "SELECT 1" >/dev/null 2>&1 \
  || {
    # SKIP is for a developer without Postgres. In CI it is a lie: this ran
    # green through a whole run where the database step had been skipped
    # because verify.sh failed before it, so five gates reported success
    # without touching their subject. CI sets the variable; there, absence of
    # a database is a failure of the setup, not a reason to pass.
    if [ -n "${CI:-}" ]; then
      echo "nojs: FAIL — no database at $H:$P/$D, and CI is set: the setup did not run"
      exit 1
    fi
    echo "nojs: SKIP (no database at $H:$P/$D)"; exit 0; }

tmp=$(mktemp -d) || exit 1
srv=""
cleanup() { [ -n "$srv" ] && kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

"$MERE" -c app.mere > "$tmp/app.c" 2>/dev/null || { echo "nojs: FAIL — app.mere did not emit"; exit 1; }
SSL_INC=""; SSL_LIB=""
[ -d /opt/homebrew/opt/openssl@3 ] && SSL_INC="-I/opt/homebrew/opt/openssl@3/include" && SSL_LIB="-L/opt/homebrew/opt/openssl@3/lib"
clang -O1 -w $SSL_INC $SSL_LIB "$tmp/app.c" -lssl -lcrypto -o "$tmp/app" 2>"$tmp/cc" \
  || { echo "nojs: FAIL — the emitted C did not compile"; head -3 "$tmp/cc"; exit 1; }

PGHOST=$H PGPORT=$P PGUSER=$U PGDATABASE=$D "$tmp/app" > "$tmp/srv.log" 2>&1 &
srv=$!
i=0
until curl -s -m 1 "http://127.0.0.1:$APP_PORT/" > "$tmp/page.html" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -gt 60 ] && { echo "nojs: FAIL — app never answered"; cat "$tmp/srv.log"; exit 1; }
  sleep 0.3
done

fail=0; checks=0
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

page=$(tr -d '\n' < "$tmp/page.html")
form=$(echo "$page" | sed -n 's/.*\(<form[^>]*>\).*/\1/p')
checks=$((checks + 1)); [ -n "$form" ] || bad "the page renders no <form>: with scripting off there is nothing to submit"
method=$(echo "$form" | sed -n 's/.*method="\([^"]*\)".*/\1/p' | tr 'a-z' 'A-Z')
action=$(echo "$form" | sed -n 's/.*action="\([^"]*\)".*/\1/p')
checks=$((checks + 1)); [ "$method" = POST ] || bad "the form declares method [$method]"
checks=$((checks + 1)); [ -n "$action" ] || bad "the form has no action"
if [ "$method" != POST ] || [ -z "$action" ]; then
  echo "nojs: FAIL — the page does not describe a submission a scriptless client could make"
  exit 1
fi

fields=$(echo "$page" | grep -oE '<input[^>]*name="[^"]*"' | sed -n 's/.*name="\([^"]*\)".*/\1/p' | sort -u)
nf=$(echo "$fields" | grep -c .)
checks=$((checks + 1)); [ "${nf:-0}" -ge 2 ] || bad "the form exposes ${nf:-0} named fields"

marker="nojs-$$"
body=""
for f in $fields; do body="${body}${body:+&}${f}=${marker}-${f}"; done

code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X "$method" --data "$body" "http://127.0.0.1:$APP_PORT$action")
checks=$((checks + 1))
case "$code" in
  303|302) ;;
  200) bad "the submission answered 200; with no script a reload resubmits it" ;;
  *)   bad "the form's own submission answered $code" ;;
esac

loc=$(curl -s -D - -o /dev/null -m 5 -X "$method" --data "${body}2" "http://127.0.0.1:$APP_PORT$action" \
       | sed -n 's/^[Ll]ocation: *//p' | tr -d '\r')
checks=$((checks + 1)); [ -n "$loc" ] || bad "the redirect carries no Location"

curl -s -m 5 "http://127.0.0.1:$APP_PORT/" > "$tmp/after.html"
checks=$((checks + 1))
grep -q "$marker" "$tmp/after.html" || bad "the comment does not appear on a subsequent GET: the flow returned but did not complete"

code2=$(curl -s -o "$tmp/bad.html" -w '%{http_code}' -m 5 -X "$method" --data "author=&body=" "http://127.0.0.1:$APP_PORT$action")
checks=$((checks + 1)); [ "$code2" = 422 ] || bad "an empty submission answered $code2 rather than being refused"
checks=$((checks + 1))
grep -qi '<form' "$tmp/bad.html" || bad "the refusal is not a page with the form on it"

[ "$checks" -ge 9 ] || { echo "nojs: FAIL — only $checks checks ran"; exit 1; }
[ "$fail" -eq 0 ] || { echo "nojs: FAIL — $fail of $checks"; exit 1; }
echo "nojs: $checks checks — form read from the page ($nf fields), submitted, and the comment was visible with no JavaScript"
exit 0
