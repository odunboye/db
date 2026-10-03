||| A hand-written, typed query builder (`Column`/`Condition`/`Query`),
||| inspired by Drift (Dart/SQLite)'s
||| `select(table)..where(...)..orderBy(...)..limit(...)`.
|||
||| Deliberately NOT elaborator-reflection-generated: confirmed directly
||| (not assumed) that neither Idris2 0.8.0's base `Language.Reflection.
||| TTImp` nor `elab-util` has any mechanism to declare new infix
||| operators (fixity + name) as a source-level `Decl` - so `==.`/`&&.`/
||| etc below are ordinary, hand-written top-level definitions. Only the
||| per-table `Column` *values* (`DB.Derive.ActiveRecord.deriveColumns`)
||| are actually code-generated.
|||
||| Scope: `SELECT` only - `WHERE`/`ORDER BY`/`LIMIT`/`OFFSET`. No JOINs,
||| no raw-SQL escape hatch, no `LIKE`, no migrations. `DB.Crud`'s
||| `insert`/`update`/`deleteById` (by primary key) are untouched by
||| this module; a bulk `updateWhere`/`deleteWhere` (by an arbitrary
||| condition, not just pk) would reuse `compileCondition` cheaply as a
||| later addition, not built here.
module DB.Query

import Data.List
import DB.Field
import DB.Row
import DB.Table
import Data.PGTypes
import Data.PGValue
import Idris2_pg

%default total

public export
record Column (a : Type) (t : Type) where
  constructor MkColumn
  columnName : String

||| The "existential typeclass dictionary" GADT idiom: `ToField t` is
||| packed into each comparison constructor at construction time and
||| recovered at pattern-match time (in `compileCondition`) - confirmed
||| directly this compiles and dispatches correctly in this Idris2
||| version before committing to the design (see this feature's plan).
public export
data Condition : Type -> Type where
  CEq        : ToField t => Column a t -> t -> Condition a
  CNotEq     : ToField t => Column a t -> t -> Condition a
  CLt        : ToField t => Column a t -> t -> Condition a
  CGt        : ToField t => Column a t -> t -> Condition a
  CLte       : ToField t => Column a t -> t -> Condition a
  CGte       : ToField t => Column a t -> t -> Condition a
  CIsNull    : Column a (Maybe t) -> Condition a
  CIsNotNull : Column a (Maybe t) -> Condition a
  CAnd       : Condition a -> Condition a -> Condition a
  COr        : Condition a -> Condition a -> Condition a
  CNot       : Condition a -> Condition a

export infix 4 ==., /=., <., >., <=., >=.
export infixr 3 &&.
export infixr 2 ||.

public export
(==.) : ToField t => Column a t -> t -> Condition a
(==.) = CEq

public export
(/=.) : ToField t => Column a t -> t -> Condition a
(/=.) = CNotEq

public export
(<.) : ToField t => Column a t -> t -> Condition a
(<.) = CLt

public export
(>.) : ToField t => Column a t -> t -> Condition a
(>.) = CGt

public export
(<=.) : ToField t => Column a t -> t -> Condition a
(<=.) = CLte

public export
(>=.) : ToField t => Column a t -> t -> Condition a
(>=.) = CGte

public export
(&&.) : Condition a -> Condition a -> Condition a
(&&.) = CAnd

public export
(||.) : Condition a -> Condition a -> Condition a
(||.) = COr

public export
isNull : Column a (Maybe t) -> Condition a
isNull = CIsNull

public export
isNotNull : Column a (Maybe t) -> Condition a
isNotNull = CIsNotNull

||| Named `not_`, not `not` - avoids colliding with `Prelude.not`.
public export
not_ : Condition a -> Condition a
not_ = CNot

public export
data SortDir = Asc | Desc

public export
record Query a where
  constructor MkQuery
  whereCond : Maybe (Condition a)
  orderCols : List (String, SortDir)
  limitVal  : Maybe Nat
  offsetVal : Maybe Nat

public export
selectAll : Query a
selectAll = MkQuery Nothing [] Nothing Nothing

||| ANDs with any existing `whereCond` if called more than once - each
||| `where_` narrows the result set further, matching Drift's own
||| repeated `..where(...)` semantics.
public export
where_ : Condition a -> Query a -> Query a
where_ c q = { whereCond := Just (maybe c (\ex => CAnd ex c) q.whereCond) } q

public export
orderByAsc : Column a t -> Query a -> Query a
orderByAsc col q = { orderCols $= (++ [(col.columnName, Asc)]) } q

public export
orderByDesc : Column a t -> Query a -> Query a
orderByDesc col q = { orderCols $= (++ [(col.columnName, Desc)]) } q

public export
limit : Nat -> Query a -> Query a
limit n q = { limitVal := Just n } q

public export
offset : Nat -> Query a -> Query a
offset n q = { offsetVal := Just n } q

placeholder : Nat -> String
placeholder n = "$" ++ show n

binOp : ToField t => String -> Nat -> Column a t -> t -> (String, List (Maybe String), Nat)
binOp op n col val = (col.columnName ++ " " ++ op ++ " " ++ placeholder (n + 1), [toField val], n + 1)

||| Threads `$N` placeholder numbering through a `Condition` tree - a
||| state-threading fold, since numbering has to stay globally
||| sequential across the whole tree, not restart per leaf.
export
compileCondition : (startIdx : Nat) -> Condition a -> (String, List (Maybe String), Nat)
compileCondition n (CEq col val)    = binOp "="  n col val
compileCondition n (CNotEq col val) = binOp "<>" n col val
compileCondition n (CLt col val)    = binOp "<"  n col val
compileCondition n (CGt col val)    = binOp ">"  n col val
compileCondition n (CLte col val)   = binOp "<=" n col val
compileCondition n (CGte col val)   = binOp ">=" n col val
compileCondition n (CIsNull col)    = (col.columnName ++ " IS NULL", [], n)
compileCondition n (CIsNotNull col) = (col.columnName ++ " IS NOT NULL", [], n)
compileCondition n (CAnd l r) =
  let (sl, pl, n1) := compileCondition n l
      (sr, pr, n2) := compileCondition n1 r
   in ("(" ++ sl ++ " AND " ++ sr ++ ")", pl ++ pr, n2)
compileCondition n (COr l r) =
  let (sl, pl, n1) := compileCondition n l
      (sr, pr, n2) := compileCondition n1 r
   in ("(" ++ sl ++ " OR " ++ sr ++ ")", pl ++ pr, n2)
compileCondition n (CNot c) =
  let (s, p, n1) := compileCondition n c
   in ("NOT (" ++ s ++ ")", p, n1)

joinCommas : List String -> String
joinCommas = concat . intersperse ", "

renderSort : (String, SortDir) -> String
renderSort (col, Asc)  = col
renderSort (col, Desc) = col ++ " DESC"

||| "SELECT <cols> FROM <table> [WHERE ...] [ORDER BY ...] [LIMIT $N]
||| [OFFSET $N]". `LIMIT`/`OFFSET` are placeholders, not literals
||| spliced into the SQL text - keeps the SQL text (and thus `DB`'s
||| exact-text-keyed prepared-statement cache) stable across calls that
||| only vary the limit/offset for an otherwise identical `WHERE`/
||| `ORDER BY` shape (paging through the same filtered query reuses one
||| cache entry instead of minting a new one per page).
export
compileQuery : Table a => Query a -> (String, List (Maybe String))
compileQuery {a} q =
  let (whereSql, whereParams, n1) := case q.whereCond of
        Nothing => ("", [], 0)
        Just c  => let (s, p, n) := compileCondition 0 c in (" WHERE " ++ s, p, n)
      orderSql := case q.orderCols of
        [] => ""
        cs => " ORDER BY " ++ joinCommas (map renderSort cs)
      (limitSql, limitParams, n2) := case q.limitVal of
        Nothing => ("", [], n1)
        Just lv => (" LIMIT " ++ placeholder (n1 + 1), [Just (show lv)], n1 + 1)
      (offsetSql, offsetParams, _) := case q.offsetVal of
        Nothing => ("", [], n2)
        Just ov => (" OFFSET " ++ placeholder (n2 + 1), [Just (show ov)], n2 + 1)
      sql := "SELECT " ++ joinCommas (columns {a}) ++ " FROM " ++ tableName {a}
               ++ whereSql ++ orderSql ++ limitSql ++ offsetSql
   in (sql, whereParams ++ limitParams ++ offsetParams)

||| Runs a `Query a`, decoding every row via `FromRow` - a decode
||| failure becomes `Left (ProtocolError "could not decode a row: ...")`,
||| matching `DB.Crud`'s own existing decode-error convention.
export
selectQuery : (Table a, FromRow a) => DB -> Query a -> IO (Either PGError (List a))
selectQuery {a} db q = do
  let (sql, params) := compileQuery {a} q
  Right rows <- queryRows db sql params
    | Left err => pure (Left err)
  case the (Either String (List a)) (traverse fromRow rows) of
    Right vs  => pure (Right vs)
    Left err  => pure (Left (ProtocolError ("could not decode a row: " ++ err)))
