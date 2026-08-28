# PAIN log — mere-blog dogfood

Friction hit building a **Rails-ish web + PostgreSQL app** in Mere, on top
of the existing `contrib/http` + `contrib/db/pg` batteries. The novel angle
vs the earlier dogfoods (mere-notes = realtime web/ws/redis, mq = native
CLI) is a **typed model layer** — turning the raw `(str option list) list`
rows `pg_query` returns into typed records — i.e. the "schema ↔ type"
mapping problem in an ML with no metaprogramming / reflection.

Each entry is a signal for a language / library / tooling improvement.
Status legend: 🔴 open · 🟡 worked around · 🟢 fixed upstream

---

## B1 🟢 `let main = …` collided with the synthesized entry (diagnostic fixed upstream)

The program's trailing top-level expression compiles to a Wasm `$main`
export. Naming a top-level binding `let main = fn () -> …` also emits
`$main`, so the module has two — and `mere -w` reported nothing; the clash
only surfaced from `wat2wasm`:

```
error: redefinition of function "$main"
```

Worked around by renaming the entry function to `run`.

**Fixed upstream (mere `6a12b06`):** it turned out a reserved-name warning
existed but only fired on the *interp* path, not the compile paths
(`-c` / `-ll` / `-w`) where the clash actually bites — so the compile
paths now run it too, and `main` gets a purpose-specific message ("reserved
for the program entry point … rename this binding") instead of the generic
"collides with a libc symbol" line. The clash is now caught at `mere -w`
with a clear message rather than downstream in `wat2wasm`.

## B2 🟢 Backends couldn't destructure a constructor/record in `let` (fixed upstream)

The natural decoder primitive returns a value plus the unread columns, and
the ideal shape is a named single-constructor wrapper:

```
type 'a Decoded = Decoded of 'a * (str option list);
let (id, r1) = ...            // needs: let Decoded (id, r1) = dec_int row
```

But the Wasm backend rejects a constructor pattern in `let`:

```
codegen error: unsupported (wasm codegen, Phase 6.1 MVP):
  non-P_var let pattern — Phase 6 later slice
```

Curiously **tuple** `let (a, b) = …` *does* compile, but constructor
(and, it turned out, record) patterns in `let` failed — and not just on
Wasm: the **C and LLVM backends had the same gap** (only the interp
accepted every pattern). A three-backend parity gap.

**Worked around** by having decoders return a bare tuple
`(value, remaining)` instead of a `Decoded of …` wrapper — tuple `let`
destructuring works everywhere, so the cursor-threading builder style
survives, just without the descriptive constructor name.

**Fixed upstream** (mere `047662e`): each backend's `let` handler now
desugars a general irrefutable pattern to a single-arm
`match value with | pat -> body`, reusing the existing pattern compiler.
Verified across interp + C + Wasm + LLVM. Once a mere release ships this,
the decoders can go back to the named `Decoded of …` wrapper.

## B3 🟢 No record → JSON serialization (fully closed: `to_json`, mere v0.1.6)

M2's HTTP layer builds JSON responses by hand (`jstr` for escaping +
string concatenation of each field), exactly as `examples/http_todo_pg`
does — its own comment concedes "a real API would centralize this." The
typed model layer produces `Post` / `Comment` records, but turning a
record into JSON is still manual: there's no record → JSON encoder, and
building a `Json.json` value from a record by hand is the same boilerplate
as concatenating strings. Serialization is the mirror of the row-decoder
problem (B2 space) — reflection would derive it, but Mere has none.

**Addressed in-repo (M4):** built encoder combinators in `orm.mere` that
mirror the decoders — value encoders (`enc_int` / `enc_str` / `enc_bool` /
`enc_str_opt`) plus `enc_obj` (object from `(key, encoded-value)` pairs)
and `enc_arr`. A model now writes
`enc_obj (Cons (("id", enc_int p.id), …))` instead of hand-concatenating,
and escaping lives in one place. Nice side effect: the `{` /
string-interpolation escaping papercut (a literal `{` in a string must be
written `\{`) is now confined to a single spot in `orm.mere` instead of
being sprinkled across every handler's JSON strings.

