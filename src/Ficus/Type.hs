-- | Semantic types shared by compiler stages. The variable parameter keeps
-- inference metavariables out of accepted Core and checked interfaces.
module Ficus.Type where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Primitive.Registry qualified as P
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Syntax.Name qualified as N

data Kind = TypeKind | KindArrow Kind Kind deriving (Eq, Ord, Show)

newtype BoundId = BoundId Int deriving (Eq, Ord, Show)

data Type v
  = Variable v Kind
  | Constructor GlobalId Kind
  | Application (Type v) (Type v)
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

data Quantifier = Quantifier {quantifierId :: BoundId, quantifierName :: Text, quantifierKind :: Kind} deriving (Eq, Show)

data Predicate ty = Predicate {predicateTrait :: GlobalId, predicateArgument :: ty} deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

-- | Explicit binders are addressable by source @ application; implicit binders
-- are instantiated as well, but have no source-visible argument position.
data Scheme ty = Scheme
  { explicitQuantifiers :: [Quantifier],
    implicitQuantifiers :: [Quantifier],
    schemePredicates :: [Predicate ty],
    schemeType :: ty
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

monomorphic :: ty -> Scheme ty
monomorphic = Scheme [] [] []

quantifiers :: Scheme ty -> [Quantifier]
quantifiers s = explicitQuantifiers s ++ implicitQuantifiers s

data KindError = KindMismatch Kind Kind | NotATypeFunction Kind deriving (Eq, Show)

kindOf :: Type v -> Either KindError Kind
kindOf ty = case ty of
  Variable _ k -> Right k
  Constructor _ k -> Right k
  Application f x -> do
    fk <- kindOf f
    xk <- kindOf x
    case fk of
      KindArrow input output
        | input == xk -> Right output
        | otherwise -> Left (KindMismatch input xk)
      _ -> Left (NotATypeFunction fk)

primitiveKind :: Intrinsic -> Kind
primitiveKind intrinsic = foldr KindArrow TypeKind (replicate (P.intrinsicArity intrinsic) TypeKind)

primitive :: Intrinsic -> Type v
primitive p = Constructor (IntrinsicId p) (primitiveKind p)

function :: Type v -> Type v -> Type v
function = arrow StrictArrow

data ArrowMode = StrictArrow | NameArrow deriving (Eq, Ord, Show)

arrow :: ArrowMode -> Type v -> Type v -> Type v
arrow mode a b = Application (Application (primitive constructor) a) b
  where
    constructor = case mode of StrictArrow -> FunctionType; NameArrow -> LazyFunctionType

arrowParts :: Type v -> Maybe (ArrowMode, Type v, Type v)
arrowParts (Application (Application (Constructor (IntrinsicId constructor) _) a) b) = case constructor of
  FunctionType -> Just (StrictArrow, a, b)
  LazyFunctionType -> Just (NameArrow, a, b)
  _ -> Nothing
arrowParts _ = Nothing

list :: Type v -> Type v
list = Application (primitive ListType)

productType :: Type v -> Type v -> Type v
productType a b = Application (Application (primitive ProductType) a) b

functionParts :: Type v -> Maybe (Type v, Type v)
functionParts (Application (Application (Constructor (IntrinsicId FunctionType) _) a) b) = Just (a, b)
functionParts _ = Nothing

freeVariables :: (Ord v) => Type v -> Set v
freeVariables = Set.fromList . foldr (:) []

renderKind :: Kind -> Text
renderKind TypeKind = "Type"
renderKind (KindArrow a b) = domain a <> " -> " <> renderKind b
  where
    domain TypeKind = "Type"
    domain k = "(" <> renderKind k <> ")"

renderType :: forall v. (v -> Text) -> Type v -> Text
renderType variable = render 0
  where
    render :: Int -> Type v -> Text
    render precedence ty = case ty of
      Variable v _ -> variable v
      Constructor gid _ -> renderConstructor gid
      Application (Application (Constructor (IntrinsicId FunctionType) _) a) b ->
        parens (precedence > 0) (render 1 a <> " -> " <> render 0 b)
      Application (Application (Constructor (IntrinsicId LazyFunctionType) _) a) b ->
        parens (precedence > 0) (render 1 a <> " ~> " <> render 0 b)
      Application (Application (Constructor (IntrinsicId ProductType) _) a) b ->
        parens (precedence > 1) (render 2 a <> " * " <> render 1 b)
      Application (Constructor (IntrinsicId ListType) _) a -> "[" <> render 0 a <> "]"
      Application f x -> parens (precedence > 2) (render 2 f <> " " <> render 3 x)
    parens True s = "(" <> s <> ")"
    parens False s = s

renderConstructor :: GlobalId -> Text
renderConstructor (GlobalId _ _ name) = name
renderConstructor (IntrinsicId p) = case p of
  IntType -> "Int"
  FloatType -> "Float"
  BoolType -> "Bool"
  CharType -> "Char"
  StringType -> "String"
  UnitType -> "Unit"
  ListType -> "[]"
  ProductType -> "(*)"
  FunctionType -> "(->)"
  LazyFunctionType -> "(~>)"
  N.TypeKind -> "Type"
  TrueConstructor -> "True"
  FalseConstructor -> "False"
  ConsConstructor -> "(::)"
  NilConstructor -> "[]"

renderBound :: BoundId -> Text
renderBound (BoundId n) = "a" <> T.pack (show n)
