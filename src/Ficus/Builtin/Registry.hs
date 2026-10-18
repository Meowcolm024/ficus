-- | Compiler builtin contracts shared across stages. Keys are metadata;
-- source declarations retain their ordinary nominal identities.
module Ficus.Builtin.Registry (BuiltinContract (..), builtinRegistry, builtinKeys, primitiveFromKey, typeKindFromKey) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text (Text)
import Ficus.Syntax.Name (PrimitiveId (..))
import Ficus.Type (Kind (..))

data BuiltinContract = ValueBuiltin PrimitiveId | TypeBuiltin Kind deriving (Eq, Show)

builtinRegistry :: Map Text BuiltinContract
builtinRegistry =
  Map.fromList
    [ ("HANDLE", TypeBuiltin TypeKind),
      ("INT_ADD", ValueBuiltin IntAdd),
      ("INT_SUB", ValueBuiltin IntSubtract),
      ("INT_MUL", ValueBuiltin IntMultiply),
      ("INT_DIV", ValueBuiltin IntDivide),
      ("INT_REM", ValueBuiltin IntRemainder),
      ("INT_EQ", ValueBuiltin IntEqual),
      ("INT_LT", ValueBuiltin IntLess),
      ("INT_SHOW", ValueBuiltin IntShow),
      ("STRING_APPEND", ValueBuiltin StringAppend),
      ("STRING_EQ", ValueBuiltin StringEqual),
      ("STRING_LENGTH", ValueBuiltin StringLength)
    ]

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
