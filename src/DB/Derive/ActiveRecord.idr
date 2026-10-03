||| Elaborator-reflection derivation of `FromRow`/`ToRow` (declared in
||| `DB.Row`) and `Table` (declared in `DB.Table`): maps a plain,
||| single-constructor record to/from a Postgres `Row`, one field at a
||| time, via `DB.Field`'s `FromField`/`ToField`, plus the static
||| per-type table metadata `DB.Crud`'s generic CRUD helpers run on.
|||
||| All three derivations - and their shared "walk this record's fields"
||| helper - deliberately live in this ONE file, not split across
||| separate modules the way the rest of this codebase usually would
||| (see e.g. `DB.Row`/`DB.Table` staying separate from THIS file
||| for a similar-sounding but different reason). Confirmed empirically,
||| the hard way: `%runElab derive "X" [...]`'s compile-time reduction
||| cannot unfold a THREE-module call chain (consumer -> deriver-module
||| -> a further shared-helper module) - it gets stuck and fails with
||| "Bad elaborator script ... (script is not a data value)", even
||| though the exact same logic reduces fine as a plain TWO-module chain
||| (consumer -> deriver-module, with the helper inlined into that same
||| module). A shared `Derive.PGFields` helper module, imported by both a
||| separate `Derive.PGRow` and `Derive.PGTable`, hit exactly this - so
||| `recordFields` below is the shared helper, kept local (not exported)
||| and duplicated in spirit, not split out, purely to keep every derive
||| call here at a guaranteed two-hop depth regardless of which
||| combination of `[FromRow, ToRow, Table]` a caller derives together.
module DB.Derive.ActiveRecord

import public DB.Field
import public DB.Row
import public DB.Table
import public DB.ColumnType
import public DB.Query
import public Language.Reflection.Util
import Data.List
import Data.Maybe
import Data.String

%language ElabReflection
%default total

||| The shape of a single `%runElab derive`-list item - what `FromRow`/
||| `ToRow`/`Table` below, `elab-util`'s own `Show`/`Eq`, and a
||| `customTable` override (`customTable Export (Just "todos") Nothing
||| [("done", "false")]`, say) all are. Exported so a caller writing a
||| `customTable`/`customFromRow`/`customToRow` override doesn't have to
||| spell out this exact elab-util shape itself - `TodoTable : DeriveItem`
||| instead of `TodoTable : List Name -> ParamTypeInfo -> Res (List
||| TopLevel)`.
public export
DeriveItem : Type
DeriveItem = List Name -> ParamTypeInfo -> Res (List TopLevel)

--------------------------------------------------------------------------------
--          Shared field-walking helper
--------------------------------------------------------------------------------

record RowField where
  constructor MkRowField
  ||| The field/column name, taken directly from the constructor arg's
  ||| label - a record field has no positional-arg equivalent, so this is
  ||| required, not optional.
  name : Name
  ||| The field's Idris type, for `fromField {a=type}`/`toField`
  ||| instantiation.
  type : TTImp

fieldOf : Arg -> Res RowField
fieldOf (MkArg _ ExplicitArg (Just nm) ty) = Right (MkRowField nm ty)
fieldOf (MkArg _ ExplicitArg Nothing   _ ) =
  Left "every field must be named (found an unnamed explicit argument)"
fieldOf (MkArg _ _           _         _ ) =
  Left "every field must be an explicit, named argument (found an implicit, auto, or erased argument)"

||| Fails (via `failRecord`) unless `p` has exactly one constructor;
||| otherwise fails with a specific message unless every one of that
||| constructor's arguments is a named, explicit field. Returns the
||| constructor's own `Name` (for applying/pattern-matching it) plus its
||| fields, in declaration order - the single shared source of truth
||| `FromRow`/`ToRow`/`Table` all derive from, so they can never drift
||| out of sync with each other.
recordFields : (interfaceName : String) -> ParamTypeInfo -> Res (Name, List RowField)
recordFields iname p = case p.info.cons of
  [c] => case traverse fieldOf (toList c.args) of
    Right fields => Right (c.name, fields)
    Left err     => Left ("Cannot derive " ++ iname ++ " for " ++ nameStr p.info.name ++ ": " ++ err)
  _   => failRecord iname

