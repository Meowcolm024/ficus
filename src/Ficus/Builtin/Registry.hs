-- | Frontend adapter for the shared primitive inventory: semantic kinds and
-- ordinary source identities are added here, without changing registry keys.
module Ficus.Builtin.Registry (BuiltinContract (..), builtinRegistry, builtinKeys, primitiveFromKey, typeKindFromKey, specializePrimitive) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text (Text)
import Ficus.Primitive.Registry qualified as P
import Ficus.Syntax.Name (GlobalId (..), ModuleId (..), Namespace (..), PrimitiveId)
import Ficus.Type (Kind (..))

data BuiltinContract = ValueBuiltin PrimitiveId | TypeBuiltin Kind | TraitBuiltin Kind deriving (Eq, Show)

builtinRegistry :: Map Text BuiltinContract
builtinRegistry =
  Map.fromList
    ( [(P.builtinTypeKey builtin, TraitBuiltin (KindArrow TypeKind TypeKind)) | builtin <- P.builtinTraits]
        ++ [(P.builtinTypeKey builtin, TypeBuiltin (foldr KindArrow TypeKind (replicate (P.builtinTypeArity builtin) TypeKind))) | builtin <- P.builtinTypes]
        ++ [(key, ValueBuiltin (fmap (libraryType . P.builtinTypeName) operation)) | (Just key, operation) <- P.primitiveCatalog]
    )

builtinKeys :: Set Text
builtinKeys = Map.keysSet builtinRegistry

primitiveFromKey :: Text -> Maybe PrimitiveId
primitiveFromKey key = case Map.lookup key builtinRegistry of
  Just (ValueBuiltin primitive) -> Just primitive
  _ -> Nothing

typeKindFromKey :: Text -> Maybe Kind
typeKindFromKey key = case Map.lookup key builtinRegistry of
  Just (TypeBuiltin kind) -> Just kind
  _ -> Nothing

-- Nominal library types keep their source identities, including renamed targets.
libraryType :: Text -> GlobalId
libraryType name = GlobalId (ModuleId ("Ficus" :| ["Builtin", name])) TypeNS name

specializePrimitive :: Map Text GlobalId -> PrimitiveId -> Maybe PrimitiveId
specializePrimitive types operation =
  case [template | (_, template) <- P.primitiveCatalog, P.erasePrimitive template == P.erasePrimitive operation] of
    template : _ -> traverse (\builtin -> Map.lookup (P.builtinTypeKey builtin) types) template
    [] -> Nothing
