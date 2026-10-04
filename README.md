# db

`db` was originally built inside [Flux](https://github.com/odunboye/flux)
(as `flux-db`, itself an outright rename of an earlier package called
Nebula) and later moved back out to its own repo, since it has no
Flux-specific dependencies - see "Install / build" below. The module
prefix changed from `Flux.DB.*` to `DB.*` as part of that move.
Read [MIGRATION.md](MIGRATION.md) before upgrading an existing database -
it predates the repo split and still documents the Nebula cutover.

A derivable active-record layer, typed query builder, and repository
pattern for Idris2 apps - `Row`<->record mapping, generated CRUD, a
typed `SELECT` builder, and a generic `Repository` every app can extend
with its own domain-specific operations. Built
on [postgres](https://github.com/odunboye/postgres) today; postgres itself stays a primitive
Postgres wire-protocol client only - everything that maps a `Row` onto
an application record type lives here instead, so it isn't tied to one
backend forever (see "Backends" below). Deliberately has no dependency
on any HTTP framework - `flux-db-flux` (in the Flux repo) is the Flux
adapter (`dbIO`/`query`/`command`/`decodeRows`/`decodeOne`/`requireId`),
kept in its own package there so a consumer that only wants this
active-record/query-builder layer isn't forced to pull in Flux and its
own dependency tree too.

## Why this exists

An app using postgres directly would otherwise hand-write, per project:
the `Row`<->record decode/encode boilerplate for every table, the basic
CRUD calls, and a `CREATE TABLE` for each type. None of that is
app-specific - no schema, no routes, no handlers - so it belongs in a
shared library instead of being re-derived per project. `todo-api`
(an example app in the Flux repo) is the first real consumer; this
library exists so the second one doesn't re-derive any of it.

## Active-record layer: deriving `Row`<->record mapping and CRUD

For the common case - a record type that maps one-to-one onto a table -
`%runElab derive` can generate the `Row` decoding/encoding and the basic
CRUD calls, instead of hand-writing them per type:

```idris
import DB.Field
import DB.Row
import DB.Table
import DB.Derive.ActiveRecord
import DB.Crud

%language ElabReflection

record User where
  constructor MkUser
  id    : Integer
  name  : String
  email : String

%runElab derive "User" [FromRow, ToRow, Table]
%runElab deriveInsertable Nothing "User"

main : IO ()
main = do
  Right db <- connectDB (mkPGConfig "127.0.0.1" 5432 "myuser" "mypassword" "mydb")
    | Left err => putStrLn (displayError err)
  Right user   <- insert db (MkNewUser "Ada" "ada@example.com")
    | Left err => putStrLn (displayError err)
  Right mFound <- findById {a = User} db user.id
    | Left err => putStrLn (displayError err)
  closeDB db
```

- **`FromRow`/`ToRow`** (`DB.Row`) decode/encode one field at a time,
  via a `FromField`/`ToField` typeclass (`DB.Field`) with instances
  for `String`/`Int`/`Integer`/`Double`/`Bool`, plus a blanket
  `FromField a => FromField (Maybe a)`/`ToField a => ToField (Maybe a)`
  that maps SQL `NULL` to `Nothing` (something none of postgres's raw
  `Data.PGValue` getters do on their own).
- **`Table`** (`DB.Table`) generates static per-type metadata - table
  name, column list, primary-key column - plus the four fixed SQL
  strings the CRUD calls below run, computed once at compile time so
  they're literal, byte-identical every call (this matters: postgres's
  `DB` prepared-statement cache is keyed by exact SQL text). Table name
  defaults to the exact-lowercase type name (`User` → `"user"`) - no
  pluralization guessing - and the primary key defaults to a field
  literally named `id`; override either with `customTable`:
  `customTable Export (Just "users") Nothing []` in place of `Table` in
  the derive list, for a table name that doesn't match the type name.
- **`Table` also generates `createTableSql`** - a real
  `CREATE TABLE IF NOT EXISTS` - via `DB.ColumnType`, a typeclass
  mapping an Idris type to its column type
  (`String`/`Bool`/`Int`/`Integer`/`Double`, `Maybe a` for a nullable
  column; add your own instance for a type of your own, e.g. an enum
  stored as `TEXT`). Unlike `Table`'s other SQL strings, this one is a
  genuine runtime-dispatched value, not a compile-time literal - DDL
  normally runs once at startup, so the prepared-statement-cache
  argument above doesn't apply, and a real typeclass means you aren't
  limited to types this library already knows about. The primary key
  gets `SERIAL`/`BIGSERIAL` if its type has one (`Int`/`Integer`); a
  type without an auto-increment form (a `String` UUID/slug key, say)
  falls back to its plain column type plus `PRIMARY KEY`. `customTable`'s
  fourth argument, `columnDefaults : List (String, String)` (column name
  → raw SQL default expression), adds a real `DEFAULT` clause -
  `customTable Export Nothing Nothing [("done", "false")]` generates
  `done BOOLEAN NOT NULL DEFAULT false`. (This design deliberately
  mirrors [Drift](https://github.com/simolus3/drift)'s own two-defaults
  split for Dart/SQLite: `columnDefaults` is Drift's `withDefault()` - a
  real DB-level default; `deriveInsertable`'s pk-less companion record,
  below, is flux-db's equivalent of Drift's `clientDefault()` - an
  application-side default needing no schema support, since the caller
  always supplies every field of the companion type explicitly.)
  No migrations, and no other constraints (`UNIQUE`/`CHECK`/foreign
  keys) - `createTableSql` only ever runs on a fresh table
  (`IF NOT EXISTS`), so a later change to a type's fields won't `ALTER`
  an existing one; for anything past the structural common case, write
  real SQL/migrations by hand, same as always.
- **`deriveSubset`** generates a companion record containing only the
  named fields you list - an INCLUDE-list, not an exclude-list - plus
  runs any `derive`-style items you like against it:
  `deriveSubset ["title","done"] "TodoUpdate" [FromJSON] "Todo"` declares
  `TodoUpdate`/`MkTodoUpdate` (with real field accessors - `tu.title`
  works, same as if you'd hand-written the record) and a `FromJSON
  TodoUpdate` instance, in one line. `derives` can be anything
  `derive`-shaped - this module's own `FromRow`/`ToRow`, `elab-util`'s
  `Show`/`Eq`, `json-simple`'s `FromJSON`/`ToJSON`, not just flux-db's
  own. Deliberately inclusive by default: something built from untrusted
  input (an HTTP request body, say) shouldn't silently gain a new
  accepted field just because the original record gained a column.
- **`deriveInsertable`** is `deriveSubset` specialized the other way -
  every field EXCEPT `pk` (default `"id"`) - for `insert`'s companion
  record (`New<Type>`, e.g. `NewUser`): Postgres assigns the real `id`
  (`SERIAL`/`BIGSERIAL`, if `Table`'s generated `createTableSql` is
  what created the table), so there's no real value to put in one, and
  a separate type means you can't accidentally pass a stray id that gets
  silently ignored. Excluding the pk is the one place an exclude-shape
  still makes sense; `deriveSubset` itself stays include-only.
  Both are a genuinely different kind of derivation from `FromRow`/
  `ToRow`/`Table` above: they declare a brand new record type (not just
  an instance for an existing one), so each is its own standalone
  `%runElab` line, not one more item in `derive`'s own list - see the
  doc comments in `DB.Derive.ActiveRecord` for why, and for a real
  Idris2-elaborator gotcha this surfaced (two reflection-declared
  records sharing a field name collide unless each is given its own
  nested namespace, same as a normal `record` block gets implicitly).
- **`DB.Crud`** provides the actual CRUD calls, generic over any
  `Table`/`FromRow`/`ToRow`/`Insertable` instance rather than
  per-type-generated: `insert`, `findById`, `update` (whole-record
  replace of every non-pk column), `deleteById`. "Not found" is
  `Right Nothing`/`Right False`, not an error. `findById`/`deleteById`
  don't take the target type as an argument, so a call site needs
  `{a = User}`.
- **`deriveColumns`** + **`DB.Query`** - a typed `SELECT` query
  builder, inspired by [Drift](https://github.com/simolus3/drift) (Dart/
  SQLite)'s `select(table)..where(...)..orderBy(...)..limit(...)`.
  `%runElab deriveColumns "User"` generates `UserColumns`/`userColumns`
  (typed column references - `userColumns.email : Column User String`,
  with real field accessors, the same `IRecord`+namespace mechanism
  `deriveSubset`/`deriveInsertable` already use), and
  `userColumns.email ==. "ada@example.com"` builds a `Condition User`
  via hand-written operators (`==.`/`/=.`/`<.`/`>.`/`<=.`/`>=.`/`&&.`/
  `||.`/`isNull`/`isNotNull`/`not_` - confirmed directly that Idris2 has
  no reflection mechanism to *generate* new infix operators, so these
  are ordinary source, not code-generated). Compose a `Query` with
  `selectAll |> where_ cond |> orderByAsc userColumns.name |> limit 10`,
  run it with `selectQuery : (Table a, FromRow a) => DB -> Query a -> IO
  (Either PGError (List a))` - which, like every other `IO (Either
  PGError a)`-shaped call in this library, composes with `dbIO` (below)
  inside a Flux handler with zero extra glue needed. `LIMIT`/`OFFSET` are
  `$N` placeholders, not literals, so paging through the same
  filtered/sorted query reuses one `DB.stmtCache` entry instead of
  minting a new one per page. Single-table only - no JOINs, no raw-SQL
  escape hatch, no `LIKE` (a clean later addition, same shape as the
  comparison operators). `insert`/by-pk `update`/`deleteById` (above) are
  unaffected; a bulk `updateWhere`/`deleteWhere` by condition would reuse
  `compileCondition` cheaply as a later addition, not built yet.

Deliberately out of scope: no relations/joins, no migrations, no
partial-update/PATCH, and no dedicated error case for constraint
violations (inspect postgres's `SqlError`'s `code`/`constraintName`
yourself, same as always). This is meant for the common "one record, one
table, basic CRUD plus simple filtering" case - anything more exotic
still goes through postgres's own `queryRows`/`execCommand` directly.

## Repository pattern: `DB.Repository`

A generic CRUD+query repository, bound to one `DB` connection - the same
integration pattern every app gets for free, instead of handlers taking
a raw `DB` directly:

```idris
import DB.Repository

getUser : DB -> Integer -> IO (Either PGError (Maybe User))
getUser db uid =
  let repo := pgRepository {ins = NewUser} db
   in repo.findById uid
```

```idris
public export
record Repository pk a ins where
  constructor MkRepository
  findById   : pk -> IO (Either PGError (Maybe a))
  insert     : ins -> IO (Either PGError a)
  update     : a -> IO (Either PGError (Maybe a))
  deleteById : pk -> IO (Either PGError Bool)
  query      : Query a -> IO (Either PGError (List a))
```

- **A plain record of functions, not an interface.** A caller is handed
  exactly the implementation it needs explicitly - `pgRepository db` (the
  real, Postgres-backed one below), or an app's own in-memory test
  double of the same shape - rather than relying on Idris2's global
  instance search to pick the right one. This is what actually makes the
  pattern useful for tests: a handler written against `Repository a ins`
  (or an app's own extension of it - see `todo-api`'s `TodoRepository`,
  which embeds this plus a hand-written `toggle`) doesn't care which
  value it's given.
- **`pgRepository`** builds the real implementation for free, once a
  type has the `Table`/`FromRow`/`ToRow`/`Insertable ins a` instances
  `%runElab derive [...]` already generates - every field just delegates
  to `DB.Crud`'s generic CRUD helpers and `DB.Query.selectQuery`.
- **HTTP-independent on purpose.** Every operation returns a plain
  `IO (Either PGError _)` - no `Context`/status codes/`AppProg`. A
  handler (in flux-db-flux, or an app) decides what a
  `Nothing`/`False`/`Left` becomes (a 404, a 500, ...); the repository
  just reports what happened. `Flux.DB.PG.dbIO` already lifts any of
  these into `AppProg` unchanged, the same way it already lifts
  `DB.Crud`'s own functions - no `flux-db-flux` changes were needed
  to add this.
- **The primary key (`pk`) is generic**, matching `DB.Crud.findById`/
  `deleteById`'s own genericity over the same name - any type with a
  `ToField` instance works. `DB.Field` already has one for `String`,
  so a UUID/slug key stored as text works today with no new code needed
  anywhere underneath this. Most apps still use `Integer`
  (`SERIAL`/`BIGSERIAL`) - `flux-db-flux`'s `requireId` stays
  `Integer`-only for exactly that reason (not generalized speculatively
  ahead of a real non-`Integer`-keyed consumer); an app that needs one
  reads its own path param as whatever type it needs and calls
  `repo.findById`/`repo.deleteById` directly - no `flux-db-flux` change
  required for that to already work.
- **An app's own domain-specific operations aren't here.** `DB.Crud`
  has no "list all"/partial-update primitive, so an app needing e.g. a
  partial update builds its own hand-written-SQL extension on top of
  this, reusing the now-exported `DB.Crud.decodeFirst` (the same
  "decode a single optional row" helper `findById`/`update` use
  internally) instead of duplicating it - see `todo-api`'s
  `TodoRepository.toggle` for a worked example. Flux DB supplies the
  generic piece and this extension point; the domain-specific operation
  itself is each app's own.

### Transactions: `withTransactionRepos`

```idris
export
withTransactionRepos : DB -> (DB -> repos) -> (repos -> IO (Either PGError a)) -> IO (Either PGError a)
```

Repositories are just values closing over a `DB` - `repo.findById`/etc
already participate in whatever Postgres transaction is active on that
connection (transactions are connection-scoped, not value-scoped), so
nothing *new* was needed for that part. What was missing was a
contract-level way to say "these operations run in one transaction",
instead of a caller manually threading `db`/postgres's own
`withTransaction` around raw repository calls and hoping they never mix
in a repository built from a different connection.
`withTransactionRepos` wraps postgres's `withTransaction` (BEGIN, then
COMMIT on `Right`/ROLLBACK on `Left`, no nesting) and hands the callback
repositories built via `mkRepos` from the SAME transactional connection
- a single repository, a tuple of several, or a record grouping many;
`mkRepos` decides the shape:

```idris
transferOwnership : DB -> Integer -> Integer -> IO (Either PGError ())
transferOwnership db widgetId newOwnerId =
  withTransactionRepos db
    (\txDb => (pgRepository {a = Widget} txDb, pgRepository {a = Owner} txDb))
    (\(widgetRepo, ownerRepo) => do
       ... -- both calls run in the same transaction; an error from
           -- either one rolls both back)
```

Verified against real Postgres (`test/src/Main.idr`'s
`testTransaction`, exercising `Widget`/`Gadget` together) for both
paths - reading through a SEPARATE connection from the one the
transaction itself ran on, so the check can't be fooled by read-your-
own-writes visibility on the transactional connection: a successful
callback commits writes across both tables (durably, visible from
elsewhere), and an error inside the callback - specifically after it
had already written successfully, not before - rolls back everything,
with `txStatus` back to `Idle` afterward either way.

## What this deliberately doesn't do

- **No relations/joins/migrations/partial-update** in the active-record
  layer - see "Active-record layer" above for the exact boundary.
- **No HTTP-framework glue in this package.** `dbIO`/`dbFail`/`query`/
  `command`/`decodeRows`/`decodeOne`/`requireId` - the functions that
  lift an `IO (Either PGError a)` call into a Flux handler - live in
  flux-db-flux (in the Flux repo) instead, so a consumer that only wants
  `Row`<->record mapping, CRUD, or the typed query builder isn't forced
  to depend on Flux at all.

## Backends

Built against [postgres](https://github.com/odunboye/postgres) today - `Table`/`DB.Crud`/
`DB.Query`'s `selectQuery`/`DB.Repository`'s `Repository` are all
typed against postgres's `DB`/`PGError`/`Row`. SQLite support is planned
next; the active-record/
query-builder design above (typeclass-driven `FromRow`/`ToRow`/`Table`/
`PGColumnType`, a hand-written condition/query AST rather than anything
postgres-specific baked into the elaborator reflection) was kept
deliberately backend-agnostic in shape for exactly this, but the actual
multi-backend split (what stays shared vs. what becomes a
`DB.SQLite`-style per-backend module) hasn't been designed yet - not
speculatively built ahead of that work.

## Explicit SQL migrations (experimental)

`DB.Migration` supplies `Migration` (`version`, `name`, `statements`) and
`runMigrations : PGConfig -> List Migration -> IO (Either PGError Nat)`.
Pass the complete ordered migration history; the result counts newly applied
versions. Versions must be strictly increasing positive BIGINTs.

The runner opens a **dedicated connection**, takes a nonblocking database-wide
session advisory lock, and checks `flux_db_meta.migrations` against the supplied
version/name/SHA-256 checksums. Missing or edited applied migrations fail
closed. Each migration's SQL and history insertion share one transaction;
a failure rolls back that migration, not earlier successful versions. Closing
the dedicated connection releases the lock even after protocol errors/timeouts.
A second runner fails immediately while the lock is held instead of waiting
indefinitely. Supply suitable explicit connect/read deadlines in `PGConfig`.

This is a deliberately conservative v1 SQL subset: CREATE/ALTER/DROP TABLE,
CREATE [UNIQUE]/DROP INDEX, INSERT INTO, UPDATE and DELETE FROM. Each entry is
one extended-protocol statement. Transaction control and multiple statements
per entry are rejected. Leading comments, CTEs, nontransactional migrations,
procedures and arbitrary session commands are unsupported. SQL remains trusted,
reviewed application code: do not mutate `flux_db_meta` or release the advisory
lock from a migration. Rollback covers PostgreSQL transactional effects, not
external effects triggered by user-defined database code.

There is no automatic schema diff, automatic destructive migration, downgrade,
or CLI yet. Review SQL explicitly before applying it to an intended environment.
The deployment role needs DDL permissions and access to the metadata schema.

The first integration checks were written against Flux's platform example
(`platform/example/MigrationTests.idr`, run by
`platform/test_pg_wire.py` in the Flux repo against its own disposable DB)
before this package moved out on its own; `test/src/Main.idr` here covers
the same migration runner directly.
They cover fresh install, replay, upgrade, drift, rollback/history atomicity,
held-lock exclusion/recovery, invalid versions and transaction-control rejection.

## Install / build

Requires [pack](https://github.com/stefan-hoeck/idris2-pack).

```sh
pack install db
```

Or, from a checkout of this repo:

```sh
pack build db.ipkg
```

## Running the tests

```sh
cd test
pack build test.ipkg
./build/exec/db-test
```

Needs a real Postgres - connection details come from `PG_TEST_HOST`/
`PG_TEST_PORT`/`PG_TEST_USER`/`PG_TEST_PASSWORD`/`PG_TEST_DB`, defaulting to
`127.0.0.1:5432`/`testuser`/`testpass`/`testdb` (same convention as
[postgres](https://github.com/odunboye/postgres)'s own test suite - see its
README for a `docker run` one-liner). Point it only at a disposable test
database.

It runs the repository/query/derivation/transaction suite directly against
that database - fresh-install/replay/upgrade/drift/rollback migration
checks, the active-record derivations, and `withTransactionRepos`.

Two standalone Python checks complement it:

```sh
python3 -m unittest discover -s test -p legacy_metadata_guard_test.py
PG_TEST_HOST=... PG_TEST_PORT=... PG_TEST_USER=... PG_TEST_PASSWORD=... PG_TEST_DB=... \
  python3 test/runtime_integration_test.py
```

`legacy_metadata_guard_test.py` is a static source check (no database, no
build needed) confirming `DB.Migration`'s `nebula_meta` detection stays a
fail-closed guard, not a fallback - see "Explicit SQL migrations" above and
MIGRATION.md. `runtime_integration_test.py` runs the already-built
`db-test` executable under an external 180s deadline, using the same
`PG_TEST_*` environment as above.