--------------------------------------------------------------------------------
--          FromRow
--------------------------------------------------------------------------------

rowVar : Name
rowVar = UN (Basic "row")

-- Chains `fromField {a=<field type>} row "<field name>"` per field, via
-- the same Either-chaining shape as json-simple's own Derive.FromJSON
-- (`decFields`/`matchEither`) - minus the sum-type branching a flat
-- Postgres row never needs.
buildFromRowBody : Name -> List RowField -> TTImp
buildFromRowBody conName fields = go fields []
  where
    go : List RowField -> List Name -> TTImp
    go []        bound = `(Right ~(appAll conName (map var (reverse bound))))
    go (f :: fs) bound =
      let x := UN (Basic ("x" ++ show (length bound)))
       in `(case fromField {a = ~(f.type)} ~(var rowVar) ~(f.name.namePrim) of
             Left err => Left err
             Right ~(bindVar x) => ~(go fs (x :: bound)))

export
customFromRow : Visibility -> DeriveItem
customFromRow vis nms p = case recordFields "FromRow" p of
  Left err => Left err
  Right (conName, fields) =>
    let fun        := funName p "fromRow"
        impl       := implName p "FromRow"
        rowArg     := MkArg MW ExplicitArg (Just rowVar) `(Row)
        ty         := piAll `(Either String ~(p.applied)) (allImplicits p "FromRow" ++ [rowArg])
        claimD     := simpleClaim vis fun ty
        bodyD      := def fun [patClause (var fun `app` bindVar rowVar) (buildFromRowBody conName fields)]
        implClaimD := implClaimVis vis impl (implType "FromRow" p)
        implDefD   := def impl [patClause (var impl) (var "MkFromRow" `app` var fun)]
     in Right [TL claimD bodyD, TL implClaimD implDefD]

public export %inline
FromRow : DeriveItem
FromRow = customFromRow Export

--------------------------------------------------------------------------------
--          ToRow
--------------------------------------------------------------------------------

