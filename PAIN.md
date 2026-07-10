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

**Worked around** with per-model `post_json` / `comment_json` writers.
**Signal:** an encoder-combinator story that mirrors the decoders
(`enc_int` / `enc_str` / an object builder) — or, longer term, a derive —
would remove the most repetitive part of a JSON API. Positive counterpoint:
composing `contrib/http` (router, json_body) with the typed model layer
otherwise had **zero friction** — routing, path-param captures, and body
parsing all fit together cleanly on the first try.

## Positive: the typed model layer paid off at the HTTP boundary

Handlers read like Rails: `post_find fd id` returns a `Post option`,
`comments_for fd id` a `Comment list`, and JSON is built from typed fields
(`p.title`, `c.author`) — SQL and raw `(str option list)` rows never
appear in `app.mere`. The model layer (M1) is what makes the web layer
(M2) thin.
