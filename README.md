# mere-blog

A small blog (posts + comments) written in [Mere](https://github.com/merelang/mere) —
a Rails-ish web + PostgreSQL app built to **dogfood a typed model layer** on
top of the existing `contrib/http` + `contrib/db/pg` batteries.

The interesting problem: `pg_query` returns raw `(str option list) list`
rows. Turning those into typed records (`Post { id; title; … }`) with no
metaprogramming or reflection — the "schema ↔ type" mapping in an ML — is
what this app exercises. Pain found along the way feeds back upstream; see
[PAIN.md](./PAIN.md).

## Status

- ✅ **M0**: schema + raw pg round-trip. `migrate.mere` connects, creates
  the `posts` / `comments` tables, seeds a post, reads it back through the
  raw driver — proving the vendored host + `contrib/db/pg` path works.

## Stack

- **Web**: `contrib/http` (router, json_body, …)
- **DB**: `contrib/db/pg` — a pure-Mere PostgreSQL wire-protocol client
- **Model layer**: hand-written row decoders + typed query helpers (this repo)
- **Runtime**: compiled to Wasm, run on the vendored Node host (`mere serve`)

## Develop

```bash
mere install                          # deps (.mere_modules/) + host (.mere_host/)

# a trust-auth Postgres for local dev (port 15499, db "blog"):
docker run -d --name mere-blog-pg -p 15499:5432 \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -e POSTGRES_USER=postgres -e POSTGRES_DB=blog postgres:16

# run the migration / smoke test:
mere -w migrate.mere > /tmp/m.wat
wat2wasm --enable-tail-call /tmp/m.wat -o /tmp/m.wasm
node .mere_host/run_wasm.js /tmp/m.wasm
```
