-- | Typed, unary Core. This stage owns its syntax and diagnostic placeholders;
-- it imports neither Abstract syntax nor inference's solver variables.
module Ficus.Syntax.Core (module Ficus.Syntax.Core, PrimitiveId (..)) where

import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Ficus.Syntax.Literal (Literal)
import Ficus.Syntax.Name
import Ficus.Type (BoundId, Kind, Quantifier, Scheme, Type)
import Ficus.Util.Source

data Node a = Node
  { nodeId :: NodeId,
    nodeSpan :: Span,
    nodeOrigin :: Provenance,
    nodeValue :: a
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

newtype DiagnosticMetaId = DiagnosticMetaId Int deriving (Eq, Ord, Show)

data CoreVariable = BoundVariable BoundId | DiagnosticVariable DiagnosticMetaId deriving (Eq, Ord, Show)

type CoreType = Type CoreVariable

data BinderRole = ValueBinder | EvidenceBinder deriving (Eq, Show)

type Binder ty = Node (LocalId, Text, BinderRole, ty)

type Expr ty = Node (TypedExpr ty)

data TypedExpr ty = TypedExpr {expressionType :: ty, expressionForm :: ExprF ty}
  deriving (Eq, Show, Functor, Foldable, Traversable)

data ConstructorId = DataConstructor GlobalId | PairConstructor | UnitConstructor deriving (Eq, Ord, Show)

data FieldId = FieldId GlobalId Int deriving (Eq, Ord, Show)

data ExprF ty
  = Var Reference [ty]
  | Literal Literal
  | Hole HoleId
  | Lambda (Binder ty) (Expr ty)
  | Apply (Expr ty) (Expr ty)
  | Let (Binding ty) (Expr ty)
  | LetRec (NonEmpty (Binding ty)) (Expr ty)
  | Construct ConstructorId [ty] [Expr ty]
  | Case (Expr ty) [Alternative ty] (Expr ty)
  | If [Node (Expr ty, Expr ty)] (Maybe (Expr ty))
  | SelectField (Expr ty) FieldId
  | Dictionary GlobalId ty [Expr ty] [PolyValue ty]
  | SelectMethod (Expr ty) GlobalId Int [ty]
  | SelectSuperclass (Expr ty) GlobalId Int
  | ScopeTypes [Node Quantifier] (Expr ty)
  | Primitive PrimitiveId [Expr ty]
  | Fail
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- | Method-local quantification is confined to dictionary fields. ScopeTypes
-- binds erased internal types that do not occur in its expression's result.
type PolyValue ty = Node (Scheme ty, Expr ty)

data DictionaryDescriptor ty = DictionaryDescriptor
  { dictionaryParameter :: Quantifier,
    dictionarySuperclasses :: [Node ty],
    dictionaryMethods :: [Node (GlobalId, Scheme ty)]
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

type Alternative ty = Node (CaseTest ty, Expr ty)

data CaseTest ty
  = ConstructorTest ConstructorId [ty] [Binder ty]
  | LiteralTest Literal
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- | Source initialization facts survive erased type abstraction and generated
-- lambdas. Recursive safety is rechecked against the actual Core references.
data BindingFacts = BindingFacts
  { writtenValueParameters :: Int,
    expansiveOrigin :: Maybe Span
  }
  deriving (Eq, Show)

type Binding ty = Node (BindingF ty)

data BindingF ty = Binding
  { bindingReference :: Reference,
    bindingScheme :: Scheme ty,
    bindingBody :: Expr ty,
    bindingFacts :: BindingFacts
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data BindingGroup ty = NonRecursive (Binding ty) | Recursive (NonEmpty (Binding ty))
  deriving (Eq, Show, Functor, Foldable, Traversable)

data ConstructorDescriptor ty = ConstructorDescriptor
  { constructorScheme :: Scheme ty,
    constructorArity :: Int,
    constructorOwner :: GlobalId
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- Field schemes have the form forall parameters. Record parameters -> Field.
data RecordDescriptor ty = RecordDescriptor
  { recordConstructor :: ConstructorId,
    recordFields :: [Node (Text, Scheme ty)]
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data HoleGoal ty = HoleGoal
  { goalIdentity :: HoleId,
    goalType :: ty,
    goalContext :: [Node (Text, Scheme ty)],
    goalBlockers :: [Node (Text, ty)]
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

data CoreModule ty = CoreModule
  { coreId :: ModuleId,
    coreSpan :: Span,
    coreOrigin :: Provenance,
    coreKinds :: Map GlobalId Kind,
    coreImports :: Map Reference (Scheme ty),
    coreConstructors :: Map ConstructorId (Node (ConstructorDescriptor ty)),
    coreRecords :: Map GlobalId (Node (RecordDescriptor ty)),
    coreDictionaries :: Map GlobalId (Node (DictionaryDescriptor ty)),
    coreBindings :: [BindingGroup ty],
    coreGoals :: Map HoleId (Node (HoleGoal ty))
  }
  deriving (Eq, Show, Functor, Foldable, Traversable)

typeOf :: Expr ty -> ty
typeOf = expressionType . nodeValue

formOf :: Expr ty -> ExprF ty
formOf = expressionForm . nodeValue

binderType :: Binder ty -> ty
binderType b = let (_, _, _, ty) = nodeValue b in ty

binderReference :: Binder ty -> Reference
binderReference b = let (ident, _, _, _) = nodeValue b in LocalRef ident

groupBindings :: BindingGroup ty -> [Binding ty]
groupBindings (NonRecursive b) = [b]
groupBindings (Recursive bs) = foldr (:) [] bs

-- | Shared by acceptance checks and the defensive Runtime boundary. Traverse
-- every body, even unused lets, unselected arms, and delayed lambdas.
expressionHoles :: Expr ty -> [Node (HoleId, ty)]
expressionHoles expression = case formOf expression of
  Hole ident -> [fmap (const (ident, typeOf expression)) expression]
  _ -> concatMap expressionHoles (children expression)

children :: Expr ty -> [Expr ty]
children expression = case formOf expression of
  Var {} -> []
  Literal {} -> []
  Hole {} -> []
  Lambda _ body -> [body]
  Apply f x -> [f, x]
  Let binding body -> [bindingBody (nodeValue binding), body]
  LetRec bindings body -> map (bindingBody . nodeValue) (foldr (:) [] bindings) ++ [body]
  Construct _ _ fields -> fields
  Case receiver alternatives fallback -> receiver : map (snd . nodeValue) alternatives ++ [fallback]
  If arms fallback -> concatMap (\arm -> let (condition, body) = nodeValue arm in [condition, body]) arms ++ maybe [] pure fallback
  SelectField receiver _ -> [receiver]
  Dictionary _ _ supers methods -> supers ++ map (snd . nodeValue) methods
  SelectMethod receiver _ _ _ -> [receiver]
  SelectSuperclass receiver _ _ -> [receiver]
  ScopeTypes _ body -> [body]
  Primitive _ arguments -> arguments
  Fail -> []
