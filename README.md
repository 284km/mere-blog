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
  `contrib/http` (router + json body). JSON is built from the typed
  records, so the model layer keeps the handlers thin.
- ✅ **M3**: full CRUD. `PUT /api/posts/:id` (update) and `DELETE
  /api/posts/:id` (204 / 404) added, backed by `post_update` /
  `post_delete` (UPDATE / DELETE … RETURNING).
- ✅ **M4**: JSON encoder combinators. `orm.mere` gains `enc_int` /
  `enc_str` / `enc_bool` / `enc_str_opt` + `enc_obj` / `enc_arr` — the
  mirror of the row decoders. Handlers encode records with
  `enc_obj (Cons (("id", enc_int p.id), …))` instead of hand-rolled string
  concatenation; escaping is centralized.
- ✅ **M5**: deploy via `mere serve`. The compiled wasm runs on the host
  vendored into `.mere_host/` — the same packaged-deployment path
  mere-notes uses, now confirmed for a Postgres-backed HTTP app.
- ✅ **M6**: auth + ownership. `users` table + a `User` model; `POST
  /api/signup`, `POST /api/login`, `POST /api/logout`, `GET /api/me` via
  `contrib/http/session` (cookie sessions) with `sha256_hex` password
  hashing. Posts record their `author`; creating a post requires login,
  and only the author may update/delete their own (403 otherwise).
- ✅ **M7**: the local decode/encode combinators graduated upstream into
  `contrib/orm` (mere v0.1.4). This repo now `mere install`s `orm` and
  uses `Orm.dec_*` / `Orm.enc_*`; only the pg-specific query runner
  (`query_as` / `insert_returning`) stays app-local. The dogfood's typed
  layer is now a reusable package.

Endpoints: `GET /`, `POST /api/signup`, `POST /api/login`,
`POST /api/logout`, `GET /api/me`, `GET /api/posts`, `GET /api/posts/:id`,
`POST /api/posts` (auth), `PUT /api/posts/:id` (author only),
`DELETE /api/posts/:id` (author only), `POST /api/posts/:id/comments`.

## Run the server

```bash
mere -w app.mere > /tmp/app.wat
wat2wasm --enable-tail-call /tmp/app.wat -o /tmp/app.wasm
mere serve /tmp/app.wasm            # runs the wasm on the vendored host, :8080

curl -s localhost:8080/api/posts
curl -s -X POST localhost:8080/api/posts \
  -d '{"title":"Hi","body":"...","published":"true"}'
curl -s localhost:8080/api/posts/1
curl -s -X PUT localhost:8080/api/posts/1 \
  -d '{"title":"Edited","body":"...","published":"true"}'
curl -s -X DELETE localhost:8080/api/posts/1
```

`mere serve` uses the runtime host vendored into `.mere_host/` by
`mere install` (no compiler checkout needed at runtime).

## Stack

- **Web**: `contrib/http` (router, json_body, …)
- **DB**: `contrib/db/pg` — a pure-Mere PostgreSQL wire-protocol client
- **Model layer**: `contrib/orm` (row decoders + JSON encoders, graduated
  from this dogfood) + a small pg-specific query runner in this repo
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
