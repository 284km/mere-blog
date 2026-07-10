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

## B2 🟡 Wasm backend can't destructure a constructor in `let`

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

Curiously **tuple** `let (a, b) = …` *does* compile on Wasm, and the interp
+ C backends accept both — so this is a Wasm-only parity gap, specific to
constructor (not tuple) patterns in `let`.

**Worked around** by having decoders return a bare tuple
`(value, remaining)` instead of a `Decoded of …` wrapper — tuple `let`
destructuring works everywhere, so the cursor-threading builder style
survives, just without the descriptive constructor name. **Signal:** lower
constructor `let` patterns on the Wasm backend the same way `match` already
does (or desugar `let pat = e` to a one-arm `match`), so backends reach
parity.
