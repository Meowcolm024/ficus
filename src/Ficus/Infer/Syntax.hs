-- | Elaborate resolved type syntax to semantic types. Transparent aliases are
-- expanded before equality, ownership, and implementation-head checks.
module Ficus.Infer.Syntax where

import Control.Monad (forM, unless, void, when)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Ficus.Error.Type qualified as E
import Ficus.Infer.Kind (KindSummary (..))
import Ficus.Infer.Monad hiding (variableKinds)
import Ficus.Infer.Type
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Type
import Ficus.Type.Substitution qualified as S
import Ficus.Util.Source

type TypeScope = Map TypeVarId InferType

data Alias = Alias
  { aliasParameters :: [Quantifier],
    aliasBody :: InferType,
    aliasOrigin :: Span
  }
  deriving (Eq, Show)

data TypeEnvironment = TypeEnvironment
  { typeKinds :: Map GlobalId Kind,
    binderKinds :: Map TypeVarId Kind,
    writtenKinds :: Map NodeId Kind,
    aliases :: Map GlobalId Alias,
    aliasNames :: Set GlobalId
  }
  deriving (Eq, Show)

emptyTypes :: TypeEnvironment
emptyTypes = TypeEnvironment Map.empty Map.empty Map.empty Map.empty Set.empty

withKinds :: KindSummary -> TypeEnvironment -> TypeEnvironment
withKinds summary environment = environment {typeKinds = constructorKinds summary, binderKinds = variableKinds summary, writtenKinds = syntaxKinds summary}

data Signature = Signature
  { signatureScheme :: Scheme InferType,
    signatureHasHoles :: Bool,
    signatureOrigin :: Span
  }
  deriving (Eq, Show)

bindQuantifiers :: TypeEnvironment -> [A.TypeBinder] -> Infer ([Quantifier], TypeScope)
bindQuantifiers environment binders = do
  entries <- forM binders $ \binder -> do
    ident <- BoundId <$> freshId
    let (sourceId, name, _) = A.nodeValue binder
        kind = Map.findWithDefault TypeKind sourceId (binderKinds environment)
        quantifier = Quantifier ident name kind
    pure (quantifier, (sourceId, Variable (Bound ident) kind))
  pure (map fst entries, Map.fromList (map snd entries))

readScheme :: TypeEnvironment -> TypeScope -> Bool -> A.Scheme -> Infer Signature
readScheme environment outer holesAllowed source = do
  let (explicit, implicit, body) = A.nodeValue source
  (explicitBinders, explicitScope) <- bindQuantifiers environment explicit
  (implicitBinders, implicitScope) <- bindQuantifiers environment implicit
  let scope = explicitScope `Map.union` implicitScope `Map.union` outer
  (predicates, ty) <- readQualified environment scope holesAllowed body
  ensureKind (A.nodeSpan body) TypeKind ty
  let scheme = Scheme explicitBinders implicitBinders predicates ty
      ambiguous = Set.unions (map (freeVariables . predicateArgument) predicates) `Set.difference` freeVariables ty
  unless (Set.null ambiguous) (emit (E.diagnostic E.AmbiguousConstraint (A.nodeSpan body) "constraint variables must occur in the value type"))
  pure (Signature scheme (hasHoles body) (A.nodeSpan body))

readQualified :: TypeEnvironment -> TypeScope -> Bool -> A.TypeSyntax -> Infer ([Predicate InferType], InferType)
readQualified environment scope holesAllowed source = case A.nodeValue source of
  A.QualifiedType predicates body -> do
    checked <- mapM (readPredicate environment scope holesAllowed) predicates
    (rest, ty) <- readQualified environment scope holesAllowed body
    pure (checked ++ rest, ty)
  _ -> (,) [] <$> readType environment scope holesAllowed source

readPredicate :: TypeEnvironment -> TypeScope -> Bool -> A.Predicate -> Infer (Predicate InferType)
readPredicate environment scope holesAllowed source = do
  let (trait, argument) = A.nodeValue source
      expected = case Map.lookup trait (typeKinds environment) of Just (KindArrow input TypeKind) -> input; _ -> TypeKind
  ty <- readTypeAt environment scope holesAllowed expected argument
  pure (Predicate trait ty)

readTypeAt :: TypeEnvironment -> TypeScope -> Bool -> Kind -> A.TypeSyntax -> Infer InferType
readTypeAt environment scope holesAllowed expected source = do
  ty <- case A.nodeValue source of
    A.TypeHole _ -> hole holesAllowed expected source
    _ -> readType environment scope holesAllowed source
  ensureKind (A.nodeSpan source) expected ty
  pure ty

