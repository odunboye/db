||| Active-record/query-builder smoke test against a real Postgres
||| server. Connection details come from environment variables so this
||| isn't hardcoded to one local setup - see flux-postgres's own README for
||| how to point it at a disposable Postgres (this suite uses the same
||| `PG_TEST_HOST`/`PG_TEST_PORT`/`PG_TEST_USER`/`PG_TEST_PASSWORD`/
||| `PG_TEST_DB` env vars, defaulting the same way).
|||
||| This is the active-record/query-builder half of what used to be
||| flux-postgres's own test suite before `FromRow`/`ToRow`/`Table`/
||| `DB.Crud`/`DB.Query`/`DB.Derive.ActiveRecord` moved here -
||| flux-postgres's own suite covers the primitive wire-protocol client only
||| (raw `queryRows`/`execCommand`, transactions, LISTEN/NOTIFY, COPY,
||| binary format, TLS, timeouts).
module Main

import Data.IORef
import Data.List
import Data.Maybe
import Data.String
import System
import Idris2_pg
import Data.PGTypes
import Data.PGValue
import DB.Field
import DB.Row
import DB.Table
import DB.Derive.ActiveRecord
import DB.Crud
import DB.Repository as Repo
import Derive.Show
import Derive.Eq

%language ElabReflection

