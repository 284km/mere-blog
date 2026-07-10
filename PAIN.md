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

## B1 🟡 `let main = …` silently collides with the synthesized module entry

The program's trailing top-level expression compiles to a Wasm `$main`
export. Naming a top-level binding `let main = fn () -> …` also emits
`$main`, so the module has two — but `mere -w` reports nothing; the clash
only surfaces from `wat2wasm`:

```
error: redefinition of function "$main"
```

Worked around by renaming the entry function to `run`. **Signal:** the
compiler should either reject a user `main` binding with a clear message
or namespace user bindings away from the synthesized entry — surfacing a
codegen name clash through a downstream tool is a poor diagnostic.

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

## B3 🟡 No record → JSON serialization; every app hand-rolls it

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
release → app consumes the package. Longer term a derive would remove even
the field-by-field wiring. Positive counterpoint: composing `contrib/http` (router,
json_body) with the typed model layer had **zero friction** — routing,
path-param captures, and body parsing all fit together cleanly on the
first try.

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

## Positive: session/cookie auth composed cleanly

M6 added signup / login / logout / me + per-post ownership on top of
`contrib/http/session` (session_new_store / session_current /
session_login / session_logout) and the `sha256_hex` host extern, with a
`User` model in the typed layer. It came together without new language
friction: the session store is a plain closed-over `map`, ownership is a
`str_eq post.author current_user` check, and `user_json` simply omits
`pw_hash`. Verified end-to-end (401 when logged out, 403 for another
user's post, 409 on duplicate signup, cookie round-trip across requests).

## Positive: the typed model layer paid off at the HTTP boundary

Handlers read like Rails: `post_find fd id` returns a `Post option`,
`comments_for fd id` a `Comment list`, and JSON is built from typed fields
(`p.title`, `c.author`) — SQL and raw `(str option list)` rows never
appear in `app.mere`. The model layer (M1) is what makes the web layer
(M2) thin.
