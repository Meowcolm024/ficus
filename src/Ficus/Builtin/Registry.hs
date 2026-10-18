-- | Compiler builtin contracts shared across stages. Keys are metadata;
-- source declarations retain their ordinary nominal identities.
module Ficus.Builtin.Registry (BuiltinContract (..), builtinRegistry, builtinKeys, primitiveFromKey, typeKindFromKey, specializePrimitive) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text (Text)
import Ficus.Syntax.Name (GlobalId (..), ModuleId (..), Namespace (..), PrimitiveId (..))
import Ficus.Type (Kind (..))

data BuiltinContract = ValueBuiltin PrimitiveId | TypeBuiltin Kind deriving (Eq, Show)

builtinRegistry :: Map Text BuiltinContract
builtinRegistry =
  Map.fromList
    [ ("HANDLE", TypeBuiltin TypeKind),
      ("VOID", TypeBuiltin TypeKind),
      ("BYTE", TypeBuiltin TypeKind),
      ("VEC", TypeBuiltin (KindArrow TypeKind TypeKind)),
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
      ("STRING_LENGTH", ValueBuiltin StringLength),
      ("INT_TO_FLOAT", ValueBuiltin IntToFloat),
      ("FLOAT_ADD", ValueBuiltin FloatAdd),
      ("FLOAT_SUB", ValueBuiltin FloatSubtract),
      ("FLOAT_MUL", ValueBuiltin FloatMultiply),
      ("FLOAT_DIV", ValueBuiltin FloatDivide),
      ("FLOAT_EQ", ValueBuiltin FloatEqual),
      ("FLOAT_LT", ValueBuiltin FloatLess),
      ("FLOAT_SHOW", ValueBuiltin FloatShow),
      ("FLOAT_TO_INT", ValueBuiltin FloatToInt),
      ("CHAR_EQ", ValueBuiltin CharEqual),
      ("CHAR_LT", ValueBuiltin CharLess),
      ("CHAR_SHOW", ValueBuiltin CharShow),
      ("STRING_LT", ValueBuiltin StringLess),
      ("STRING_TO_CHARS", ValueBuiltin StringToChars),
      ("STRING_FROM_CHARS", ValueBuiltin CharsToString),
      ("PRINT", ValueBuiltin Print),
      ("PRINTLN", ValueBuiltin Println),
      ("READ_LINE", ValueBuiltin ReadLine),
      ("ABSURD", ValueBuiltin (Absurd (libraryType "Void"))),
      ("VEC_FROM_LIST", ValueBuiltin (VecFromList (libraryType "Vec"))),
      ("VEC_TO_LIST", ValueBuiltin (VecToList (libraryType "Vec"))),
      ("VEC_LENGTH", ValueBuiltin (VecLength (libraryType "Vec"))),
      ("BYTE_FROM_INT", ValueBuiltin (ByteFromInt (libraryType "Byte"))),
      ("BYTE_TO_INT", ValueBuiltin (ByteToInt (libraryType "Byte")))
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

-- Nominal library types keep their source identities, including renamed targets.
libraryType :: Text -> GlobalId
libraryType name = GlobalId (ModuleId ("Ficus" :| ["Builtin", name])) TypeNS name

specializePrimitive :: Map Text GlobalId -> PrimitiveId -> Maybe PrimitiveId
specializePrimitive types primitive = case primitive of
  Absurd _ -> Absurd <$> Map.lookup "VOID" types
  VecFromList _ -> VecFromList <$> Map.lookup "VEC" types
  VecToList _ -> VecToList <$> Map.lookup "VEC" types
  VecLength _ -> VecLength <$> Map.lookup "VEC" types
  ByteFromInt _ -> ByteFromInt <$> Map.lookup "BYTE" types
  ByteToInt _ -> ByteToInt <$> Map.lookup "BYTE" types
  _ -> Just primitive
