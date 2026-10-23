module Ficus.Infer.Monad where

import Control.Monad (unless)
import Control.Monad.State.Strict (State, gets, modify', runState)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.CompilationConfig
import Ficus.Error.Diagnostic qualified as D
import Ficus.Error.Type qualified as E
import Ficus.Infer.Type
import Ficus.Infer.Unify qualified as U
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Type
import Ficus.Type.Substitution (Substitution)
import Ficus.Type.Substitution qualified as S
import Ficus.Util.Source

data MetaInfo = MetaInfo {metaKind :: Kind, metaOrigin :: Span} deriving (Eq, Show)

data WeakReason = ValueRestriction | MonomorphismRestriction | PendingField | PendingNegation deriving (Eq, Show)

data WeakVariable = WeakVariable {weakType :: InferType, weakOrigin :: Span, weakReason :: WeakReason} deriving (Eq, Show)

data Wanted = Wanted {wantedNode :: NodeId, wantedOrigin :: Span, wantedPredicate :: Predicate InferType} deriving (Eq, Show)

data FieldWanted = FieldWanted
  { fieldNode :: NodeId,
    fieldOrigin :: Span,
    fieldSite :: Span,
    fieldValueOrigin :: Span,
    fieldReceiver :: InferType,
    fieldName :: Text,
    fieldResult :: InferType,
    fieldIsUpdate :: Bool
  }
  deriving (Eq, Show)

data InferState = InferState
  { compilationConfig :: CompilationConfig,
    nextVariable :: Int,
    substitution :: Substitution InferVariable,
    metavariables :: Map MetaId MetaInfo,
    weakVariables :: [WeakVariable],
    diagnostics :: [E.Diagnostic],
    checkedNodeTypes :: Map NodeId InferType,
    checkedInstantiations :: Map NodeId [InferType],
    checkedBindingSchemes :: Map Reference (Scheme InferType),
    checkedDeclarations :: Map NodeId (Scheme InferType),
    bindingSubstitutions :: Map NodeId (Substitution InferVariable),
    expressionSubstitutions :: Map NodeId (Substitution InferVariable),
    bindingWanteds :: Map NodeId [Wanted],
    checkedGoals :: Map HoleId (C.Node (C.HoleGoal InferType)),
    pendingFields :: [FieldWanted],
    checkedFields :: Map NodeId C.FieldId,
    openedWitnesses :: Map NodeId [InferType],
    checkedEvidence :: [(Wanted, Evidence)],
    pendingNegations :: Map NodeId (C.Node InferType)
  }
  deriving (Eq, Show)

newtype Infer a = Infer {unInfer :: State InferState a}
  deriving newtype (Functor, Applicative, Monad)

initialState :: InferState
initialState =
  InferState
    { compilationConfig = defaultCompilationConfig,
      nextVariable = 0,
      substitution = S.empty,
      metavariables = Map.empty,
      weakVariables = [],
      diagnostics = [],
      checkedNodeTypes = Map.empty,
      checkedInstantiations = Map.empty,
      checkedBindingSchemes = Map.empty,
      checkedDeclarations = Map.empty,
      bindingSubstitutions = Map.empty,
      expressionSubstitutions = Map.empty,
      bindingWanteds = Map.empty,
      checkedGoals = Map.empty,
      pendingFields = [],
      checkedFields = Map.empty,
      openedWitnesses = Map.empty,
      checkedEvidence = [],
      pendingNegations = Map.empty
    }

runInfer :: Infer a -> (a, InferState)
runInfer action = runState (unInfer action) initialState

runInferFrom :: InferState -> Infer a -> (a, InferState)
runInferFrom state action = runState (unInfer action) state

freshId :: Infer Int
freshId = Infer $ do
  n <- gets nextVariable
  modify' (\s -> s {nextVariable = n + 1})
  pure n

fresh :: Span -> Kind -> Infer InferType
fresh origin kind = do
  ident <- MetaId <$> freshId
  Infer (modify' (\s -> s {metavariables = Map.insert ident (MetaInfo kind origin) (metavariables s)}))
  pure (Variable (Meta ident) kind)

freshSkolem :: Kind -> Infer InferType
freshSkolem kind = do
  ident <- SkolemId <$> freshId
  pure (Variable (Skolem ident) kind)

zonk :: InferType -> Infer InferType
zonk ty = Infer (gets (\s -> S.apply (substitution s) ty))

zonkScheme :: Scheme InferType -> Infer (Scheme InferType)
zonkScheme = traverse zonk

emit :: E.Diagnostic -> Infer ()
emit d = Infer $ do
  config <- gets compilationConfig
  let configured =
        if rejectNonExhaustivePatterns config && E.diagnosticCode d == E.NonExhaustiveMatch
          then d {E.diagnosticSeverity = D.Error}
          else d
  modify' (\s -> s {diagnostics = diagnostics s ++ [configured]})

equate :: Span -> InferType -> InferType -> Infer Bool
equate = equateWith E.TypeMismatch

equateWith :: E.TypeCode -> Span -> InferType -> InferType -> Infer Bool
equateWith mismatchCode origin left right = do
  a <- zonk left
  b <- zonk right
  case U.unify a b of
    Right next -> do
      Infer (modify' (\s -> s {substitution = S.compose next (substitution s)}))
      pure True
    Left problem -> do
      let (code, message) = case problem of
            U.TypesDiffer x y -> (mismatchCode, "expected " <> renderInferType x <> ", found " <> renderInferType y)
            U.InfiniteType _ t -> (E.InfiniteType, "infinite type involving " <> renderInferType t)
            U.KindsDiffer k -> (E.KindMismatch, "incompatible kinds: " <> T.pack (show k))
      emit (E.diagnostic code origin message)
      pure False

-- | All quantifiers are fresh on every use, including omitted explicit ones.
-- The argument list is also retained for Core's explicit instantiations.
instantiate :: Span -> Scheme InferType -> Infer (InferType, [Predicate InferType], [InferType])
instantiate origin scheme = do
  arguments <- mapM (fresh origin . quantifierKind) (quantifiers scheme)
  let mapping = binderSubstitution (quantifiers scheme) arguments
  pure (S.apply mapping (schemeType scheme), map (fmap (S.apply mapping)) (schemePredicates scheme), arguments)

skolemize :: Scheme InferType -> Infer (InferType, [Predicate InferType], [InferType])
skolemize scheme = do
  arguments <- mapM (freshSkolem . quantifierKind) (quantifiers scheme)
  let mapping = binderSubstitution (quantifiers scheme) arguments
  pure (S.apply mapping (schemeType scheme), map (fmap (S.apply mapping)) (schemePredicates scheme), arguments)

binderSubstitution :: [Quantifier] -> [InferType] -> Substitution InferVariable
binderSubstitution qs ts = foldr (S.compose . uncurry S.singleton) S.empty [(Bound (quantifierId q), t) | (q, t) <- zip qs ts]

freeSchemeVariables :: Scheme InferType -> Set InferVariable
freeSchemeVariables scheme =
  Set.unions (map freeVariables (schemeType scheme : map predicateArgument (schemePredicates scheme)))
    `Set.difference` Set.fromList (map (Bound . quantifierId) (quantifiers scheme))

-- | Track roots, not just a set of currently weak IDs: later substitutions can
-- expand a weak variable to a type containing fresh variables.
markWeak :: Span -> WeakReason -> InferType -> Infer ()
markWeak origin reason ty = Infer (modify' (\s -> s {weakVariables = weakVariables s ++ [WeakVariable ty origin reason]}))

weakMetas :: Infer (Set InferVariable)
weakMetas = do
  roots <- Infer (gets weakVariables)
  Set.unions . map freeVariables <$> mapM (zonk . weakType) roots

-- | Generalize only variables absent from the zonked outer environment and
-- from every reachable weak root. Predicate policy is applied by the caller.
generalize :: Span -> Bool -> [Scheme InferType] -> [Predicate InferType] -> InferType -> Infer (Scheme InferType)
generalize origin eligible environment predicates ty = fst <$> generalizeWithMapping origin eligible environment predicates ty

generalizeWithMapping :: Span -> Bool -> [Scheme InferType] -> [Predicate InferType] -> InferType -> Infer (Scheme InferType, Substitution InferVariable)
generalizeWithMapping origin eligible environment predicates ty = do
  resolved <- zonk ty
  constraints <- traverse (traverse zonk) predicates
  outer <- Set.unions . map freeSchemeVariables <$> mapM zonkScheme environment
  weak <- weakMetas
  let available = Set.unions (map freeVariables (resolved : map predicateArgument constraints)) `Set.difference` outer
      candidates = Set.filter isMeta (available `Set.difference` weak)
      kinds = variableKinds (resolved : map predicateArgument constraints)
  if eligible
    then do
      pairs <- mapM (quantify kinds) (Set.toAscList candidates)
      let mapping = foldr (S.compose . uncurry S.singleton) S.empty [(v, Variable (Bound (quantifierId q)) (quantifierKind q)) | (v, q) <- pairs]
      pure (Scheme [] (map snd pairs) (map (fmap (S.apply mapping)) constraints) (S.apply mapping resolved), mapping)
    else do
      mapM_ (\v -> case Map.lookup v kinds of Just k -> markWeak origin ValueRestriction (Variable v k); Nothing -> pure ()) (Set.toList available)
      pure (Scheme [] [] constraints resolved, S.empty)
  where
    isMeta (Meta _) = True
    isMeta _ = False
    quantify kinds v = do
      n <- freshId
      pure (v, Quantifier (BoundId n) ("a" <> T.pack (show n)) (Map.findWithDefault TypeKind v kinds))

variableKinds :: [InferType] -> Map InferVariable Kind
variableKinds = Map.unions . map collect
  where
    collect (Variable v k) = Map.singleton v k
    collect (Constructor _ _) = Map.empty
    collect (Application a b) = collect a `Map.union` collect b

finishWeakVariables :: Infer ()
finishWeakVariables = do
  roots <- Infer (gets weakVariables)
  _ <- foldl check (pure Set.empty) roots
  pure ()
  where
    check action weak = do
      reported <- action
      resolved <- zonk (weakType weak)
      let remaining = Set.filter isMeta (freeVariables resolved) `Set.difference` reported
      if Set.null remaining
        then pure reported
        else do
          alreadyReported <- Infer (gets (any (\d -> E.diagnosticCode d == E.UnresolvedWeakType && E.diagnosticSpan d == weakOrigin weak) . diagnostics))
          unless alreadyReported (emit (E.diagnostic E.UnresolvedWeakType (weakOrigin weak) ("unresolved monomorphic type " <> renderInferType resolved <> reasonText (weakReason weak))))
          pure (reported `Set.union` remaining)
    isMeta (Meta _) = True
    isMeta _ = False
    reasonText :: WeakReason -> Text
    reasonText ValueRestriction = " (value restriction)"
    reasonText MonomorphismRestriction = " (monomorphism restriction)"
    reasonText PendingField = " (record receiver is unknown)"
    reasonText PendingNegation = " (negation operand is unknown)"
