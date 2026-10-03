||| A `FromJSON` derivation that always decodes a single-constructor
||| record as a plain JSON object (`{"field": value, ...}`), regardless
||| of field count.
|||
||| `json-simple`'s own `FromJSON` derive special-cases exactly one field
||| as a "newtype" and unwraps it to the bare value (`"value"` instead of
||| `{"field":"value"}`) - confirmed directly (not assumed) via a minimal
||| standalone repro against this exact library version: a 2-field
||| record derives correctly, only the 1-field case does this. Reading
||| `Derive.FromJSON.Simple`'s own source confirms it, too - single-field
||| unwrapping happens unconditionally in its `decRecord` (the plain,
||| untagged-record path every single-constructor type goes through by
||| default), with no `Options` flag able to turn it off without also
||| switching to sum-type-shaped tagging (`{"tag":...,"contents":...}`),
||| which isn't what a single-field API body wants either.
|||
||| This derivation is deliberately independent of `flux-postgres`'s
||| `DB.Derive.ActiveRecord` - it's plain JSON, with no DB coupling at
||| all - but is written the same way and is meant to compose with
||| `flux-postgres`'s `deriveSubset` the same way `FromRow`/`ToRow`/
||| `elab-util`'s `Show`/`Eq` do: pass `[ObjectFromJSON]` as `deriveSubset`'s
||| `derives` argument to get a companion type's JSON body decoded this
||| way instead of through `json-simple`'s own `FromJSON`.
module DB.ObjectFromJSON

import public JSON.Simple
import Language.Reflection.Util

%language ElabReflection
%default total

fieldOf : Arg -> Res (Name, TTImp)
fieldOf (MkArg _ ExplicitArg (Just nm) ty) = Right (nm, ty)
fieldOf (MkArg _ ExplicitArg Nothing   _ ) =
  Left "every field must be named (found an unnamed explicit argument)"
fieldOf (MkArg _ _           _         _ ) =
  Left "every field must be an explicit, named argument (found an implicit, auto, or erased argument)"

objVar : Name
objVar = UN (Basic "obj")

-- Chains `field {a=<field type>} obj "<field name>"` per field, via the
-- same Either-chaining shape as `DB.Derive.ActiveRecord`'s `FromRow` (and
-- json-simple's own `Derive.FromJSON.Simple`'s `decFields`/`matchEither`
-- - the exact logic that gets skipped for a single-field record there).
buildBody : Name -> List (Name, TTImp) -> TTImp
buildBody conName fields = go fields []
  where
    go : List (Name, TTImp) -> List Name -> TTImp
    go []             bound = `(Right ~(appAll conName (map var (reverse bound))))
    go ((nm, ty) :: fs) bound =
      let x := UN (Basic ("x" ++ show (length bound)))
       in `(case field {a = ~ty} ~(var objVar) ~(nm.namePrim) of
             Left err => Left err
             Right ~(bindVar x) => ~(go fs (x :: bound)))

export
customObjectFromJSON : Visibility -> List Name -> ParamTypeInfo -> Res (List TopLevel)
customObjectFromJSON vis nms p = case p.info.cons of
  [c] => case traverse fieldOf (toList c.args) of
    Left err     => Left ("Cannot derive ObjectFromJSON for " ++ nameStr p.info.name ++ ": " ++ err)
    Right fields =>
      let fun        := funName p "fromJSON"
          impl       := implName p "FromJSON"
          ty         := piAll `(Parser JSON ~(p.applied)) (allImplicits p "FromJSON")
          claimD     := simpleClaim vis fun ty
          body       := `(withObject ~(p.info.name.namePrim) (\ ~(bindVar objVar) => ~(buildBody c.name fields)))
          bodyD      := def fun [patClause (var fun) body]
          implClaimD := implClaimVis vis impl (implType "FromJSON" p)
          implDefD   := def impl [patClause (var impl) (var "MkFromJSON" `app` var fun)]
       in Right [TL claimD bodyD, TL implClaimD implDefD]
  _ => failRecord "ObjectFromJSON"

public export %inline
ObjectFromJSON : List Name -> ParamTypeInfo -> Res (List TopLevel)
ObjectFromJSON = customObjectFromJSON Export
