module Ficus.Syntax.Core.Intrinsic (constructorSignature, primitiveSignature, primitiveScheme, matchesPrimitive, primitiveFromKey, literalType) where

import Control.Monad (foldM)
import Data.Map.Strict qualified as Map
import Ficus.Builtin.Registry (primitiveFromKey)
import Ficus.Syntax.Core (ConstructorId (..), CoreType, CoreVariable (..))
import Ficus.Syntax.Literal qualified as L
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Type

constructorSignature :: ConstructorId -> Maybe (Scheme CoreType, Int)
constructorSignature constructor = case constructor of
  DataConstructor (IntrinsicId TrueConstructor) -> Just (monomorphic bool, 0)
  DataConstructor (IntrinsicId FalseConstructor) -> Just (monomorphic bool, 0)
  DataConstructor (IntrinsicId NilConstructor) -> Just (poly [qa] (list a), 0)
  DataConstructor (IntrinsicId ConsConstructor) -> Just (poly [qa] (function a (function (list a) (list a))), 2)
  PairConstructor -> Just (poly [qa, qb] (function a (function b (productType a b))), 2)
  UnitConstructor -> Just (monomorphic (primitive UnitType), 0)
  _ -> Nothing
  where
    bool = primitive BoolType
    qa = Quantifier (BoundId (-1)) "a" TypeKind
    qb = Quantifier (BoundId (-2)) "b" TypeKind
    a = Variable (BoundVariable (quantifierId qa)) TypeKind
    b = Variable (BoundVariable (quantifierId qb)) TypeKind
    poly qs = Scheme [] qs []

primitiveSignature :: PrimitiveId -> ([CoreType], CoreType)
primitiveSignature primitiveId = case primitiveId of
  IntAdd -> intBinary int
  IntSubtract -> intBinary int
  IntMultiply -> intBinary int
  IntDivide -> intBinary int
  IntRemainder -> intBinary int
  IntEqual -> intBinary bool
  IntLess -> intBinary bool
  IntShow -> ([int], string)
  StringAppend -> ([string, string], string)
  StringEqual -> ([string, string], bool)
  StringLength -> ([string], int)
  IntToFloat -> ([int], float)
  FloatAdd -> floatBinary float
  FloatSubtract -> floatBinary float
  FloatMultiply -> floatBinary float
  FloatDivide -> floatBinary float
  FloatEqual -> floatBinary bool
  FloatLess -> floatBinary bool
  FloatShow -> ([float], string)
  FloatToInt -> ([float], int)
  CharEqual -> ([char, char], bool)
  CharLess -> ([char, char], bool)
  CharShow -> ([char], string)
  StringLess -> ([string, string], bool)
  StringToChars -> ([string], list char)
  CharsToString -> ([list char], string)
  Print -> ([string], primitive UnitType)
  Println -> ([string], primitive UnitType)
  ReadLine -> ([primitive UnitType], string)
  Absurd ident -> ([Constructor ident TypeKind], a)
  VecFromList ident -> ([list a], vec ident a)
  VecToList ident -> ([vec ident a], list a)
  VecLength ident -> ([vec ident a], int)
  ByteFromInt ident -> ([int], Constructor ident TypeKind)
  ByteToInt ident -> ([Constructor ident TypeKind], int)
  IntNegate -> ([int], int)
  FloatNegate -> ([primitive FloatType], primitive FloatType)
  where
    int = primitive IntType
    bool = primitive BoolType
    string = primitive StringType
    float = primitive FloatType
    char = primitive CharType
    a = Variable (BoundVariable (BoundId (-1))) TypeKind
    vec ident = Application (Constructor ident (KindArrow TypeKind TypeKind))
    floatBinary result = ([float, float], result)
    intBinary result = ([int, int], result)

literalType :: L.Literal -> Type v
literalType literal = primitive $ case literal of
  L.IntegerLiteral _ -> IntType
  L.FloatLiteral _ -> FloatType
  L.CharacterLiteral _ -> CharType
  L.StringLiteral _ -> StringType

-- Primitive templates quantify only their element/result variable. Nominal
-- opaque constructors have already been specialized from builtin metadata.
primitiveScheme :: PrimitiveId -> Scheme CoreType
primitiveScheme ident =
  let (inputs, output) = primitiveSignature ident
      ty = foldr function output inputs
      qs = [Quantifier (BoundId (-1)) "a" TypeKind | not (null (freeVariables ty))]
   in Scheme [] qs [] ty

matchesPrimitive :: PrimitiveId -> [CoreType] -> CoreType -> Bool
matchesPrimitive ident inputs output =
  let (expected, result) = primitiveSignature ident
   in length inputs == length expected && case foldM match Map.empty (zip (expected ++ [result]) (inputs ++ [output])) of
        Nothing -> False
        Just _ -> True
  where
    match substitution (template, actual) = case template of
      Variable (BoundVariable key) kind -> case Map.lookup key substitution of
        Just previous | previous == actual -> Just substitution
        Just _ -> Nothing
        Nothing | kindOf actual == Right kind -> Just (Map.insert key actual substitution)
        _ -> Nothing
      Constructor ident' kind -> case actual of
        Constructor actualId actualKind | ident' == actualId && kind == actualKind -> Just substitution
        _ -> Nothing
      Application f x -> case actual of
        Application g y -> match substitution (f, g) >>= \extended -> match extended (x, y)
        _ -> Nothing
      _ -> Nothing