||| Prints `line` (same as a bare `putStrLn`), and - if it's a failure
||| line (starts with `"FAIL"`, this suite's own consistent convention
||| throughout) - also records it, so the suite can exit non-zero at the
||| end instead of a `FAIL` line silently coexisting with a successful
||| process exit (the same accumulate-then-`exitFailure` pattern
||| `todo-api`'s own test suite already uses).
report : IORef Nat -> String -> IO ()
report failCount line = do
  putStrLn line
  when (isPrefixOf "FAIL" line) (modifyIORef failCount (+1))

--------------------------------------------------------------------------------
-- Active-record layer (FromRow/ToRow/Table/Insertable + DB.Crud)
--------------------------------------------------------------------------------

record Widget where
  constructor MkWidget
  id    : Integer
  label : String
  qty   : Maybe Int

%runElab derive "Widget" [FromRow, ToRow, Table]

-- `deriveInsertable` auto-generates `NewWidget`/`MkNewWidget` (every
-- field of `Widget` except `id`), its `ToRow` instance, and the
-- `Insertable NewWidget Widget` link - no hand-written companion record
-- needed. `testActiveRecord` below uses `MkNewWidget`/`insert` exactly
-- as if this had been declared by hand.
%runElab deriveInsertable Nothing "Widget"

-- `deriveSubset` is the general, INCLUDE-list version underneath
-- `deriveInsertable`'s pk-exclusion - proven here against a different
-- derive family entirely (elab-util's own Show/Eq, not ToRow/FromRow),
-- to check it really does work with any `derive`-style item, not just
-- this module's own.
%runElab deriveSubset ["label"] "WidgetLabel" [Show, Eq] "Widget"

-- `deriveColumns` auto-generates `WidgetColumns`/`MkWidgetColumns`/
-- `widgetColumns` (fields `id`/`label`/`qty`, each `Column Widget _`) -
-- the typed column references `DB.Query`'s `Condition`/`Query`
-- builder (`testQueryBuilder` below) runs on.
%runElab deriveColumns "Widget"

-- `columnDefaults` - `customTable`'s own take on Drift's `withDefault()`
-- (a real DB-level DEFAULT, not this layer's equivalent of Drift's
-- `clientDefault()`, which `deriveInsertable`'s NewWidget/NewTodo-style
-- companion records already give you for free at the call site).
GadgetTable : List Name -> ParamTypeInfo -> Res (List TopLevel)
GadgetTable = customTable Export Nothing Nothing [("active", "true")]

record Gadget where
  constructor MkGadget
  id     : Integer
  active : Bool

-- FromRow/ToRow/Insertable, on top of the createTableSql-shape fixture
-- Gadget already was - needed so testTransaction (below) can build a
-- real Repository Integer Gadget NewGadget, exercising
-- withTransactionRepos against TWO distinct tables in one transaction,
-- not just Widget again.
%runElab derive "Gadget" [FromRow, ToRow, GadgetTable]
%runElab deriveInsertable Nothing "Gadget"

-- A STRING-keyed fixture (a slug, not a SERIAL/BIGSERIAL id) -
-- Widget/Gadget above are both Integer-keyed, so on their own they'd
-- never actually exercise `DB.Repository.Repository`'s `pk` type
-- param as anything other than `Integer` - this is the fixture that
-- proves `Repository String Category NewCategory` genuinely works end to end
-- against real Postgres (`testStringKeyRepository`, below), not just
-- that `pk` typechecks as a free variable.
--
-- Confirmed directly (not assumed): `Table`'s generated `insertSql`
-- (`DB.Derive.ActiveRecord.buildInsertSql`) unconditionally excludes the
-- pk column from the INSERT's own column/placeholder list, on the
-- assumption that Postgres - not the caller - always assigns it
-- (`deriveInsertable`'s own doc comment says so explicitly). A first
-- attempt at this fixture tried a genuinely caller-supplied slug value
-- (`NewCategory` carrying `slug` itself, inserted as `MkNewCategory
-- "idris" "Idris2"`) and failed at RUNTIME, not compile time - a real
-- SQL error ("bind message supplies 2 parameters, but prepared
-- statement ... requires 1"), since `insertSql` still only has one
-- placeholder (for `label`) regardless of what `ins`'s own `ToRow`
-- produces. So this fixture instead has Postgres assign `slug` itself,
-- via a real DB-level DEFAULT (`columnDefaults`, the same mechanism
-- Gadget's `active` column above already exercises) - `md5(random()
-- ::text)` needs no extension (unlike `gen_random_uuid()`, pgcrypto),
-- and is exactly the kind of DB-generated STRING pk this library's
-- insert path actually supports today: a caller-supplied string pk
-- would need `Table`/`Insertable`'s design changed first, out of scope
-- for this test fixture.
CategoryTable : List Name -> ParamTypeInfo -> Res (List TopLevel)
CategoryTable = customTable Export Nothing (Just "slug") [("slug", "substr(md5(random()::text), 1, 12)")]

record Category where
  constructor MkCategory
  slug  : String
  label : String

%runElab derive "Category" [FromRow, ToRow, CategoryTable]
%runElab deriveInsertable (Just "slug") "Category"

-- Connection details come from environment variables so this isn't
-- hardcoded to one local setup; see flux-postgres's own README for how to
-- point it at a disposable Postgres.
testConfig : IO PGConfig
testConfig = do
  host <- fromMaybe "127.0.0.1" <$> getEnv "PG_TEST_HOST"
  port <- fromMaybe 5432 . (>>= parsePositive) <$> getEnv "PG_TEST_PORT"
  user <- fromMaybe "testuser" <$> getEnv "PG_TEST_USER"
  password <- fromMaybe "testpass" <$> getEnv "PG_TEST_PASSWORD"
  database <- fromMaybe "testdb" <$> getEnv "PG_TEST_DB"
  pure (mkPGConfig host port user password database)

testActiveRecord : IORef Nat -> DB -> IO ()
testActiveRecord failCount db = do
  -- deriveSubset doesn't touch the database - a pure check that the
  -- generated WidgetLabel/MkWidgetLabel/Show/Eq/field-accessor all
  -- actually work. The accessor check matters specifically: a plain
  -- `data` declaration (what deriveSubset builds under the hood) does
  -- NOT get Idris2's automatic record-field-accessor sugar the way a
  -- real `record` block does - deriveSubset generates `.label` by hand.
  let wl1 = MkWidgetLabel "Bolt"
      wl2 = MkWidgetLabel "Bolt"
      wl3 = MkWidgetLabel "Nut"
  report failCount (if wl1 == wl2 && wl1 /= wl3 && wl1.label == "Bolt" && isInfixOf "Bolt" (show wl1)
               then "OK deriveSubset generates a working include-list companion type"
               else "FAIL deriveSubset: " ++ show (wl1, wl2, wl3))

  -- `createTableSql` is generated (via DB.ColumnType), not
  -- hand-written - use it directly, rather than a parallel hand-written
  -- CREATE TABLE, so a regression in the generator would actually be
  -- caught here instead of silently untested.
  report failCount (if isInfixOf "BIGSERIAL" (createTableSql {a = Widget})
               && isInfixOf "label TEXT NOT NULL" (createTableSql {a = Widget})
               && isInfixOf "qty INTEGER" (createTableSql {a = Widget})
               && not (isInfixOf "qty INTEGER NOT NULL" (createTableSql {a = Widget}))
               then "OK createTableSql generates the expected DDL shape"
               else "FAIL createTableSql: " ++ createTableSql {a = Widget})

  report failCount (if isInfixOf "active BOOLEAN NOT NULL DEFAULT true" (createTableSql {a = Gadget})
               then "OK customTable's columnDefaults generates a real DB-level DEFAULT"
               else "FAIL columnDefaults: " ++ createTableSql {a = Gadget})

  _ <- execCommand db "DROP TABLE IF EXISTS widget" []
  Right _ <- execCommand db (createTableSql {a = Widget}) []
    | Left err => report failCount ("FAIL create widget table: " ++ displayError err)

  Right w1 <- insert {a = Widget} db (MkNewWidget "Bolt" (Just 10))
    | Left err => report failCount ("FAIL insert w1: " ++ displayError err)
  report failCount (if w1.label == "Bolt" && w1.qty == Just 10
               then "OK insert via the derived active-record layer"
               else "FAIL insert w1 values: " ++ show (w1.label, w1.qty))

  -- NULL round-trip: qty = Nothing, both on the way in and back out.
  Right w2 <- insert {a = Widget} db (MkNewWidget "Nut" Nothing)
    | Left err => report failCount ("FAIL insert w2 (NULL qty): " ++ displayError err)
  report failCount (if w2.label == "Nut" && w2.qty == Nothing
               then "OK insert with a NULL field round-trips as Nothing"
               else "FAIL insert w2 values: " ++ show (w2.label, w2.qty))

  Right (Just found) <- findById {a = Widget} db w1.id
    | Right Nothing => report failCount "FAIL findById: expected a row, found none"
    | Left err       => report failCount ("FAIL findById: " ++ displayError err)
  report failCount (if found.label == "Bolt" && found.qty == Just 10
               then "OK findById"
               else "FAIL findById values: " ++ show (found.label, found.qty))

  Right missing <- findById {a = Widget} db (the Integer 999999)
    | Left err => report failCount ("FAIL findById (missing id): " ++ displayError err)
  report failCount (case missing of
    Nothing => "OK findById returns Nothing (not an error) for a missing id"
    Just _  => "FAIL findById (missing id): unexpectedly found a row")

  Right (Just updated) <- update {a = Widget} db (MkWidget w1.id "Bolt (updated)" (Just 99))
    | Right Nothing => report failCount "FAIL update: expected a row, found none"
    | Left err       => report failCount ("FAIL update: " ++ displayError err)
  report failCount (if updated.label == "Bolt (updated)" && updated.qty == Just 99
               then "OK update (whole-record replace)"
               else "FAIL update values: " ++ show (updated.label, updated.qty))

  Right deleted <- deleteById {a = Widget} db w1.id
    | Left err => report failCount ("FAIL deleteById: " ++ displayError err)
  report failCount (if deleted then "OK deleteById reports True for an existing id" else "FAIL deleteById: expected True")

  Right deletedAgain <- deleteById {a = Widget} db w1.id
    | Left err => report failCount ("FAIL deleteById (already gone): " ++ displayError err)
  report failCount (if not deletedAgain
               then "OK deleteById reports False for an already-deleted id"
               else "FAIL deleteById (already gone): expected False")

  _ <- execCommand db "DROP TABLE widget" []
  pure ()

testQueryBuilder : IORef Nat -> DB -> IO ()
testQueryBuilder failCount db = do
  -- Pure check (no DB) that compileQuery/compileCondition generate the
  -- expected SQL shape - same style as testActiveRecord's own
  -- createTableSql shape check.
  let q          := selectAll |> where_ (widgetColumns.label ==. "Bolt") |> orderByAsc widgetColumns.id |> limit 5
      (sql, ps)  := compileQuery {a = Widget} q
  report failCount (if isInfixOf "WHERE label = $1" sql
               && isInfixOf "ORDER BY id" sql
               && isInfixOf "LIMIT $2" sql
               && ps == [Just "Bolt", Just "5"]
               then "OK compileQuery generates the expected SQL shape"
               else "FAIL compileQuery: " ++ sql ++ " / " ++ show ps)

  _ <- execCommand db "DROP TABLE IF EXISTS widget" []
  Right _ <- execCommand db (createTableSql {a = Widget}) []
    | Left err => report failCount ("FAIL testQueryBuilder create widget table: " ++ displayError err)

  Right _ <- insert {a = Widget} db (MkNewWidget "Bolt" (Just 1))
    | Left err => report failCount ("FAIL testQueryBuilder insert 1: " ++ displayError err)
  Right _ <- insert {a = Widget} db (MkNewWidget "Nut" (Just 2))
    | Left err => report failCount ("FAIL testQueryBuilder insert 2: " ++ displayError err)
  Right _ <- insert {a = Widget} db (MkNewWidget "Bolt" Nothing)
    | Left err => report failCount ("FAIL testQueryBuilder insert 3: " ++ displayError err)
  Right _ <- insert {a = Widget} db (MkNewWidget "Washer" (Just 3))
    | Left err => report failCount ("FAIL testQueryBuilder insert 4: " ++ displayError err)

  Right allRows <- selectQuery {a = Widget} db selectAll
    | Left err => report failCount ("FAIL selectAll: " ++ displayError err)
  report failCount (if length allRows == 4
               then "OK selectAll (no condition) returns everything"
               else "FAIL selectAll count: " ++ show (length allRows))

  Right bolts <- selectQuery {a = Widget} db (where_ (widgetColumns.label ==. "Bolt") selectAll)
    | Left err => report failCount ("FAIL where_ (==.): " ++ displayError err)
  report failCount (if length bolts == 2 && all (\w => w.label == "Bolt") bolts
               then "OK where_ (==.) filters correctly"
               else "FAIL where_ (==.) results: " ++ show (map (\w => (w.label, w.qty)) bolts))

  Right boltNoQty <- selectQuery {a = Widget} db
    (where_ (widgetColumns.label ==. "Bolt" &&. isNull widgetColumns.qty) selectAll)
    | Left err => report failCount ("FAIL compound &&./isNull: " ++ displayError err)
  report failCount (case boltNoQty of
    [w] => if w.label == "Bolt" && w.qty == Nothing
              then "OK compound &&. with isNull filters correctly"
              else "FAIL compound &&./isNull value: " ++ show (w.label, w.qty)
    _   => "FAIL compound &&./isNull count: " ++ show (length boltNoQty))

  Right withQty <- selectQuery {a = Widget} db (where_ (isNotNull widgetColumns.qty) selectAll)
    | Left err => report failCount ("FAIL isNotNull: " ++ displayError err)
  report failCount (if length withQty == 3
               then "OK isNotNull filters correctly"
               else "FAIL isNotNull count: " ++ show (length withQty))

  Right several <- selectQuery {a = Widget} db
    (where_ (widgetColumns.label ==. "Nut" ||. widgetColumns.label ==. "Washer") selectAll)
    | Left err => report failCount ("FAIL (||.): " ++ displayError err)
  report failCount (if length several == 2
               then "OK where_ (||.) combines conditions correctly"
               else "FAIL (||.) count: " ++ show (length several))

  Right ascByLabel <- selectQuery {a = Widget} db (selectAll |> orderByAsc widgetColumns.label)
    | Left err => report failCount ("FAIL orderByAsc: " ++ displayError err)
  let labels := map (\w => w.label) ascByLabel
  report failCount (if labels == sort labels
               then "OK orderByAsc sorts ascending"
               else "FAIL orderByAsc order: " ++ show labels)

  Right descById <- selectQuery {a = Widget} db (selectAll |> orderByDesc widgetColumns.id)
    | Left err => report failCount ("FAIL orderByDesc: " ++ displayError err)
  let descIds := map (\w => w.id) descById
  report failCount (if descIds == reverse (sort descIds)
               then "OK orderByDesc sorts descending"
               else "FAIL orderByDesc order: " ++ show descIds)

  Right page1 <- selectQuery {a = Widget} db (selectAll |> orderByAsc widgetColumns.id |> limit 2)
    | Left err => report failCount ("FAIL limit: " ++ displayError err)
  Right page2 <- selectQuery {a = Widget} db (selectAll |> orderByAsc widgetColumns.id |> limit 2 |> offset 2)
    | Left err => report failCount ("FAIL limit/offset: " ++ displayError err)
  report failCount (if length page1 == 2 && length page2 == 2
               && map (\w => w.id) page1 /= map (\w => w.id) page2
               then "OK limit/offset paginate correctly"
               else "FAIL limit/offset: " ++ show (map (\w => w.id) page1, map (\w => w.id) page2))

  -- White-box check mirroring flux-postgres's own testPreparedCache: two
  -- selectQuery calls with the same WHERE/ORDER BY shape but different
  -- limit VALUES should hit the SAME stmtCache entry (LIMIT is a $N
  -- placeholder, not a literal spliced into the SQL text) - the direct
  -- regression test for that design choice. Uses a condition/ordering
  -- shape not exercised anywhere else in this function - the
  -- "limit/offset paginate correctly" check above happens to compile to
  -- the exact same SQL text as a same-shaped, differently-valued limit
  -- query (limit VALUES never appear in the text), so reusing that
  -- shape here would already find it cached before this check even runs.
  let pagedQuery := selectAll |> where_ (widgetColumns.label /=. "Never Used Label XYZ") |> orderByDesc widgetColumns.label
  cacheBefore <- readIORef (stmtCache db)
  _ <- selectQuery {a = Widget} db (pagedQuery |> limit 1)
  cacheAfterFirst <- readIORef (stmtCache db)
  _ <- selectQuery {a = Widget} db (pagedQuery |> limit 2)
  cacheAfterSecond <- readIORef (stmtCache db)
  report failCount (if length cacheAfterFirst == length cacheBefore + 1 && length cacheAfterSecond == length cacheAfterFirst
               then "OK selectQuery's LIMIT-as-placeholder design reuses one stmtCache entry across different limit values"
               else "FAIL stmtCache growth: before=" ++ show (length cacheBefore) ++
                    " afterFirst=" ++ show (length cacheAfterFirst) ++
                    " afterSecond=" ++ show (length cacheAfterSecond))

  _ <- execCommand db "DROP TABLE widget" []
  pure ()

-- Exercises `DB.Repository.pgRepository` - the generic CRUD+query
-- repository - against the same `widget` table `testActiveRecord`/
-- `testQueryBuilder` already use, confirming its five fields really do
-- delegate correctly to `DB.Crud`/`DB.Query` (not just
-- typecheck). Uses `Repo.Repository`/`Repo.pgRepository` (the qualified
-- import) for the type/constructor; dot-notation on the resulting value
-- (`repo.insert`/`repo.findById`/etc) needs no qualification - it
-- resolves against the value's own type regardless of how the defining
-- module was imported.
testRepository : IORef Nat -> DB -> IO ()
testRepository failCount db = do
  _ <- execCommand db "DROP TABLE IF EXISTS widget" []
  Right _ <- execCommand db (createTableSql {a = Widget}) []
    | Left err => report failCount ("FAIL testRepository create widget table: " ++ displayError err)

  let repo : Repo.Repository Integer Widget NewWidget
      repo = Repo.pgRepository db

  Right w1 <- repo.insert (MkNewWidget "Bolt" (Just 10))
    | Left err => report failCount ("FAIL repo.insert: " ++ displayError err)
  report failCount (if w1.label == "Bolt" && w1.qty == Just 10
               then "OK repo.insert"
               else "FAIL repo.insert values: " ++ show (w1.label, w1.qty))

  Right (Just found) <- repo.findById w1.id
    | Right Nothing => report failCount "FAIL repo.findById: expected a row, found none"
    | Left err       => report failCount ("FAIL repo.findById: " ++ displayError err)
  report failCount (if found.label == "Bolt" && found.qty == Just 10
               then "OK repo.findById"
               else "FAIL repo.findById values: " ++ show (found.label, found.qty))

  Right (Just updated) <- repo.update (MkWidget w1.id "Bolt (updated)" (Just 99))
    | Right Nothing => report failCount "FAIL repo.update: expected a row, found none"
    | Left err       => report failCount ("FAIL repo.update: " ++ displayError err)
  report failCount (if updated.label == "Bolt (updated)" && updated.qty == Just 99
               then "OK repo.update"
               else "FAIL repo.update values: " ++ show (updated.label, updated.qty))

  _ <- repo.insert (MkNewWidget "Nut" (Just 2))
  Right all_ <- repo.query selectAll
    | Left err => report failCount ("FAIL repo.query selectAll: " ++ displayError err)
  report failCount (if length all_ == 2
               then "OK repo.query selectAll returns everything"
               else "FAIL repo.query selectAll count: " ++ show (length all_))

  Right filtered <- repo.query (where_ (widgetColumns.label ==. "Nut") selectAll)
    | Left err => report failCount ("FAIL repo.query where_: " ++ displayError err)
  report failCount (case filtered of
    [w] => if w.label == "Nut" then "OK repo.query with a condition filters correctly"
                                else "FAIL repo.query where_ value: " ++ w.label
    _   => "FAIL repo.query where_ count: " ++ show (length filtered))

  Right deleted <- repo.deleteById w1.id
    | Left err => report failCount ("FAIL repo.deleteById: " ++ displayError err)
  report failCount (if deleted then "OK repo.deleteById reports True for an existing id"
                        else "FAIL repo.deleteById: expected True")

  Right deletedAgain <- repo.deleteById w1.id
    | Left err => report failCount ("FAIL repo.deleteById (already gone): " ++ displayError err)
  report failCount (if not deletedAgain
               then "OK repo.deleteById reports False for an already-deleted id"
               else "FAIL repo.deleteById (already gone): expected False")

  _ <- execCommand db "DROP TABLE widget" []
  pure ()

-- Exercises `DB.Repository.withTransactionRepos` against TWO
-- distinct tables (Widget/Gadget) on real Postgres - both the commit
-- path (a genuine cross-table atomic write) and the rollback path (an
-- error inside the callback, AFTER a successful write, must undo
-- everything, not partially commit).
--
-- Verification reads through a SEPARATE connection (`verifyDb`), not
-- `db` (the one the transaction itself ran on) - reading through the
-- same connection wouldn't distinguish "the data is genuinely committed
-- to the database" from "this session still sees its own writes for
-- some other reason" (read-your-own-writes visibility isn't what's
-- under test here; cross-connection durability is). Also asserts
-- `txStatus db` is back to `Idle` after each path, not left mid-
-- transaction or in a failed-transaction state.
covering
testTransaction : IORef Nat -> DB -> IO ()
testTransaction failCount db = do
  _ <- execCommand db "DROP TABLE IF EXISTS widget" []
  Right _ <- execCommand db (createTableSql {a = Widget}) []
    | Left err => report failCount ("FAIL testTransaction create widget table: " ++ displayError err)
  _ <- execCommand db "DROP TABLE IF EXISTS gadget" []
  Right _ <- execCommand db (createTableSql {a = Gadget}) []
    | Left err => report failCount ("FAIL testTransaction create gadget table: " ++ displayError err)

  cfg <- testConfig
  Right verifyDb <- connectDB cfg
    | Left err => report failCount ("FAIL testTransaction connect verify db: " ++ displayError err)

  -- Commit path: withTransactionRepos hands the callback repositories
  -- for two DIFFERENT tables, both built from the same transactional
  -- connection - a real cross-table atomic write, not just proving the
  -- combinator typechecks.
  let mkRepos : DB -> (Repo.Repository Integer Widget NewWidget, Repo.Repository Integer Gadget NewGadget)
      mkRepos txDb = (Repo.pgRepository txDb, Repo.pgRepository txDb)

      insertBoth : (Repo.Repository Integer Widget NewWidget, Repo.Repository Integer Gadget NewGadget)
                -> IO (Either PGError (Widget, Gadget))
      insertBoth (widgetRepo, gadgetRepo) = do
        Right w <- widgetRepo.insert (MkNewWidget "Committed" (Just 1))
          | Left err => pure (Left err)
        Right g <- gadgetRepo.insert (MkNewGadget True)
          | Left err => pure (Left err)
        pure (Right (w, g))

  commitResult <- Repo.withTransactionRepos db mkRepos insertBoth
  Right (w, g) <- pure commitResult
    | Left err => report failCount ("FAIL withTransactionRepos commit path: " ++ displayError err)

  let verifyWidgets : Repo.Repository Integer Widget NewWidget
      verifyWidgets = Repo.pgRepository verifyDb
      verifyGadgets : Repo.Repository Integer Gadget NewGadget
      verifyGadgets = Repo.pgRepository verifyDb

  Right foundWidget <- verifyWidgets.findById w.id
    | Left err => report failCount ("FAIL testTransaction verify widget committed: " ++ displayError err)
  Right foundGadget <- verifyGadgets.findById g.id
    | Left err => report failCount ("FAIL testTransaction verify gadget committed: " ++ displayError err)
  report failCount (case (foundWidget, foundGadget) of
    (Just _, Just _) => "OK withTransactionRepos commit path: both rows are visible after commit (verified via a separate connection)"
    _                => "FAIL withTransactionRepos commit path: expected both rows to exist")

  statusAfterCommit <- txStatus db
  report failCount (case statusAfterCommit of
    Just Idle => "OK withTransactionRepos commit path: txStatus returns to Idle"
    _         => "FAIL withTransactionRepos commit path: expected Idle, got " ++ show statusAfterCommit)

  -- Rollback path: the callback inserts a widget - MUST succeed first,
  -- so this genuinely exercises "a later failure undoes an earlier
  -- successful write", not just "an error propagates" - then
  -- deliberately fails with a specific, recognizable error. Checking
  -- for exactly that error (not just any `Left`) matters: accepting any
  -- `Left` here would also silently pass if the INSERT itself failed
  -- for an unrelated reason, never actually testing what a rollback
  -- undoes at all.
  let mkWidgetRepo : DB -> Repo.Repository Integer Widget NewWidget
      mkWidgetRepo = Repo.pgRepository

      insertThenFail : Repo.Repository Integer Widget NewWidget -> IO (Either PGError ())
      insertThenFail widgetRepo = do
        Right _ <- widgetRepo.insert (MkNewWidget "ShouldRollback" Nothing)
          | Left err => pure (Left err)
        pure (Left (ProtocolError "deliberate failure to test rollback"))

  rollbackResult <- Repo.withTransactionRepos db mkWidgetRepo insertThenFail
  report failCount (case rollbackResult of
    Left (ProtocolError "deliberate failure to test rollback") =>
      "OK withTransactionRepos rollback path: the deliberate error after a successful insert propagates out"
    Left otherErr =>
      "FAIL withTransactionRepos rollback path: expected the deliberate error, got a different one instead (insert itself may have failed): " ++ displayError otherErr
    Right _ => "FAIL withTransactionRepos rollback path: expected Left, got Right")

  Right allWidgets <- verifyWidgets.query selectAll
    | Left err => report failCount ("FAIL testTransaction verify rollback: " ++ displayError err)
  report failCount (if not (any (\w' => w'.label == "ShouldRollback") allWidgets)
               then "OK withTransactionRepos rollback path: the row was NOT persisted (verified via a separate connection)"
               else "FAIL withTransactionRepos rollback path: the row WAS persisted despite the error")

  statusAfterRollback <- txStatus db
  report failCount (case statusAfterRollback of
    Just Idle => "OK withTransactionRepos rollback path: txStatus returns to Idle"
    _         => "FAIL withTransactionRepos rollback path: expected Idle, got " ++ show statusAfterRollback)

  closeDB verifyDb
  _ <- execCommand db "DROP TABLE widget" []
  _ <- execCommand db "DROP TABLE gadget" []
  pure ()

-- Exercises `pgRepository`/`Repository` with `pk = String` (a slug, not
-- an `Integer` id) against real Postgres - `Widget`/`Gadget` above are
-- both `Integer`-keyed, so nothing else in this suite actually proves
-- the generic `pk` type param works for anything other than `Integer`.
covering
testStringKeyRepository : IORef Nat -> DB -> IO ()
testStringKeyRepository failCount db = do
  _ <- execCommand db "DROP TABLE IF EXISTS category" []
  Right _ <- execCommand db (createTableSql {a = Category}) []
    | Left err => report failCount ("FAIL testStringKeyRepository create tag table: " ++ displayError err)

  let repo : Repo.Repository String Category NewCategory
      repo = Repo.pgRepository db

  -- `slug` is Postgres-assigned (the `md5(random()::text)` DEFAULT
  -- above), same as Widget/Gadget's own `id` - so `NewCategory` only
  -- carries `label`, and the actually-generated slug is read back from
  -- the inserted row, not asserted against a literal.
  Right t1 <- repo.insert (MkNewCategory "Idris2")
    | Left err => report failCount ("FAIL testStringKeyRepository repo.insert: " ++ displayError err)
  report failCount (if t1.label == "Idris2" && t1.slug /= ""
               then "OK repo.insert with a String key"
               else "FAIL repo.insert values: " ++ show (t1.slug, t1.label))

  Right (Just found) <- repo.findById t1.slug
    | Right Nothing => report failCount "FAIL repo.findById (String key): expected a row, found none"
    | Left err       => report failCount ("FAIL repo.findById (String key): " ++ displayError err)
  report failCount (if found.label == "Idris2"
               then "OK repo.findById with a String key"
               else "FAIL repo.findById (String key) value: " ++ found.label)

  Right missing <- repo.findById "does-not-exist"
    | Left err => report failCount ("FAIL repo.findById (String key, missing): " ++ displayError err)
  report failCount (case missing of
    Nothing => "OK repo.findById with a String key returns Nothing for a missing slug"
    Just _  => "FAIL repo.findById (String key, missing): unexpectedly found a row")

  Right deleted <- repo.deleteById t1.slug
    | Left err => report failCount ("FAIL repo.deleteById (String key): " ++ displayError err)
  report failCount (if deleted then "OK repo.deleteById reports True for an existing String key"
                                else "FAIL repo.deleteById (String key): expected True")

  Right deletedAgain <- repo.deleteById t1.slug
    | Left err => report failCount ("FAIL repo.deleteById (String key, already gone): " ++ displayError err)
  report failCount (if not deletedAgain
               then "OK repo.deleteById reports False for an already-deleted String key"
               else "FAIL repo.deleteById (String key, already gone): expected False")

  _ <- execCommand db "DROP TABLE category" []
  pure ()

main : IO ()
main = do
  failCount <- newIORef {a = Nat} 0
  cfg <- testConfig
  Right db <- connectDB cfg
    | Left err => do
        putStrLn ("FAIL connect: " ++ displayError err)
        exitFailure
  putStrLn "OK connected"
  testActiveRecord failCount db
  testQueryBuilder failCount db
  testRepository failCount db
  testTransaction failCount db
  testStringKeyRepository failCount db
  closeDB db
  n <- readIORef failCount
  case n of
    0 => putStrLn "OK done"
    _ => do
      putStrLn "FAIL \{show n} check(s) failed"
      exitFailure