**Promoted upstream (mere v0.1.4):** the `dec_*` + `enc_*` pair graduated
into `contrib/orm` (`module Orm`). This repo now `mere install`s it and
uses `Orm.dec_*` / `Orm.enc_*`, keeping only the pg-specific query runner
local — so the reduction round-trips: dogfood → language/library fix →
release → app consumes the package. Positive counterpoint: composing
`contrib/http` (router, json_body) with the typed model layer had **zero
friction** — routing, path-param captures, and body parsing all fit
together cleanly on the first try.

**Fully closed (mere v0.1.6 → M9):** the "longer term a derive" became
real. `to_json` — a structural, compile-time-specialized builtin (the JSON
sibling of `show`, no trait machinery; interp / C / Wasm) — serializes any
typed record/list to JSON directly. `app.mere` deleted its per-model
writers and the `enc_obj` calls; handlers are now just `to_json p` /
`to_json (posts_all fd)`, and it shrank ~40%. Only two projection records
stay explicit: `UserPublic` (never leak `pw_hash` — `to_json` on a `User`
would include it) and `PostView` (the post+comments composite). The full
loop: dogfood found B3 → mere grew `to_json` → released v0.1.6 → the app
dropped its JSON layer.

## B4 🟢 Deep `Cons (…, Cons (…, Nil))` nesting — feature existed, I missed it

Early on I built route tables, SQL batches, query-param lists, and JSON
field lists by hand-nesting `Cons`, so an 11-route table ended in
`Nil)))))))))));` and a miscount (5 closing parens for 6 `Cons`) was easy —
and the parse error pointed deep *inside* an unrelated string literal, not
at the paren. I logged this as "no list literal."

**It turns out Mere already has list literals** — `[a, b, c]` desugars to
`Cons`/`Nil`, `[]` is `Nil`, and there are even comprehensions
(`[f x | x <- xs, cond]`). This was a **discoverability miss on my part**,
not a language gap. Fixed by rewriting the whole app to `[...]`: routes,
`schema_sql`, query params, and `enc_obj` / `enc_arr` field lists are now
list literals, and the two JSON arrays use comprehensions
(`Orm.enc_arr [post_json p | p <- ps]`). **Signal:** the feature is great
but underadvertised — a mention in the language tour / a friendlier
unbalanced-paren diagnostic would have saved the detour.

## B5 🟢 No JSON → typed decode (closed: `of_json` / `of_json_opt`, mere v0.1.7)

`to_json` (B3) closed the *serialize* side, but request bodies were still
plucked field-by-field with `body_field "username"` — a flat, string-only
`parse_json_body` helper with no typing, no nesting, and silent `""` for
missing keys. The symmetric gap: no JSON → typed value decoder.

**Fully closed (mere v0.1.7):** `of_json : str -> 'a` is the structural
inverse of `to_json` — target type from an annotation, JSON object → record
fields by name, array → list/tuple, `null`/value → option. But it *fails
fast* (raises / on native `exit`s) on malformed input, which would crash
the server on a bad request. So mere grew **`of_json_opt : str -> 'a
option`** too, which returns `None` on any parse/shape error. `app.mere`'s
auth/post/comment handlers now decode into typed request records
(`Credentials`, `NewPost`, `NewComment`) with `of_json_opt`, matching on
`Some req` / `None -> 400`. Verified end-to-end on the **native binary**:
a valid body → 201, a malformed body → 4xx, and the server **stays up**
(the whole point of the `_opt` variant).

The loop: dogfood found the decode gap + that fail-fast is unsafe for
untrusted input → mere grew `of_json` **and** `of_json_opt` → the app
dropped `body_field` for typed decoding.

**Backend coverage:** `of_json` / `of_json_opt` shipped interp + C in
v0.1.7, then the **Wasm backend in v0.1.8** — so both the wasm/Node and the
single-native-binary builds decode request bodies. (LLVM still lacks the
JSON derives, as it lacks `to_json` too.)

