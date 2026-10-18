module Ficus.Syntax.Core.Intrinsic (constructorSignature, primitiveSignature, primitiveFromKey, literalType) where

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
  IntNegate -> ([int], int)
  FloatNegate -> ([primitive FloatType], primitive FloatType)
  where
    int = primitive IntType
    bool = primitive BoolType
    string = primitive StringType
    intBinary result = ([int, int], result)

literalType :: L.Literal -> Type v
literalType literal = primitive $ case literal of
  L.IntegerLiteral _ -> IntType
  L.FloatLiteral _ -> FloatType
  L.CharacterLiteral _ -> CharType
  L.StringLiteral _ -> StringType