-- Binds each field to a fresh var (mirrors Derive.Show's use of
-- `bindCon`) and builds `[toField x0, toField x1, ...]`, in field
-- declaration order - no explicit `{a=...}` needed here, since each
-- `xN`'s type is already known from the pattern match.
buildToRowBody : Name -> List RowField -> (TTImp, TTImp)
buildToRowBody conName fields =
  let xs  := toList (freshNames "x" (length fields))
      pat := appAll conName (map bindVar xs)
      rhs := listOf (map (\x => `(toField ~(var x))) xs)
   in (pat, rhs)

export
customToRow : Visibility -> DeriveItem
customToRow vis nms p = case recordFields "ToRow" p of
  Left err => Left err
  Right (conName, fields) =>
    let fun        := funName p "toRow"
        impl       := implName p "ToRow"
        ty         := piAll `(List (Maybe String)) (allImplicits p "ToRow" ++ [MkArg MW ExplicitArg (Just (UN (Basic "rec"))) p.applied])
        claimD     := simpleClaim vis fun ty
        (pat, rhs) := buildToRowBody conName fields
        bodyD      := def fun [patClause (var fun `app` pat) rhs]
        implClaimD := implClaimVis vis impl (implType "ToRow" p)
        implDefD   := def impl [patClause (var impl) (var "MkToRow" `app` var fun)]
     in Right [TL claimD bodyD, TL implClaimD implDefD]

public export %inline
ToRow : DeriveItem
ToRow = customToRow Export

--------------------------------------------------------------------------------
--          Table
--------------------------------------------------------------------------------

joinCommas : List String -> String
joinCommas = concat . intersperse ", "

-- `Data.List` (base) has no `elemIndex` (only `Data.Vect` does) - a
-- small local search is simpler than pulling in a Vect conversion.
findIndexOf : Eq a => a -> List a -> Maybe Nat
findIndexOf x []        = Nothing
findIndexOf x (y :: ys) = if x == y then Just Z else map S (findIndexOf x ys)

placeholdersFrom : (start : Nat) -> (count : Nat) -> List String
placeholdersFrom start n = map (\i => "$" ++ show i) [start .. (start + n `minus` 1)]

buildInsertSql : (table : String) -> (cols : List String) -> (pk : String) -> String
buildInsertSql table cols pk =
  let nonPk := filter (/= pk) cols
   in "INSERT INTO " ++ table ++ " (" ++ joinCommas nonPk ++ ") VALUES (" ++
      joinCommas (placeholdersFrom 1 (length nonPk)) ++ ") RETURNING " ++ joinCommas cols

buildSelectByIdSql : (table : String) -> (cols : List String) -> (pk : String) -> String
buildSelectByIdSql table cols pk =
  "SELECT " ++ joinCommas cols ++ " FROM " ++ table ++ " WHERE " ++ pk ++ " = $1"

buildUpdateSql : (table : String) -> (cols : List String) -> (pk : String) -> String
buildUpdateSql table cols pk =
  let nonPk := filter (/= pk) cols
      sets  := zipWith (\c, ph => c ++ " = " ++ ph) nonPk (placeholdersFrom 1 (length nonPk))
   in "UPDATE " ++ table ++ " SET " ++ joinCommas sets ++ " WHERE " ++ pk ++
      " = $" ++ show (S (length nonPk)) ++ " RETURNING " ++ joinCommas cols

buildDeleteByIdSql : (table : String) -> (pk : String) -> String
buildDeleteByIdSql table pk =
  "DELETE FROM " ++ table ++ " WHERE " ++ pk ++ " = $1 RETURNING " ++ pk

-- Joins per-column TTImp *expressions* (not literal strings - each one
-- involves a runtime `PGColumnType` dispatch, spliced via `~`) with a
-- literal ", " between them, right-associated to avoid needing an
-- extra `Monoid`/`Foldable` constraint on `TTImp` itself.
joinExprsWithComma : List TTImp -> TTImp
joinExprsWithComma []        = primVal (Str "")
joinExprsWithComma [x]       = x
joinExprsWithComma (x :: xs) = `(~(x) ++ ", " ++ ~(joinExprsWithComma xs))

-- One column's `CREATE TABLE` fragment, as a TTImp expression mixing
-- compile-time-known literal parts (the column name, ", NOT NULL",
-- any `columnDefaults` override) with a runtime `PGColumnType`
-- dispatch on the field's own type (`pgColumnType`/`pgAutoIncrementType`/
-- `pgNullable {a = ~ty}`) - the pk column uses its `pgAutoIncrementType`
-- if it has one (falling back to `pgColumnType` plus `PRIMARY KEY`
-- otherwise), every other column uses `pgColumnType` plus `NOT NULL`
-- unless `pgNullable` (i.e. the field's Idris type is `Maybe _`).
columnDefExpr : (pk : String) -> (columnDefaults : List (String, String)) -> RowField -> TTImp
columnDefExpr pk columnDefaults f =
  let colName := nameStr f.name
      ty      := f.type
      deflt   := maybe "" (\d => " DEFAULT " ++ d) (lookup colName columnDefaults)
   in if colName == pk
         then `(~(f.name.namePrim) ++ " " ++
                fromMaybe (pgColumnType {a = ~ty}) (pgAutoIncrementType {a = ~ty}) ++
                " PRIMARY KEY" ++ ~(primVal (Str deflt)))
         else `(~(f.name.namePrim) ++ " " ++ pgColumnType {a = ~ty} ++
                (if pgNullable {a = ~ty} then "" else " NOT NULL") ++
                ~(primVal (Str deflt)))

buildCreateTableSqlExpr : (table : String) -> (pk : String) -> (columnDefaults : List (String, String)) -> List RowField -> TTImp
buildCreateTableSqlExpr table pk columnDefaults fields =
  let colExprs := map (columnDefExpr pk columnDefaults) fields
   in `(~(primVal (Str ("CREATE TABLE IF NOT EXISTS " ++ table ++ " (")))
        ++ ~(joinExprsWithComma colExprs) ++ ")")

export
customTable :
     Visibility
  -> (tableOverride : Maybe String)
  -> (pkOverride : Maybe String)
  -> (columnDefaults : List (String, String))
  -> DeriveItem
customTable vis tableOverride pkOverride columnDefaults nms p = case recordFields "Table" p of
  Left err => Left err
  Right (_, fields) =>
    let cols  := map (\f => nameStr f.name) fields
        table := fromMaybe (toLower (nameStr p.info.name)) tableOverride
        pk    := fromMaybe "id" pkOverride
     in case findIndexOf pk cols of
          Nothing => Left ("Cannot derive Table for " ++ nameStr p.info.name ++
                            ": no field named \"" ++ pk ++
                            "\" (expected the primary key; override it if this type's pk isn't named \"id\")")
          Just pkIdx =>
            let impl := implName p "Table"
                implClaimD := implClaimVis vis impl (implType "Table" p)
                implDefD   := def impl
                  [ patClause (var impl)
                      (appAll "MkTable"
                        [ var "Prelude.id"
                        , primVal (Str table)
                        , listOf (map (primVal . Str) cols)
                        , primVal (Str pk)
                        , `(fromInteger ~(primVal (BI (cast pkIdx))))
                        , primVal (Str (buildInsertSql table cols pk))
                        , primVal (Str (buildSelectByIdSql table cols pk))
                        , primVal (Str (buildUpdateSql table cols pk))
                        , primVal (Str (buildDeleteByIdSql table pk))
                        , buildCreateTableSqlExpr table pk columnDefaults fields
                        ])
                  ]
             in Right [TL implClaimD implDefD]

public export %inline
Table : DeriveItem
Table = customTable Export Nothing Nothing []

--------------------------------------------------------------------------------
--          deriveSubset (general-purpose field-subset companion type)
--------------------------------------------------------------------------------

argName' : Arg -> Maybe String
argName' (MkArg _ _ (Just nm) _) = Just (nameStr nm)
argName' _                       = Nothing

-- `simpleDataPublic`/`IData` (a plain `data` declaration) does NOT get
-- Idris2's automatic record field-accessor sugar the way an actual
-- `record` block does - `rec.title` wouldn't resolve, and worse, a
-- hand-written accessor function under that name collides outright with
-- any OTHER same-named field's accessor already in scope (confirmed
-- directly: two real `record`s sharing a field name in one module
-- coexist fine - Idris2 treats real record accessors as an overload set
-- - but a plain top-level function declared via `declare` with the same
-- name as an existing accessor fails elaboration with "already
-- defined", since it isn't registered as part of that overload set).
-- `IRecord` (`Language.Reflection.TTImp`) is the actual AST node the
-- PARSER itself produces for a `record ... where` block - declaring one
-- via reflection instead of `IData` gets the genuine field-accessor
-- (and overload) behavior for free, no hand-rolled projection functions
-- needed.
toIField : Arg -> Maybe IField
toIField (MkArg c pi (Just nm) ty) = Just (MkIField EmptyFC c pi nm ty)
toIField _                         = Nothing

||| Declares a new, single-constructor record type named `newTypeName`,
||| containing exactly the fields of `orig` whose names appear in
||| `keepFields` - in `orig`'s own declaration order (`keepFields` is a
||| filter, not a reordering) - then runs `derive newTypeName derives`
||| against it. `deriveSubset ["title","done"] "TodoUpdate" [FromJSON]
||| "Todo"` is exactly equivalent to hand-declaring `record TodoUpdate
||| where constructor MkTodoUpdate; title : String; done : Bool` plus
||| `%runElab derive "TodoUpdate" [FromJSON]`.
|||
||| Deliberately inclusive (a whitelist), not exclusive (`Table`'s pk
||| exclusion is the one place that pattern still makes sense, see
||| `deriveInsertable` below, which builds on this) - for anything a
||| caller constructs from untrusted input (an HTTP request body, say),
||| a field added to `orig` later should have to be deliberately opted
||| into the companion type, not silently inherited by it.
|||
||| `derives` can be ANY `derive`-style item - this module's own
||| `FromRow`/`ToRow`, `elab-util`'s `Show`/`Eq`, `json-simple`'s
||| `FromJSON`/`ToJSON`, etc. - since `derive` itself
||| (`Language.Reflection.Derive`) is `Elaboration m => ...`, callable
||| directly from inside this function's own `Elab` action, the same way
||| `declare` is. This is why `deriveSubset` has to be a hand-written
||| `Elab ()` script rather than one more item in a `[...]` derive list
||| the way `FromRow`/`ToRow`/`Table` above are: `derive`'s own
||| `Res (List TopLevel)` machinery assumes every item is a single
||| claim+definition pair, with no way to express "first declare a whole
||| new data type, THEN derive against it" (the new type has to actually
||| exist, via a real `declare` call, before `derive` can check anything
||| against it). Confirmed empirically this doesn't hit the "Bad
||| elaborator script" cross-module reduction limit documented at the
||| top of this file either way - unlike the pure
||| `Res`-computation-then-`declare` style above, a real `Elab` do-block
||| is executed step by step by the compiler itself (not first
||| normalized as one big pure term), so it works both inline and from
||| another module the same way.
export
deriveSubset :
     (keepFields : List String)
  -> (newTypeName : String)
  -> List DeriveItem
  -> Name -> Elab ()
deriveSubset keepFields newTypeNameStr derives orig = do
  ti <- getInfo' orig
  let [c] = ti.cons
      | _ => fail ("deriveSubset: " ++ nameStr orig ++ " must be a single-constructor record")
  let allNames := mapMaybe argName' (toList c.args)
      missing  := filter (\f => not (f `elem` allNames)) keepFields
  case missing of
    (_ :: _) => fail ("deriveSubset: " ++ nameStr orig ++ " has no field(s) named " ++ show missing)
    []       => do
      let isKept : Arg -> Bool
          isKept a = case argName' a of
            Just nm => nm `elem` keepFields
            Nothing => False
      let kept     := filter isKept (toList c.args)
          newName  := UN (Basic newTypeNameStr)
          ctorName := UN (Basic ("Mk" ++ newTypeNameStr))
          fields   := mapMaybe toIField kept
          recDecl  := MkRecord EmptyFC newName [] [] ctorName fields
      -- `ns := Just newTypeNameStr` matters, not just cosmetic: a normal
      -- `record X where ...` block implicitly nests its own field
      -- accessors under an `X` namespace (confirmed via the error
      -- output when this was `Nothing` - "Main.(.label) is already
      -- defined" the SECOND time `deriveSubset`/`deriveInsertable`
      -- generated a type with a field of the same name as an earlier
      -- one; a reflection-declared `IRecord` needs the same nesting
      -- explicitly, or its accessors collide flatly at `Main.<field>`
      -- with every other same-named field, including other
      -- reflection-declared ones - not just real `record` blocks).
      declare [ IRecord EmptyFC (Just newTypeNameStr) (specified Public) Nothing recDecl ]
      derive newName derives

--------------------------------------------------------------------------------
--          Insertable (auto-generated pk-less companion type)
--------------------------------------------------------------------------------

||| Given an existing single-constructor record `orig` (already
||| `%runElab derive`d with `[Table]`, though this doesn't check that),
||| generates a fresh record type named `New<orig>` with every field of
||| `orig` EXCEPT `pk` (default `"id"`, same convention as `Table`'s own
||| primary-key field) via `deriveSubset` (with `[ToRow]`), plus an
||| `Insertable New<orig> orig` instance linking it back - i.e.
||| everything `insert` (`DB.Crud`) needs, without a caller
||| hand-writing a second record. Excluding the pk is the one place an
||| EXCLUDE-shaped companion type still makes sense (Postgres, not the
||| caller, assigns it) - contrast `deriveSubset` itself, which is
||| deliberately an include-list for everything else.
export
deriveInsertable : (pkOverride : Maybe String) -> Name -> Elab ()
deriveInsertable pkOverride orig = do
  ti <- getInfo' orig
  let [c] = ti.cons
      | _ => fail "Insertable derivation only supports single-constructor records"
  let pk       := fromMaybe "id" pkOverride
      allNames := mapMaybe argName' (toList c.args)
  case pk `elem` allNames of
    False => fail ("Cannot derive Insertable for " ++ nameStr orig ++
                    ": no field named \"" ++ pk ++
                    "\" (expected the primary key; pass an override if this type's pk isn't named \"id\")")
    True  => do
      let keepFields     := filter (/= pk) allNames
          newTypeNameStr := "New" ++ nameStr orig
      deriveSubset keepFields newTypeNameStr [ToRow] orig

      let newName   := UN (Basic newTypeNameStr)
          insImpl   := UN (Basic ("implInsertable" ++ newTypeNameStr))
          insClaimD := implClaimVis Export insImpl `(Insertable ~(var newName) ~(var orig))
          insDefD   := def insImpl [patClause (var insImpl) (var "MkInsertable" `app` var "Prelude.id")]
      declare [insClaimD, insDefD]

--------------------------------------------------------------------------------
--          deriveColumns (per-table Column companion type + value)
--------------------------------------------------------------------------------

lowerFirst : String -> String
lowerFirst s = case unpack s of
  []        => s
  (c :: cs) => pack (toLower c :: cs)

||| Generates a companion record type `<orig>Columns` (e.g.
||| `TodoColumns`) whose fields are `Column orig <fieldType>` for every
||| field of `orig`, plus a top-level value (`todoColumns` for `Todo`)
||| constructing it with each field's own `MkColumn "<fieldName>"` - the
||| typed column references `DB.Query`'s `Condition`/`Query` builder
||| runs on (`todoColumns.title ==. "Buy milk"`). Reuses `recordFields`,
||| the same field-enumeration source of truth `customFromRow`/
||| `customToRow`/`customTable` already share - called via
||| `getParamInfo'` (not `getInfo'`, which `deriveSubset`/
||| `deriveInsertable` use) since `recordFields` takes a `ParamTypeInfo`.
export
deriveColumns : Name -> Elab ()
deriveColumns orig = do
  p <- getParamInfo' orig
  case recordFields "Columns" p of
    Left err          => fail err
    Right (_, fields) => do
      let origTypeStr    := nameStr p.info.name
          newTypeNameStr := origTypeStr ++ "Columns"
          newName        := UN (Basic newTypeNameStr)
          ctorName       := UN (Basic ("Mk" ++ newTypeNameStr))
          colField : RowField -> IField
          colField f = MkIField EmptyFC MW ExplicitArg f.name `(Column ~(p.applied) ~(f.type))
          recDecl        := MkRecord EmptyFC newName [] [] ctorName (map colField fields)
      -- ns := Just newTypeNameStr matters, not cosmetic - same reason
      -- deriveSubset needs it: two reflection-declared IRecords sharing
      -- a field name (every table has an "id") collide without it.
      declare [ IRecord EmptyFC (Just newTypeNameStr) (specified Public) Nothing recDecl ]

      let valName := UN (Basic (lowerFirst origTypeStr ++ "Columns"))
          colExpr : RowField -> TTImp
          colExpr f = `(MkColumn ~(f.name.namePrim))
          claimD     := simpleClaim Export valName (var newName)
          bodyD      := def valName [patClause (var valName) (appAll ctorName (map colExpr fields))]
      declare [claimD, bodyD]