## Positive: session/cookie auth composed cleanly

M6 added signup / login / logout / me + per-post ownership on top of
`contrib/http/session` (session_new_store / session_current /
session_login / session_logout) and the `sha256_hex` host extern, with a
`User` model in the typed layer. It came together without new language
friction: the session store is a plain closed-over `map`, ownership is a
`str_eq post.author current_user` check, and `user_json` simply omits
`pw_hash`. Verified end-to-end (401 when logged out, 403 for another
user's post, 409 on duplicate signup, cookie round-trip across requests).

## Native full-stack: the app compiles to one native binary

Everything above ran on Wasm + a Node host (contrib/http `http_serve`,
contrib/db `tcp_connect`, … are host externs). Pushing the same `app.mere`
through the C backend (`mere -c | clang`) surfaced the last frontier: the
native backend had no sockets, no HTTP server, and no crypto, and a Mere
`int` is 32-bit (too narrow for a 64-bit pointer, which the wire-protocol
code assumes it can pass around as an address).

Fixed upstream in the Mere C backend (native full-stack Stage 1-4):

- a **Wasm-style byte arena** (`__mem`, 32-bit offsets) backing the
  `mem_*` / `str_ptr` externs, so pg's binary wire protocol works
  unchanged; **POSIX-socket** `tcp_*`; a **native `http_serve`** accept
  loop; real **SHA-256** (`sha256_hex`) + `gen_request_id`.
- **C-backend bug found & fixed**: `escape_string` emitted a raw carriage
  return into C string literals (it handled `\n`/`\t` but not `\r`),
  breaking any string with a CR — surfaced by compiling pg's COPY
  unescape to C for the first time.

**Result**: `mere -c app.mere | clang` → a ~264 KB binary serving the blog
against Postgres with signup/login/logout + ownership, no Node/Wasm.
Deferred (stubbed with a warning): Postgres **SSL** and **SCRAM** password
auth on native — they need libssl FFI + native SCRAM crypto (use trust /
plaintext for now).

## Positive: the typed model layer paid off at the HTTP boundary

Handlers read like Rails: `post_find fd id` returns a `Post option`,
`comments_for fd id` a `Comment list`, and JSON is built from typed fields
(`p.title`, `c.author`) — SQL and raw `(str option list)` rows never
appear in `app.mere`. The model layer (M1) is what makes the web layer
(M2) thin.

## B6 🟢 A native binary could not be configured, and could not answer TLS

Two things this app did that read as ordinary application code and were in fact the
only thing the compiler allowed:

```mere
let fd = pg_connect "127.0.0.1" 15499 "postgres" "" "blog";   // app.mere, before
let _  = http_serve 8080 handle;
```

**The literals were not laziness.** Until mere v0.1.337 the C backend had no lowering
for `env_var` — it existed in the interpreter and on the Wasm *component* backend, so
it looked implemented — which meant a `mere -c` binary had no way to be told anything
at startup. Changing a database host meant editing this file and recompiling it. Three
files each kept their own copy of the same five constants, which is what a language
without configuration does to a codebase.

**The plaintext was not a deployment choice.** Until v0.1.338 `tcp_starttls` could
upgrade a socket this program had dialled, but nothing could answer a TLS connection.
`grep tcp_starttls` finds TLS in the tree, so the surface looked complete.

**What made both durable is the same thing, and it is the finding.** Neither was ever
written down. This README did not recommend a proxy, did not mention TLS for serving,
did not note that the constants were unchangeable. It said `serves :8080` and moved on.
A missing capability that nobody tries to use produces no workaround — and a workaround
is the artifact that would have made it visible. The gaps were not hidden behind
anything; there was nothing in their place.

Both are closed. `config.mere` reads the environment; `http_serve_tls` terminates TLS
in-process. `verify.sh` now passes the app a port that is deliberately **not** its
default, so the configuration is checked by being used rather than asserted, and adds
four TLS checks driven by curl without `-k`.

## B7 🟢 The server answered one request at a time, and two bugs were hiding behind it

`http_serve` is a sequential accept loop. Measured upstream: eight requests against a
400 ms handler take **3.27 s**, not 0.4 s. Nothing here said so — this README described
`serves :8080` and moved on — so "the app works" and "the app can serve anyone" were
different claims and only the first had ever been checked.

**Making it concurrent did not introduce two bugs; it revealed two.**

- **One connection for the process.** The comment on that line said "a pool would be the
  next step". It was not a missing optimisation: two requests interleaving on one
  Postgres socket corrupt the protocol. It was correct only because the loop was
  sequential.
- **Sessions in a `Map`.** Concurrent SET/GET on a lock-free array lose writes. The
  compiler does not catch it — `Map` is not classified as unshareable (mere Q-080) —
  so this would have raced silently.

Both are fixed by the same idea, and it is not a pool: `http_serve_mt_ctx` gives each
worker its own context, built once by that worker and never shared. The number of
connections is the number of workers by construction, there is no moment where a
handler must give one back, and so a handler that fails cannot lose one. Sessions moved
into a `sessions` table.

**What the gate asserts is the restart, not the race.** A race is not something a check
can state: log in, restart the server, present the same cookie. Only the database-backed
store passes that, and it is the same change.

## The current compiler (M11)

Building the admin UI meant compiling this app with a compiler newer than the
one `mere.toml` pins, and four things broke at once. All four are the same
shape: a boundary that was written when a Mere value was 4 bytes and a Mere
`str` was a plain C string, and was never revisited when both changed.

- **`to_json` had no working Wasm backend.** Every case of the emitter still
  built 4-byte cells with i32 fields, so wat2wasm rejected any module that
  serialized anything. Since M9 this app serializes a typed record on every
  response, so the entire Wasm target was closed to it.
- **The native HTTP server passed a raw C string as the request line.** A Mere
  `str` carries its length in the word before byte0, so the handler read "" and
  every route 404'd. `http_current_body` and `http_get_header` had it too.
- **`sha256_hex` returned "".** The hex and base64 producers malloc'd their
  results instead of allocating through the Mere allocator, so every password
  hash was empty and signup failed with a 500.
- **A `unit` parameter broke extern closure adapters on C.** `extern fn
  http_current_body: unit -> str` lowers to a 0-arity C function, but the
  adapter passed an argument to it and the generated C would not compile.

The lesson is not the individual bugs but that **nothing detected the
mismatch**. The vendored `.mere_host/` is pinned to a release whose JS glue
still uses the old closure ABI and the old string layout, so a build made with
a current compiler links fine and then fails on the first request. A host and a
compiler have an ABI between them and nothing checks it.

`of_json` on Wasm was the fifth: the parser runtime and every generated decoder
were still 4-byte-model, so typed request decoding had no Wasm backend and M11
started out native-only. Rebuilt upstream (mere v0.1.156), along with two more
of the same shape — `mem_to_str` in the pg host glue, which is where every
column value becomes a str (an entire result set read back empty), and the
response-body read, which scanned for a NUL and so truncated a `.wasm` asset at
its first byte. This app now builds and runs on both backends.

Seven bugs, one shape. What makes them worth writing down is that each one was
invisible until something downstream measured or concatenated the value:
`print` formats with `%s` and stops at the NUL, so a broken string prints
perfectly and then breaks the moment it is used.

## Pinning to a newer revision (M11)

Repointing the dependencies at a current commit surfaced one more: `mere
install` clones a dependency's repo once and caches it, keyed by
repo-and-rev, but never fetches into an existing cache. So the first
install after a new commit is pushed fails with

```
fatal: reference is not a tree: 6ab39ac7…
```

and the only remedy was deleting `~/.mere/cache` by hand. Fixed upstream by
fetching before checkout. Worth noting that the failure mode is a git error
with no mention of the cache, which is a long way from the cause.

With that fixed, `mere install` pins every dependency and the host runtime to
one commit, and `mere serve` runs the app on it — the packaged path works again
end to end, which it had not since the compiler's value representation moved
past the pinned host.
