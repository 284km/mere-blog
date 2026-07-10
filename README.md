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
- ✅ **M1**: typed model layer. `orm.mere` (decoder primitives +
  `query_as` / `insert_returning`) + `model.mere` (`Post` / `Comment`
  records, `posts_all` / `post_create` / `comments_for` / …). `demo.mere`
  creates a post, lists typed `Post` records, adds and lists typed
  `Comment`s — SQL and raw rows stay behind the model functions.
- ✅ **M2**: HTTP layer. `app.mere` serves the blog over HTTP via
  `contrib/http` (router + json body): `GET /` (HTML index), `GET
  /api/posts`, `GET /api/posts/:id` (post + comments), `POST /api/posts`,
  `POST /api/posts/:id/comments`. JSON is built from the typed records, so
  the model layer keeps the handlers thin.

## Run the server

```bash
mere -w app.mere > /tmp/app.wat
wat2wasm --enable-tail-call /tmp/app.wat -o /tmp/app.wasm
node .mere_host/run_http_server.js /tmp/app.wasm   # serves :8080

curl -s localhost:8080/api/posts
curl -s -X POST localhost:8080/api/posts \
  -d '{"title":"Hi","body":"...","published":"true"}'
curl -s localhost:8080/api/posts/1
```

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
