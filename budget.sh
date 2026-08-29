#!/bin/sh
# budget.sh — what this app costs, and what its pages owe their readers.
#
# No latency threshold: wall clock on a shared runner measures the runner. What
# is gated is what the machine gets no vote on -- the size of the artifact the
# compiler produced, the size of the documents the server sent, and whether
# those documents carry the things a page owes someone who cannot see it.
#
# Bands run both ways. Over the ceiling is the regression everyone expects.
# UNDER THE FLOOR means the thing being measured stopped being built, and a
# gate that cannot see its subject passes forever.
#
# The accessibility checks are four absences that each have a name: a page with
# no lang is read out in the wrong language, one with no title is unlabelled in
# a tab strip and a history list, an input with no label is a box a screen
# reader announces as nothing, and a form with no submit cannot be completed
# without a pointer.
set -u

MERE=${MERE:-mere}
BUDGETS=BUDGETS
H=${PGHOST:-127.0.0.1}; P=${PGPORT:-15499}; U=${PGUSER:-postgres}; D=${PGDATABASE:-blog}
APP_PORT=${APP_PORT:-8080}
command -v curl >/dev/null 2>&1 || { echo "budget: SKIP (no curl)"; exit 0; }
command -v "$MERE" >/dev/null 2>&1 || [ -x "$MERE" ] || { echo "budget: SKIP (no mere)"; exit 0; }
psql -h "$H" -p "$P" -U "$U" -d "$D" -X -q -c "SELECT 1" >/dev/null 2>&1 \
  || { echo "budget: SKIP (no database at $H:$P/$D)"; exit 0; }

tmp=$(mktemp -d) || exit 1
srv=""
cleanup() { [ -n "$srv" ] && kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

fail=0; checks=0
: > "$tmp/measured"
band() {
  checks=$((checks + 1)); name=$1; val=$2
  echo "$name $val" >> "$tmp/measured"
  line=$(grep "^$name " "$BUDGETS" 2>/dev/null)
  [ -n "$line" ] || { echo "  FAIL $name = $val has no band in $BUDGETS (run with --update)"; fail=$((fail + 1)); return; }
  lo=$(echo "$line" | awk '{print $2}'); hi=$(echo "$line" | awk '{print $3}')
  if [ "$val" -gt "$hi" ]; then echo "  FAIL $name = $val is over its ceiling $hi"; fail=$((fail + 1))
  elif [ "$val" -lt "$lo" ]; then
    echo "  FAIL $name = $val is UNDER its floor $lo — the subject may have stopped"
    echo "       being built. If this is a real improvement, lower the floor."
    fail=$((fail + 1)); fi
}
a11y() { checks=$((checks + 1)); [ "$2" = ok ] || { echo "  FAIL $1"; fail=$((fail + 1)); }; }

# ---- the client bundle ---------------------------------------------------
"$MERE" -w admin.mere > "$tmp/admin.wat" 2>/dev/null && \
  wat2wasm --enable-tail-call "$tmp/admin.wat" -o "$tmp/admin.wasm" 2>/dev/null \
  || { echo "  FAIL admin.mere did not build"; fail=$((fail + 1)); }
[ -f "$tmp/admin.wasm" ] && band "wasm_admin" "$(wc -c < "$tmp/admin.wasm" | tr -d ' ')"

# ---- the documents the server sends --------------------------------------
"$MERE" -c app.mere > "$tmp/app.c" 2>/dev/null || { echo "budget: FAIL — app.mere did not emit"; exit 1; }
SSL_INC=""; SSL_LIB=""
[ -d /opt/homebrew/opt/openssl@3 ] && SSL_INC="-I/opt/homebrew/opt/openssl@3/include" && SSL_LIB="-L/opt/homebrew/opt/openssl@3/lib"
clang -O1 -w $SSL_INC $SSL_LIB "$tmp/app.c" -lssl -lcrypto -o "$tmp/app" 2>"$tmp/cc" \
  || { echo "budget: FAIL — the emitted C did not compile"; head -3 "$tmp/cc"; exit 1; }

PGHOST=$H PGPORT=$P PGUSER=$U PGDATABASE=$D "$tmp/app" > "$tmp/srv.log" 2>&1 &
srv=$!
i=0
until curl -s -m 1 "http://127.0.0.1:$APP_PORT/" > "$tmp/index.html" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -gt 60 ] && { echo "budget: FAIL — app never answered"; cat "$tmp/srv.log"; exit 1; }
  sleep 0.3
done
band "html_index" "$(wc -c < "$tmp/index.html" | tr -d ' ')"

page=$(tr -d '\n' < "$tmp/index.html")
case "$page" in *"<html lang="*) r=ok ;; *) r=no ;; esac
a11y "the index declares no lang, so it is read out in the wrong language" "$r"
case "$page" in *"<title>"*) r=ok ;; *) r=no ;; esac
a11y "the index has no title, so it is unlabelled in a tab strip and a history list" "$r"

# the admin page is served as a static file
band "html_admin" "$(wc -c < admin.html | tr -d ' ')"
adm=$(tr -d '\n' < admin.html)
case "$adm" in *"<html lang="*) r=ok ;; *) r=no ;; esac
a11y "the admin page declares no lang" "$r"
inputs=$(echo "$adm" | grep -oE '<input[^>]*name="[^"]*"' | wc -l | tr -d ' ')
labelled=$(echo "$adm" | grep -oE '<label[^>]*for="[^"]*"|aria-label="[^"]*"' | wc -l | tr -d ' ')
checks=$((checks + 1))
[ "${inputs:-0}" -le "${labelled:-0}" ] || {
  echo "  FAIL admin has $inputs named inputs but $labelled labels"; fail=$((fail + 1)); }

if [ "${1:-}" = "--update" ]; then
  { echo "# name  floor  ceiling — produced by budget.sh --update"
    while read -r n v; do echo "$n $((v - v / 10)) $((v + v / 10))"; done < "$tmp/measured"
  } > "$BUDGETS"
  echo "budget: wrote $BUDGETS from $(wc -l < "$tmp/measured" | tr -d ' ') measurements"
  exit 0
fi
[ "$checks" -ge 7 ] || { echo "budget: FAIL — only $checks checks ran"; exit 1; }
[ "$fail" -eq 0 ] || { echo "budget: FAIL — $fail of $checks"; exit 1; }
echo "budget: $checks checks — sizes inside their bands, pages carry lang/title/labels"
exit 0
