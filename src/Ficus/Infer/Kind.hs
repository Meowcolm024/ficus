-- | Infer declaration and written-type kinds before constructing semantic
-- types. Kind metavariables are local to this pass, never Core variables.
module Ficus.Infer.Kind (KindSummary (..), inferKinds) where

import Control.Monad (forM_, void)
import Control.Monad.State.Strict (State, gets, modify', runState)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Ficus.Builtin.Registry (typeKindFromKey)
import Ficus.Error.Type qualified as E
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Type
import Ficus.Util.Source

newtype KindMetaId = KindMetaId Int deriving (Eq, Ord, Show)

data KindTerm = Star | Arrow KindTerm KindTerm | Meta KindMetaId deriving (Eq, Show)

data KindSummary = KindSummary
  { constructorKinds :: Map GlobalId Kind,
    variableKinds :: Map TypeVarId Kind,
    syntaxKinds :: Map NodeId Kind,
    kindDiagnostics :: [E.Diagnostic]
  }
  deriving (Eq, Show)

data KindState = KindState
  { nextMeta :: Int,
    solutions :: Map KindMetaId KindTerm,
    globals :: Map GlobalId KindTerm,
    variables :: Map TypeVarId KindTerm,
    syntax :: Map NodeId KindTerm,
    origins :: Map KindMetaId Span,
    warnings :: Map KindMetaId Span,
    errors :: [E.Diagnostic]
  }

type KindCheck = State KindState

inferKinds :: Map GlobalId Kind -> A.AbstractModule -> KindSummary
inferKinds imported tree =
  let initial = KindState 0 Map.empty (Map.map liftKind imported) Map.empty Map.empty Map.empty Map.empty []
      action = do
        mapM_ collect (A.declarations (A.abstractDeclarations tree))
        mapM_ declaration (A.declarations (A.abstractDeclarations tree))
        defaultKinds
      (_, final) = runState action initial
      close = lowerKind . resolve final
   in KindSummary (Map.map close (globals final)) (Map.map close (variables final)) (Map.map close (syntax final)) (errors final)

liftKind :: Kind -> KindTerm
liftKind TypeKind = Star
liftKind (KindArrow a b) = Arrow (liftKind a) (liftKind b)

lowerKind :: KindTerm -> Kind
lowerKind Star = TypeKind
lowerKind (Arrow a b) = KindArrow (lowerKind a) (lowerKind b)
lowerKind (Meta _) = TypeKind

fresh :: Span -> Bool -> KindCheck KindTerm
fresh origin warn = do
  ident <- KindMetaId <$> gets nextMeta
  modify' (\s -> s {nextMeta = nextMeta s + 1, origins = Map.insert ident origin (origins s), warnings = if warn then Map.insert ident origin (warnings s) else warnings s})
  pure (Meta ident)

resolve :: KindState -> KindTerm -> KindTerm
resolve state kind = case kind of
  Meta ident -> maybe kind (resolve state) (Map.lookup ident (solutions state))
  Arrow a b -> Arrow (resolve state a) (resolve state b)
  Star -> Star

zonk :: KindTerm -> KindCheck KindTerm
zonk kind = gets (\s -> resolve s kind)

emit :: E.TypeCode -> Span -> Text -> KindCheck ()
emit code origin message = modify' (\s -> s {errors = errors s ++ [E.diagnostic code origin message]})

unify :: Span -> KindTerm -> KindTerm -> KindCheck ()
unify origin left right = do
  a <- zonk left
  b <- zonk right
  case (a, b) of
    _ | a == b -> pure ()
    (Meta ident, term) -> bind ident term
    (term, Meta ident) -> bind ident term
    (Arrow a1 a2, Arrow b1 b2) -> unify origin a1 b1 >> unify origin a2 b2
    _ -> emit E.KindMismatch origin "incompatible type constructor kinds"
  where
    bind ident term
      | occurs ident term = emit E.KindMismatch origin "infinite kind"
      | otherwise = modify' (\s -> s {solutions = Map.insert ident term (solutions s)})
    occurs ident = \case Meta other -> ident == other; Arrow a b -> occurs ident a || occurs ident b; Star -> False

variable :: Span -> TypeVarId -> KindCheck KindTerm
variable origin ident = do
  known <- gets (Map.lookup ident . variables)
  case known of
    Just kind -> pure kind
    Nothing -> do
      kind <- fresh origin False
      modify' (\s -> s {variables = Map.insert ident kind (variables s)})
      pure kind

binder :: A.TypeBinder -> KindCheck KindTerm
binder source = do
  let (ident, _, annotation) = A.nodeValue source
  kind <- variable (A.nodeSpan source) ident
  case annotation of
    Nothing -> case kind of
      Meta meta -> modify' (\s -> s {warnings = Map.insert meta (A.nodeSpan source) (warnings s)})
      _ -> pure ()
    Just written -> kindSyntax written >>= unify (A.nodeSpan written) kind
  pure kind

kindSyntax :: A.KindSyntax -> KindCheck KindTerm
kindSyntax source = case A.nodeValue source of
  A.TypeKindSyntax -> pure Star
  A.KindArrow a b -> Arrow <$> kindSyntax a <*> kindSyntax b
  A.KindVariable ident -> variable (A.nodeSpan source) ident
  A.KindHole _ -> fresh (A.nodeSpan source) True

global :: Span -> GlobalId -> KindCheck KindTerm
global origin ident = case ident of
  IntrinsicId primitiveId -> pure (liftKind (primitiveKind primitiveId))
  _ -> do
    known <- gets (Map.lookup ident . globals)
    case known of
      Just kind -> pure kind
      Nothing -> do
        emit E.KindMismatch origin "missing kind for resolved type constructor"
        fresh origin False

collect :: A.Declaration -> KindCheck ()
collect source = case A.nodeValue source of
  A.AliasDefinition ident parameters annotation _ -> header ident parameters annotation =<< fresh (A.nodeSpan source) False
  A.DataDefinition ident parameters annotation _ -> header ident parameters annotation Star
  A.RecordDefinition ident parameters annotation _ _ _ -> header ident parameters annotation Star
  A.OpaqueBuiltinType ident key annotation -> do
    kind <- kindSyntax annotation
    case typeKindFromKey key of
      Nothing -> emit E.BuiltinContractMismatch (A.nodeSpan annotation) "builtin key has no type contract"
      Just expected -> do
        state <- gets id
        let actual = lowerKind (resolve state kind)
        if actual == expected
          then unify (A.nodeSpan annotation) kind (liftKind expected)
          else emit E.BuiltinContractMismatch (A.nodeSpan annotation) "builtin type has an incompatible kind"
    modify' (\s -> s {globals = Map.insert ident kind (globals s)})
  A.TraitDefinition ident parameter _ _ -> header ident [parameter] Nothing Star
  _ -> pure ()
  where
    header ident parameters annotation result = do
      kinds <- mapM binder parameters
      let kind = foldr Arrow result kinds
      modify' (\s -> s {globals = Map.insert ident kind (globals s)})
      forM_ annotation $ \written -> kindSyntax written >>= unify (A.nodeSpan written) kind

typeSyntax :: A.TypeSyntax -> KindCheck KindTerm
typeSyntax source = do
  kind <- case A.nodeValue source of
    A.TypeVariable ident -> variable (A.nodeSpan source) ident
    A.TypeConstructor ident -> global (A.nodeSpan source) ident
    A.TypeApplication f x -> do
      fk <- typeSyntax f
      xk <- typeSyntax x
      result <- fresh (A.nodeSpan source) False
      unify (A.nodeSpan x) fk (Arrow xk result)
      pure result
    A.ArrowType a b -> ordinary a >> ordinary b >> pure Star
    A.QualifiedType predicates body -> mapM_ predicate predicates >> typeSyntax body
    A.TypeHole _ -> fresh (A.nodeSpan source) False
  modify' (\s -> s {syntax = Map.insert (A.nodeId source) kind (syntax s)})
  pure kind

ordinary :: A.TypeSyntax -> KindCheck ()
ordinary source = typeSyntax source >>= unify (A.nodeSpan source) Star

predicate :: A.Predicate -> KindCheck ()
predicate source = do
  let (trait, argument) = A.nodeValue source
  traitKind <- global (A.nodeSpan source) trait
  argumentKind <- typeSyntax argument
  unify (A.nodeSpan argument) traitKind (Arrow argumentKind Star)

scheme :: A.Scheme -> KindCheck [KindTerm]
scheme source = do
  let (explicit, implicit, body) = A.nodeValue source
  explicitKinds <- mapM binder explicit
  void (mapM binder implicit)
  ordinary body
  pure explicitKinds

declaration :: A.Declaration -> KindCheck ()
declaration source = case A.nodeValue source of
  A.ValueDefinition _ annotation body -> do
    written <- traverse scheme annotation
    case body of
      A.BuiltinBody _ -> pure ()
      A.ClausesBody _ clauses -> forM_ clauses $ \clause -> do
        let value = A.nodeValue clause
        bound <- mapM binder (A.clauseTypes value)
        case written of
          Just expected -> sequence_ (zipWith (unify (A.nodeSpan clause)) expected bound)
          Nothing -> pure ()
        mapM_ patternSyntax (A.clausePatterns value)
        mapM_ declaration (A.declarations (A.clauseWhere value))
        expression (A.clauseBody value)
  A.PatternDefinition pattern' body -> patternSyntax pattern' >> expression body
  A.AliasDefinition ident parameters _ body -> do
    parametersKinds <- mapM binder parameters
    result <- typeSyntax body
    declared <- global (A.nodeSpan source) ident
    unify (A.nodeSpan body) declared (foldr Arrow result parametersKinds)
  A.DataDefinition _ _ _ constructors -> mapM_ (mapM_ ordinary . snd . A.nodeValue) constructors
  A.RecordDefinition _ _ _ _ fields members -> void (mapM binder members) >> mapM_ (ordinary . snd . A.nodeValue) fields
  A.OpaqueBuiltinType {} -> pure ()
  A.TraitDefinition _ _ supers members -> mapM_ predicate supers >> mapM_ declaration members
  A.MethodDefinition _ annotation -> void (scheme annotation)
  A.ImplementationDefinition _ parameters context head' members -> do
    void (mapM binder parameters)
    mapM_ predicate (head' : context)
    mapM_ declaration members

expression :: A.Expr -> KindCheck ()
expression source = case A.nodeValue source of
  A.Ref _ -> pure ()
  A.Constructor _ -> pure ()
  A.Method _ -> pure ()
  A.Literal _ -> pure ()
  A.Hole _ -> pure ()
  A.Apply f x -> expression f >> expression x
  A.TypeApply body arguments -> expression body >> void (mapM (typeSyntax . A.nodeValue) arguments)
  A.Annotated body parameters annotation -> void (mapM binder parameters) >> ordinary annotation >> expression body
  A.Lambda _ body -> expression body
  A.TypeLambda parameters body -> void (mapM binder parameters) >> expression body
  A.Match _ receiver clauses -> expression receiver >> mapM_ (\clause -> let (pattern', guard, body) = A.nodeValue clause in patternSyntax pattern' >> mapM_ expression guard >> expression body) clauses
  A.Conditional clauses -> mapM_ (\clause -> let (condition, body) = A.nodeValue clause in mapM_ expression condition >> expression body) clauses
  A.Sequence statements body -> mapM_ statement statements >> expression body
  A.Where _ bindings body -> mapM_ declaration (A.declarations bindings) >> expression body
  A.Project receiver _ -> expression receiver
  A.PackRecord _ ts fields -> void (mapM (typeSyntax . snd . A.nodeValue) ts) >> mapM_ (expression . snd . A.nodeValue) fields
  A.ConstructRecord _ fields -> mapM_ (expression . snd . A.nodeValue) fields
  A.UpdateRecord receiver fields -> expression receiver >> mapM_ (expression . snd . A.nodeValue) fields
  A.Product components -> mapM_ expression components
  A.List components -> mapM_ expression components
  A.Unit -> pure ()
  A.Negate body -> expression body
  where
    statement sourceStatement = case A.nodeValue sourceStatement of A.Effect body -> expression body; A.BindStatement bindings -> mapM_ declaration (A.declarations bindings)

patternSyntax :: A.Pattern -> KindCheck ()
patternSyntax source = case A.nodeValue source of
  A.AnnotatedPattern body annotation -> ordinary annotation >> patternSyntax body
  A.OpenPattern witnesses body -> void (mapM (binder . snd) witnesses) >> patternSyntax body
  A.ConstructorPattern _ patterns -> mapM_ patternSyntax patterns
  A.ProductPattern patterns -> mapM_ patternSyntax patterns
  A.ListPattern patterns -> mapM_ patternSyntax patterns
  A.NegatedPattern body -> patternSyntax body
  _ -> pure ()

defaultKinds :: KindCheck ()
defaultKinds = do
  allocated <- gets origins
  requested <- gets warnings
  unresolved <- mapM (\(ident, origin) -> (,) origin <$> zonk (Meta ident)) (Map.toAscList allocated)
  warningRoots <- mapM (\(ident, origin) -> (,) origin <$> zonk (Meta ident)) (Map.toAscList requested)
  let pending = Set.unions [freeMetas kind | (_, kind) <- unresolved]
      sites = Map.fromListWith min [(ident, origin) | (origin, kind) <- warningRoots, ident <- Set.toList (freeMetas kind)]
  forM_ (Set.toAscList pending) $ \ident -> do
    modify' (\s -> s {solutions = Map.insert ident Star (solutions s)})
    forM_ (Map.lookup ident sites) $ \origin -> emit E.KindDefaulting origin "unconstrained kind defaults to Type"
  where
    freeMetas = \case Meta ident -> Set.singleton ident; Arrow a b -> freeMetas a `Set.union` freeMetas b; Star -> Set.empty