readType :: TypeEnvironment -> TypeScope -> Bool -> A.TypeSyntax -> Infer InferType
readType environment scope holesAllowed source = case typeSpine source of
  (base, arguments)
    | A.TypeConstructor ident <- A.nodeValue base,
      Set.member ident (aliasNames environment) ->
        case Map.lookup ident (aliases environment) of
          Nothing -> do
            emit (E.diagnostic E.CyclicAlias (A.nodeSpan base) "alias has no acyclic definition")
            recovery
          Just alias
            | length arguments < length (aliasParameters alias) -> do
                emit (E.diagnostic E.UnsaturatedAlias (A.nodeSpan base) "type aliases must be fully applied")
                recovery
            | otherwise -> do
                let (supplied, remaining) = splitAt (length (aliasParameters alias)) arguments
                types <- sequence (zipWith (\q argument -> readTypeAt environment scope holesAllowed (quantifierKind q) argument) (aliasParameters alias) supplied)
                let expanded = S.apply (binderSubstitution (aliasParameters alias) types) (aliasBody alias)
                rest <- mapM (readType environment scope holesAllowed) remaining
                let result = foldl Application expanded rest
                checkWellKinded (A.nodeSpan source) result
                pure result
  _ -> case A.nodeValue source of
    A.TypeVariable ident -> case Map.lookup ident scope of
      Just ty -> pure ty
      Nothing -> do
        emit (E.diagnostic E.InvalidPatternAnnotation (A.nodeSpan source) "type variable is not scoped by an explicit type binder")
        recovery
    A.TypeConstructor ident -> pure (Constructor ident (case ident of IntrinsicId p -> primitiveKind p; _ -> Map.findWithDefault TypeKind ident (typeKinds environment)))
    A.TypeApplication f x -> do
      constructor <- readType environment scope holesAllowed f
      argument <- case kindOf constructor of
        Right (KindArrow input _) -> readTypeAt environment scope holesAllowed input x
        _ -> readType environment scope holesAllowed x
      let result = Application constructor argument
      checkWellKinded (A.nodeSpan source) result
      pure result
    A.ArrowType a b -> function <$> readTypeAt environment scope holesAllowed TypeKind a <*> readTypeAt environment scope holesAllowed TypeKind b
    A.LazyArrowType a b -> arrow NameArrow <$> readTypeAt environment scope holesAllowed TypeKind a <*> readTypeAt environment scope holesAllowed TypeKind b
    A.QualifiedType _ body -> do
      emit (E.diagnostic E.InvalidAnnotation (A.nodeSpan source) "constraints must occur at the outermost type level")
      readType environment scope holesAllowed body
    A.TypeHole _ -> hole holesAllowed (kindAt environment source) source
  where
    recovery = fresh (A.nodeSpan source) (kindAt environment source)

kindAt :: TypeEnvironment -> A.TypeSyntax -> Kind
kindAt environment source = Map.findWithDefault TypeKind (A.nodeId source) (writtenKinds environment)

hole :: Bool -> Kind -> A.TypeSyntax -> Infer InferType
hole allowed kind source = do
  unless allowed (emit (E.diagnostic E.InvalidTypeHole (A.nodeSpan source) "type holes require a value definition or annotation"))
  fresh (A.nodeSpan source) kind

ensureKind :: Span -> Kind -> InferType -> Infer ()
ensureKind origin expected ty = case kindOf ty of
  Right actual -> when (actual /= expected) (emit (E.diagnostic E.KindMismatch origin ("expected kind " <> renderKind expected <> ", found " <> renderKind actual)))
  Left _ -> emit (E.diagnostic E.KindMismatch origin "ill-kinded type application")

checkWellKinded :: Span -> InferType -> Infer ()
checkWellKinded origin ty = void $ case kindOf ty of
  Right _ -> pure ()
  Left _ -> emit (E.diagnostic E.KindMismatch origin "ill-kinded type application")

typeSpine :: A.TypeSyntax -> (A.TypeSyntax, [A.TypeSyntax])
typeSpine = go []
  where
    go arguments source = case A.nodeValue source of A.TypeApplication f x -> go (x : arguments) f; _ -> (source, arguments)

hasHoles :: A.TypeSyntax -> Bool
hasHoles source = case A.nodeValue source of
  A.TypeHole _ -> True
  A.TypeApplication a b -> hasHoles a || hasHoles b
  A.ArrowType a b -> hasHoles a || hasHoles b
  A.LazyArrowType a b -> hasHoles a || hasHoles b
  A.QualifiedType predicates body -> any (hasHoles . snd . A.nodeValue) predicates || hasHoles body
  _ -> False
