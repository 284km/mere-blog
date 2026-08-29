#!/bin/sh
# boundary.sh — every shipped shape of this API, crossed against every other.
#
# admin.wasm is downloaded and cached by a browser, so a client running last
# week's build calls this week's server on every deploy. The API's JSON comes
# from `to_json` over model.mere's records, which means CHANGING A RECORD
# CHANGES THE WIRE and nothing in the type says so.
#
# boundary/v<N>.mere keeps each shape executable rather than described --
# `encode` prints that version's payload, `decode <json>` answers ok or fail --
# and every (encoder, decoder) pair is crossed. The matrix is compared byte for
# byte against boundary/EXPECTED.
#
# NOT "every cell must be ok", because measurement says they cannot all be. The
# derived decoder requires every key to be PRESENT, `option` fields included --
# `option` says the value may be null, not that the key may be absent, and None
# is written as "k":null. So adding a field breaks old client -> new server.
# v2 here is the change migration 2 already set up: exposing posts.slug. The
# matrix records that it would break every cached admin.wasm, which is the
# point of writing it down before shipping it rather than after.
#
# A cell moving in EITHER direction fails: a break appearing is a regression,
# and a break disappearing means the note about it is now a lie.
set -u

MERE=${MERE:-mere}
EXPECTED=boundary/EXPECTED
command -v "$MERE" >/dev/null 2>&1 || [ -x "$MERE" ] || { echo "boundary: SKIP (no mere)"; exit 0; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

versions=$(ls boundary/v*.mere 2>/dev/null | sed 's|.*/||; s|\.mere$||' | sort -V)
[ -n "$versions" ] || { echo "boundary: FAIL — no versions in boundary/"; exit 1; }

for v in $versions; do
  "$MERE" "boundary/$v.mere" encode > "$tmp/$v.out" 2>"$tmp/$v.err" \
    || { echo "boundary: FAIL — $v could not encode"; head -3 "$tmp/$v.err"; exit 1; }
  head -1 "$tmp/$v.out" > "$tmp/$v.payload"
  [ -s "$tmp/$v.payload" ] || { echo "boundary: FAIL — $v encoded nothing"; exit 1; }
done

{
  echo "# produced by boundary.sh"
  echo "#"
  echo "# What each shipped version puts on the wire. Recorded because the"
  echo "# accept/reject matrix cannot see a change both sides still tolerate."
  for v in $versions; do echo "$v payload : $(cat "$tmp/$v.payload")"; done
  echo "#"
  echo "# encoder -> decoder"
  echo "# fail = a client on the encoder version cannot read a server on the"
  echo "#        decoder version, which during a rolling deploy is every browser"
  echo "#        holding a cached admin.wasm"
  for enc in $versions; do
    for dec in $versions; do
      r=$("$MERE" "boundary/$dec.mere" decode "$(cat "$tmp/$enc.payload")" 2>/dev/null | head -1)
      case "$r" in ok|fail) ;; *) r="ERROR($r)" ;; esac
      echo "$enc -> $dec : $r"
    done
  done
} > "$tmp/matrix"

cells=$(grep -cE '^v[^ ]* -> v[^ ]* : ' "$tmp/matrix")
[ "$cells" -gt 0 ] || { echo "boundary: FAIL — crossed 0 pairs"; exit 1; }

if [ "${1:-}" = "--update" ]; then
  cp "$tmp/matrix" "$EXPECTED"; echo "boundary: wrote $EXPECTED ($cells cells)"; exit 0
fi
[ -f "$EXPECTED" ] || { echo "boundary: FAIL — no $EXPECTED (run with --update)"; exit 1; }

if diff -u "$EXPECTED" "$tmp/matrix" > "$tmp/d" 2>&1; then
  broken=$(grep -c ': fail' "$tmp/matrix")
  echo "boundary: $cells pairs crossed, matrix unchanged ($broken recorded as incompatible)"
  exit 0
fi
echo "boundary: FAIL — the compatibility matrix changed"
echo "  ok -> fail is a break you are about to deploy."
echo "  fail -> ok means it was fixed; update $EXPECTED."
echo "  A changed payload line is a wire change even if no cell moved."
sed 's/^/  /' "$tmp/d"
exit 1
