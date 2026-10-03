# Flux DB 0.3: complete breaking rename

Nebula is now **Flux DB**. This is an implementation move, not a compatibility
package or namespace facade. The subsequent coordinated package rename calls
the transport `postgres`; its `Idris2_pg` module remains unchanged. See
[the package migration](https://github.com/odunboye/flux/blob/main/design/PACKAGE_MIGRATION.md)
in the Flux repo.

**This package was later moved out of Flux entirely and renamed again** -
see this repo's own README. The table below is the historical record of the
rename it documents (Nebula -> Flux DB); current module names are `DB.*`,
not `Flux.DB.*` (`Flux.DB.PG`/`Flux.DB.Pool` are a separate package,
`flux-db-flux`, that stayed in the Flux repo).

| Before | Now |
| --- | --- |
| `nebula`, `nebula.ipkg` | `flux-db`, `flux-db.ipkg` |
| `nebula-flux`, `nebula-flux.ipkg` | `flux-db-flux`, `flux-db-flux.ipkg` |
| `nebula-test` | `flux-db-test` |
| `Nebula.PG`, `Nebula.Pool` | `Flux.DB.PG`, `Flux.DB.Pool` |
| `Data.PGMigration` | `Flux.DB.Migration` |
| `Data.PGRepository`, `Data.PGCrud` | `Flux.DB.Repository`, `Flux.DB.Crud` |
| `Data.PGField`, `Data.PGRow`, `Data.PGTable` | `Flux.DB.Field`, `Flux.DB.Row`, `Flux.DB.Table` |
| `Data.PGColumnType`, `Data.PGQuery` | `Flux.DB.ColumnType`, `Flux.DB.Query` |
| `Derive.PGActiveRecord` | `Flux.DB.Derive.ActiveRecord` |
| `ObjectFromJSON` module | `Flux.DB.ObjectFromJSON` module |

Update dependencies, imports, qualified references and file paths; rebuild all
applications. Unbranded types/functions such as `PGRepository`, `Table`, and the
`ObjectFromJSON` deriver keep their names. Driver-owned `Data.PGTypes`,
`Data.PGValue`, `Data.PGPool`, and `Idris2_pg` are not moved.

The directories were `packages/db` and `packages/db-flux` in the Flux repo at
the time of this rename (`packages/db` later moved out to this repo). CLI templates,
examples, active documentation, landing-page branding and browser dependency
boundaries use the new names. Existing handwritten applications need the same
source/dependency changes; regenerating RPC files is not sufficient.

## Existing databases: explicit metadata cutover required

New installations use **`flux_db_meta.migrations`**. If `nebula_meta` exists,
the new runner fails closed before creating metadata or applying migrations,
even if both schema names exist. It does not translate or read old history as
a fallback. The legacy-name detection is a data-safety guard, not an alias.

1. Back up the database and verify the complete checked-in migration history.
2. Stop all old and new migration runners/application processes. Do not deploy
   mixed versions: an old binary can recreate its old metadata schema.
3. Confirm `nebula_meta` is the expected migration schema and `flux_db_meta`
   does not exist. If both exist, stop and investigate/reconcile the histories;
   do not blindly drop either schema, merge rows, or replay migrations.
4. As the schema owner, perform the reviewed maintenance operation:

```sql
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';
SELECT pg_advisory_xact_lock(723946218534101);
ALTER SCHEMA nebula_meta RENAME TO flux_db_meta;
COMMIT;
```

5. Deploy only rebuilt Flux DB applications. Run migration verification again;
   already-applied entries must be a no-op. Only genuinely pending versions
   should execute.

The schema rename preserves table identity, migration versions, names,
checksums and timestamps. **Do not edit frozen migration SQL or history rows**
to accomplish this cutover. Application tables and JSON RPC schemas are not
renamed. The advisory lock key is deliberately unchanged to retain exclusion
between old and new runners during maintenance.

## Migration execution correction

Testing the cutover exposed an existing zero-parameter SQL-batch hazard:
`execCommand` can use the simple protocol and report multiple results only
after execution. A batch containing `COMMIT` could therefore escape rollback.
Migration commands now use the additive `Idris2_pg.execCommandPrepared` API,
which always uses Parse/Bind/Execute. PostgreSQL rejects multiple statements
before executing any of them. Quoted semicolons and a single trailing semicolon
remain valid, and checksums are unchanged. Other `execCommand` callers retain
their existing behavior; this is not a general SQL-sandbox claim.

## Preserved history and scope

Original subtree ancestry, source-import provenance and saved historical reports
retain their old names. Original sibling repositories and unrelated files are
untouched. There are no old package/module aliases in the current workspace.

This rename does not add another database backend, authentication, authorization,
or authenticated PostgreSQL TLS. Flux DB remains a PostgreSQL-backed preview.
