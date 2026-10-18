-- | Pure Concrete-to-Abstract conversion. File lookup and graph traversal are
-- deliberately absent. Reader carries lexical scope, State owns fresh IDs and
-- diagnostics, and Except aborts only the current independently recoverable item.
module Ficus.Resolve.Desugar (ResolveConfig (..), Resolution (..), resolveModule) where

import Control.Monad (foldM, forM, forM_, unless, when)
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.List (nub, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Desugar.Registry
import Ficus.Error.Resolve
import Ficus.Resolve.Header
import Ficus.Resolve.Pragma
import Ficus.Resolve.Scope
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Abstract.Validate (validateAbstract)
import Ficus.Syntax.Concrete qualified as C
import Ficus.Syntax.Literal qualified as L
import Ficus.Syntax.Name
import Ficus.Util.Source

-- Contracts are injected: builtin availability and sugar ownership are library
-- choices, not hardcoded file paths or ordinary spelling lookups at a use site.
newtype ResolveConfig = ResolveConfig {builtinKeys :: Set Text} deriving (Eq, Show)

data Resolution = Resolution {resolvedModule :: Maybe A.AbstractModule, resolvedInterface :: Interface, resolutionDiagnostics :: [Diagnostic]} deriving (Eq, Show)

data Env = Env
  { envHeader :: Header,
    envScope :: Scope,
    envOwn :: A.NameSummary,
    envValues :: Map Text Reference,
    envTypes :: Map Text TypeVarId,
    envConfig :: ResolveConfig,
    envSugar :: SugarRegistry
  }

data ResolveState = ResolveState
  { fresh :: Int,
    messages :: [Diagnostic],
    occurrences :: [A.Occurrence],
    associations :: Map Text GlobalId,
    implementations :: [ImplementationId]
  }

type Resolve = ExceptT () (ReaderT Env (State ResolveState))

resolveModule :: ResolveConfig -> SugarRegistry -> Header -> C.ConcreteModule -> Map ModuleId Interface -> Resolution
resolveModule config registry header input interfaces =
  let (own, nameErrors) = collectNames (headerId header) input
      (scope, exports, importErrors) = buildScope header input own interfaces
      env = Env header scope own Map.empty Map.empty config registry
      (_, headerErrors) = scanHeader (headerId header) input
      initial = ResolveState 0 (reverse (headerErrors ++ nameErrors ++ importErrors)) [] Map.empty []
      action = do
        collectBuiltins (C.modulePragmas input ++ [p | C.Located _ _ (C.PragmaDeclaration p) <- C.moduleDeclarations input])
        group <- declarations True (C.moduleDeclarations input)
        pure group
      (result, final) = runState (runReaderT (runExceptT action) env) initial
      ds = sortOn (\d -> (primarySpan d, renderResolveCode (diagnosticCode d))) (reverse (messages final))
      entities = Map.unions (Map.fromList [(A.entityId e, e) | e <- Map.elems own] : map allEntities (Map.elems interfaces))
      visible = nub (implementations final ++ concatMap interfaceImplementations (Map.elems interfaces))
      fields = Map.unions (collectFields (headerId header) input : map interfaceFields (Map.elems interfaces))
      iface = Interface exports entities visible fields (associations final)
      candidate = case result of
        Right group | not (any ((== Error) . severity) ds) -> Just (A.AbstractModule (headerId header) (C.moduleLocation input) (C.moduleOrigin input) (headerOptions header) (headerPrelude header) group exports entities fields visible (reverse (occurrences final)) (associations final))
        _ -> Nothing
      (tree, boundaryErrors) = case candidate of
        Just m -> case validateAbstract m of
          Right () -> (Just m, [])
          Left message -> (Nothing, [diagnostic InvalidAbstractTree (A.abstractSpan m) message])
        Nothing -> (Nothing, [])
   in Resolution tree iface (ds ++ boundaryErrors)

newId :: Resolve Int
newId = do
  n <- gets fresh
  modify' (\s -> s {fresh = n + 1})
  pure n

node :: Span -> Provenance -> a -> Resolve (A.Node a)
node s o a = do n <- newId; pure (A.Node (NodeId n) s o a)

sourceNode :: C.Located b -> a -> Resolve (A.Node a)
sourceNode c = node (C.location c) (C.origin c)

generated :: Text -> Span -> a -> Resolve (A.Node a)
generated tag s = node s (GeneratedOrigin tag s)

nameNode :: C.Name -> a -> Resolve (A.Node a)
nameNode n = node (C.nameLocation n) (C.nameOrigin n)

emit :: Diagnostic -> Resolve ()
emit d = do
  n <- newId
  modify' (\s -> s {messages = d {diagnosticId = n} : messages s})

failAt :: ResolveCode -> Span -> Text -> Resolve a
failAt code s msg = emit (diagnostic code s msg) >> throwError ()

recover :: Resolve a -> Resolve (Maybe a)
recover action = (Just <$> action) `catchError` const (pure Nothing)

requireName :: C.Name -> Resolve ()
requireName n = when (C.nameText n == "_") (failAt ReservedName (C.nameLocation n) "_ is a wildcard or hole, not a name")

recordOccurrence :: C.Name -> Reference -> [Span] -> Resolve ()
recordOccurrence n ref routes = modify' (\s -> s {occurrences = A.Occurrence (C.nameLocation n) (C.nameText n) ref routes : occurrences s})

lookupEntity :: Namespace -> C.Name -> Resolve A.Entity
lookupEntity ns n = do
  requireName n
  env <- ask
  let key = (ns, C.nameText n)
      intrinsic = [A.Entity gid role (C.nameLocation n) Nothing | (space, txt, gid, role) <- primitiveNames, space == ns, txt == C.nameText n]
  case intrinsic of
    e : _ -> recordOccurrence n (GlobalRef (A.entityId e)) [] >> pure e
    [] -> case Map.lookup key (envOwn env) of
      Just e -> recordOccurrence n (GlobalRef (A.entityId e)) [] >> pure e
      Nothing -> demand ns n (Map.findWithDefault [] key (openedNames (envScope env)))

demand :: Namespace -> C.Name -> [Candidate] -> Resolve A.Entity
demand _ n candidates = case candidates of
  [Candidate e routes] -> recordOccurrence n (GlobalRef (A.entityId e)) routes >> pure e
  [] -> failAt UnresolvedName (C.nameLocation n) ("unresolved name: " <> C.nameText n)
  _ -> do
    emit ((diagnostic AmbiguousName (C.nameLocation n) "ambiguous imported name") {relatedSpans = concat [[(A.entitySpan e, "candidate declaration")] ++ [(s, "import route") | s <- routes] | Candidate e routes <- candidates]})
    throwError ()

valueRef :: C.Name -> Resolve A.Expr
valueRef n = do
  requireName n
  locals <- asks envValues
  case Map.lookup (C.nameText n) locals of
    Just ref -> recordOccurrence n ref [] >> nameNode n (A.Ref ref)
    Nothing -> do
      e <- lookupEntity (if C.nameSpace n == C.UpperName then ConstructorNS else ValueNS) n
      nameNode n (entityExpr e)
  where
    entityExpr e = case A.entityRole e of
      ConstructorRole -> A.Constructor (A.entityId e)
      RecordConstructorRole -> A.Constructor (A.entityId e)
      MethodRole -> A.Method (A.entityId e)
      _ -> A.Ref (GlobalRef (A.entityId e))

-- Resolve the entire module prefix once. No constructor-projection fallback.
qualified :: Namespace -> [C.Name] -> C.Name -> Resolve A.Entity
qualified ns prefix terminal = do
  requireName terminal
  scope <- asks envScope
  let path = map C.nameText prefix
  case Map.findWithDefault [] path (moduleQualifiers scope) of
    [] -> failAt ModuleNotFound (pathSpan prefix (C.nameLocation terminal)) "module qualifier is not in scope"
    routes -> do
      let found = [(entity, route) | (owner, route) <- routes, Just iface <- [Map.lookup owner (scopeInterfaces scope)], Just entity <- [Map.lookup (ns, C.nameText terminal) (publicNames iface)]]
          candidates = Map.findWithDefault [] (ns, C.nameText terminal) (foldl (\table (entity, route) -> insertCandidate (ns, C.nameText terminal) (Candidate entity [route]) table) Map.empty found)
      case candidates of
        [] -> failAt MissingExport (C.nameLocation terminal) "qualifier has no such public export"
        _ -> demand ns terminal candidates

pathSpan :: [C.Name] -> Span -> Span
pathSpan [] fallback = fallback
pathSpan (n : ns) _ = foldl (\s x -> s {end = end (C.nameLocation x)}) (C.nameLocation n) ns

freshBinder :: Span -> Text -> Resolve A.Binder
freshBinder s spelling = do
  i <- newId
  generated "binder" s (LocalId i, spelling)

patternNames :: C.Pattern -> [C.Name]
patternNames p = case C.concrete p of
  C.IdentP n | C.nameSpace n == C.LowerName && C.nameText n /= "_" -> [n]
  C.ConstructorP f xs -> concatMap patternNames (f : xs)
  C.OpAppP a _ b -> patternNames a ++ patternNames b
  C.ParenP a -> patternNames a
  C.AnnotatedP a _ -> patternNames a
  C.ProductP xs -> concatMap patternNames xs
  C.ListP xs -> concatMap patternNames xs
  C.NegateP a -> patternNames a
  _ -> []

bindPatterns :: [C.Pattern] -> Resolve (Map Text Reference, [A.Pattern])
bindPatterns ps = do
  bindings <- foldM bind Map.empty (concatMap patternNames ps)
  resolved <- local (\e -> e {envValues = bindings `Map.union` envValues e}) (mapM patternNode ps)
  pure (bindings, resolved)
  where
    bind table n = case Map.lookup (C.nameText n) table of
      Just _ -> failAt DuplicatePatternBinder (C.nameLocation n) "duplicate pattern binder"
      Nothing -> do
        i <- newId
        let ref = LocalRef (LocalId i)
        recordOccurrence n ref []
        pure (Map.insert (C.nameText n) ref table)

patternNode :: C.Pattern -> Resolve A.Pattern
patternNode p =
  sourceNode p =<< case C.concrete p of
    C.IdentP n
      | C.nameText n == "_" -> pure A.Wildcard
      | C.nameSpace n == C.LowerName -> do
          values <- asks envValues
          case Map.lookup (C.nameText n) values of
            Just (LocalRef i) -> A.Bind <$> nameNode n (i, C.nameText n)
            _ -> failAt InvalidAbstractTree (C.nameLocation n) "pattern binder was not allocated"
      | otherwise -> do e <- lookupEntity ConstructorNS n; pure (A.ConstructorPattern (A.entityId e) [])
    C.DottedP names -> case reverse names of
      n : rest -> do e <- qualified ConstructorNS (reverse rest) n; pure (A.ConstructorPattern (A.entityId e) [])
      [] -> failAt InvalidAbstractTree (C.location p) "empty constructor path"
    C.ConstructorP f xs -> do
      ctor <- patternNode f
      args <- mapM patternNode xs
      case A.nodeValue ctor of
        A.ConstructorPattern gid before -> pure (A.ConstructorPattern gid (before ++ args))
        _ -> failAt WrongNamespace (C.location f) "expected constructor pattern"
    C.OpAppP a n b -> do e <- lookupEntity ConstructorNS n; A.ConstructorPattern (A.entityId e) <$> mapM patternNode [a, b]
    C.ParenP q -> A.nodeValue <$> patternNode q
    C.AnnotatedP q t -> A.AnnotatedPattern <$> patternNode q <*> typeNode False t
    C.LitP l -> A.LiteralPattern <$> plainLiteral l
    C.NegateP q -> A.NegatedPattern <$> patternNode q
    C.UnitP -> pure A.UnitPattern
    C.ProductP xs -> A.ProductPattern <$> mapM patternNode xs
    C.ListP xs -> A.ListPattern <$> mapM patternNode xs

withTypes :: [C.TypeBinder] -> Resolve a -> Resolve ([A.TypeBinder], a)
withTypes bs action = do
  (table, binders) <- foldM add (Map.empty, []) bs
  result <- local (\e -> e {envTypes = table `Map.union` envTypes e}) action
  pure (binders, result)
  where
    add (table, binders) b = case C.concrete b of
      C.TypeBinder n annotation -> do
        requireName n
        when (Map.member (C.nameText n) table) (failAt DuplicatePatternBinder (C.nameLocation n) "repeated type binder")
        i <- TypeVarId <$> newId
        k <- traverse kindNode annotation
        binder <- sourceNode b (i, C.nameText n, k)
        pure (Map.insert (C.nameText n) i table, binders ++ [binder])

kindNode :: C.KindExpr -> Resolve A.KindSyntax
kindNode k =
  sourceNode k =<< case C.concrete k of
    C.IdentK n | C.nameText n == "_" -> A.KindHole . HoleId <$> newId
    C.IdentK n | C.nameText n == "Type" -> pure A.TypeKindSyntax
    C.IdentK n -> do
      variables <- asks envTypes
      case Map.lookup (C.nameText n) variables of
        Just i -> pure (A.KindVariable i)
        Nothing -> failAt UnresolvedName (C.nameLocation n) "unknown kind"
    C.ArrowK a b -> A.KindArrow <$> kindNode a <*> kindNode b
    C.ParenK a -> A.nodeValue <$> kindNode a
    C.DottedK _ -> failAt WrongNamespace (C.location k) "qualified kind is not a kind declaration"

typeNode :: Bool -> C.TypeExpr -> Resolve A.TypeSyntax
typeNode implicit t =
  sourceNode t =<< case C.concrete t of
    C.IdentT n | C.nameText n == "_" -> A.TypeHole . HoleId <$> newId
    C.IdentT n | C.nameSpace n == C.LowerName -> do
      variables <- asks envTypes
      case Map.lookup (C.nameText n) variables of
        Just i -> pure (A.TypeVariable i)
        Nothing -> failAt (if implicit then UnresolvedName else InvalidTypeVariableScope) (C.nameLocation n) "type variable is not in scope"
    C.IdentT n -> A.TypeConstructor . A.entityId <$> lookupEntity TypeNS n
    C.DottedT names -> case reverse names of
      n : rest -> A.TypeConstructor . A.entityId <$> qualified TypeNS (reverse rest) n
      [] -> failAt InvalidAbstractTree (C.location t) "empty type path"
    C.AppT a b -> A.TypeApplication <$> typeNode implicit a <*> typeNode implicit b
    C.OpAppT a op b -> do
      e <- lookupEntity TypeNS op
      f <- nameNode op (A.TypeConstructor (A.entityId e))
      x <- typeNode implicit a
      fx <- sourceNode t (A.TypeApplication f x)
      A.TypeApplication fx <$> typeNode implicit b
    C.ArrowT a b -> A.ArrowType <$> typeNode implicit a <*> typeNode implicit b
    C.ProductT a b -> intrinsicApplication ProductType [a, b]
    C.ListT a -> intrinsicApplication ListType [a]
    C.ConstrainedT cs body -> A.QualifiedType <$> mapM (predicate implicit) cs <*> typeNode implicit body
    C.ParenT a -> A.nodeValue <$> typeNode implicit a
    C.ListConstructor -> pure (A.TypeConstructor (IntrinsicId ListType))
    C.ProductConstructor -> pure (A.TypeConstructor (IntrinsicId ProductType))
    C.FunctionConstructor -> pure (A.TypeConstructor (IntrinsicId FunctionType))
  where
    intrinsicApplication key args = do
      f <- generated "type constructor" (C.location t) (A.TypeConstructor (IntrinsicId key))
      result <- foldM (\a b -> do x <- typeNode implicit b; sourceNode t (A.TypeApplication a x)) f args
      pure (A.nodeValue result)

predicate :: Bool -> C.Constraint -> Resolve A.Predicate
predicate implicit c = case C.concrete c of
  C.Constraint n t -> do
    e <- lookupEntity TypeNS n
    unless (A.entityRole e == TraitRole) (failAt WrongNamespace (C.nameLocation n) "expected trait")
    value <- typeNode implicit t
    sourceNode c (A.entityId e, value)

freeTypes :: C.TypeExpr -> [C.Name]
freeTypes t = case C.concrete t of
  C.IdentT n | C.nameSpace n == C.LowerName && C.nameText n /= "_" -> [n]
  C.AppT a b -> freeTypes a ++ freeTypes b
  C.OpAppT a _ b -> freeTypes a ++ freeTypes b
  C.ArrowT a b -> freeTypes a ++ freeTypes b
  C.ProductT a b -> freeTypes a ++ freeTypes b
  C.ConstrainedT cs a -> concat [freeTypes x | C.Located _ _ (C.Constraint _ x) <- cs] ++ freeTypes a
  C.ParenT a -> freeTypes a
  C.ListT a -> freeTypes a
  _ -> []

implicitTypes :: [C.Name] -> Resolve a -> Resolve ([A.TypeBinder], a)
implicitTypes names action = do
  existing <- asks envTypes
  let unique = Map.elems (Map.fromListWith (\_ old -> old) [(C.nameText n, n) | n <- names, Map.notMember (C.nameText n) existing])
  withTypes [C.at (C.nameLocation n) (C.TypeBinder n Nothing) | n <- unique] action

scheme :: C.SignatureType -> Resolve A.Scheme
scheme s = case C.concrete s of
  C.SignatureType qs t -> do
    let explicit = [C.Located (C.location q) (C.origin q) (C.TypeBinder n k) | q@(C.Located _ _ (C.Quantifier n k)) <- qs]
    (eb, (ib, body)) <- withTypes explicit (implicitTypes (freeTypes t) (typeNode True t))
    sourceNode s (eb, ib, body)

expr :: C.Expr -> Resolve A.Expr
expr e = case C.concrete e of
  C.Ident n | C.nameText n == "_" -> sourceNode e . A.Hole . HoleId =<< newId
  C.Ident n -> valueRef n
  C.Lit (C.StringLiteralText raw) -> stringExpr e raw
  C.Lit l -> sourceNode e . A.Literal =<< plainLiteral l
  C.App f x -> do a <- expr f; b <- expr x; sourceNode e (A.Apply a b)
  C.StaticApp f ts -> do
    a <- expr f
    args <- forM ts $ \argument -> case C.concrete argument of
      C.TypeArgument t -> sourceNode argument =<< typeNode False t
    sourceNode e (A.TypeApply a args)
  C.OpApp a op b -> do
    f <- valueRef op
    x <- expr a
    y <- expr b
    fx <- generated "operator application" (C.location e) (A.Apply f x)
    sourceNode e (A.Apply fx y)
  C.Negate a -> sourceNode e . A.Negate =<< expr a
  C.Lam bs ps body -> do
    (types, (patterns, result)) <- withTypes bs $ do
      (bindings, patterns) <- bindPatterns ps
      result <- local (\env -> env {envValues = bindings `Map.union` envValues env}) (expr body)
      pure (patterns, result)
    value <- foldM (\body' pat -> normalizeLambda A.WarningCoverage pat body') result (reverse patterns)
    sourceNode e (if null types then A.nodeValue value else A.TypeLambda types value)
  C.If b -> sourceNode e . A.Conditional =<< mapM ifClause (C.blockItems b)
  C.With scrutinee b -> do
    value <- expr scrutinee
    clauses <- mapM matchClause (C.blockItems b)
    sourceNode e (A.Match A.WarningCoverage value clauses)
  C.Do b -> do
    requirePrelude (keywordSpan e "do")
    doExpr e (C.blockItems b)
  C.ExprBlock b -> sequential e (C.blockItems b)
  C.RecordWith base b -> do
    receiver <- expr base
    fields <- mapM field (C.blockItems b)
    env <- ask
    let entities = Map.unions (Map.fromList [(A.entityId x, x) | x <- Map.elems (envOwn env)] : map allEntities (Map.elems (scopeInterfaces (envScope env))))
        result = case A.nodeValue receiver of
          A.Constructor gid | Just entity <- Map.lookup gid entities, A.entityRole entity == RecordConstructorRole -> A.ConstructRecord gid fields
          _ -> A.UpdateRecord receiver fields
    sourceNode e result
  C.Dotted base names -> dottedExpr e base names
  C.Paren a -> expr a
  C.Annotated a t -> do
    -- Expression annotations have signature-local implicit variables.
    (ib, annotation) <- implicitTypes (freeTypes t) (typeNode True t)
    value <- expr a
    sourceNode e (A.Annotated value ib annotation)
  C.Unit -> sourceNode e A.Unit
  C.Product xs -> sourceNode e . A.Product =<< mapM expr xs
  C.List xs -> sourceNode e . A.List =<< mapM expr xs
  where
    ifClause clause = case C.concrete clause of
      C.IfClause condition body -> do
        test <- case C.concrete condition of C.Ident n | C.nameText n == "_" -> pure Nothing; _ -> Just <$> expr condition
        result <- expr body
        sourceNode clause (test, result)
    matchClause clause = case C.concrete clause of
      C.MatchClause p guard body -> do
        (bindings, patterns) <- bindPatterns [p]
        local (\env -> env {envValues = bindings `Map.union` envValues env}) $ do
          g <- traverse expr guard
          result <- expr body
          case patterns of
            [pat] -> sourceNode clause (pat, g, result)
            _ -> failAt InvalidAbstractTree (C.location clause) "missing match pattern"
    field f = case C.concrete f of
      C.Field n rhs w -> do
        requireName n
        result <- withWhere 0 w (expr rhs)
        sourceNode f (C.nameText n, result)

keywordSpan :: C.Expr -> Text -> Span
keywordSpan e keyword = let s = C.location e; p = start s in s {end = p {column = column p + T.length keyword - 1, offset = offset p + T.length keyword - 1}}

normalizeLambda :: A.Coverage -> A.Pattern -> A.Expr -> Resolve A.Expr
normalizeLambda coverage p body = do
  let s = A.nodeSpan p
  binder <- case A.nodeValue p of A.Bind b -> pure b; _ -> freshBinder s "$argument"
  result <- case A.nodeValue p of
    A.Bind _ | coverage == A.WarningCoverage -> pure body
    A.Wildcard | coverage == A.WarningCoverage -> pure body
    _ -> do
      receiver <- generated "lambda parameter" s (A.Ref (LocalRef (fst (A.nodeValue binder))))
      clause <- generated "lambda parameter" s (p, Nothing, body)
      generated "lambda pattern match" s (A.Match coverage receiver [clause])
  generated "lambda parameter" s (A.Lambda binder result)

dottedExpr :: C.Expr -> C.Expr -> [C.Name] -> Resolve A.Expr
dottedExpr whole base names = case C.concrete base of
  C.Ident n | C.nameSpace n == C.UpperName -> do
    let chain = n : names
        (prefix, lower) = span ((== C.UpperName) . C.nameSpace) chain
    case lower of
      terminal : fields -> do
        entity <- qualified ValueNS prefix terminal
        value <- nameNode terminal (if A.entityRole entity == MethodRole then A.Method (A.entityId entity) else A.Ref (GlobalRef (A.entityId entity)))
        foldM project value fields
      [] -> case reverse prefix of
        terminal : rest -> do
          entity <- qualified ConstructorNS (reverse rest) terminal
          sourceNode whole (A.Constructor (A.entityId entity))
        _ -> failAt InvalidAbstractTree (C.location whole) "empty dotted chain"
  _ -> do
    receiver <- expr base
    case A.nodeValue receiver of
      A.Constructor _ -> failAt WrongNamespace (C.location base) "cannot project directly from a constructor"
      _ -> foldM project receiver names
  where
    project receiver n = do requireName n; selector <- nameNode n (C.nameText n); sourceNode whole (A.Project receiver selector)

requirePrelude :: Span -> Resolve ()
requirePrelude s = do
  enabled <- asks (headerPrelude . envHeader)
  unless enabled (failAt PreludeRequired s "this syntax requires implicit Prelude")

sugar :: Span -> SugarKey -> Resolve A.Expr
sugar s key = do
  registry <- asks (sugarBindings . envSugar)
  gid <- maybe (failAt MissingSugarBinding s "syntax expansion has no configured library contract") pure (Map.lookup key registry)
  env <- ask
  let entities = Map.unions (map allEntities (Map.elems (scopeInterfaces (envScope env))))
  case Map.lookup gid entities of
    Nothing -> failAt MissingSugarBinding s "configured sugar binding is unavailable"
    Just entity -> generated "library sugar" s (if A.entityRole entity == MethodRole then A.Method gid else A.Ref (GlobalRef gid))

apply2 :: Span -> A.Expr -> A.Expr -> A.Expr -> Resolve A.Expr
apply2 s f a b = do fa <- generated "sugar application" s (A.Apply f a); generated "sugar application" s (A.Apply fa b)

doExpr :: C.Expr -> [C.DoStatement] -> Resolve A.Expr
doExpr whole = \case
  [] -> failAt InvalidAbstractTree (C.location whole) "empty do block"
  [C.Located _ _ (C.DoExpression e)] -> expr e
  statement : rest -> case C.concrete statement of
    C.DoDeclaration d -> sequentialDeclaration whole d (doExpr whole rest)
    C.DoExpression e -> do
      value <- expr e
      continuation <- doExpr whole rest
      binder <- freshBinder (C.location statement) "$ignored"
      lambda <- generated "do sequencing" (C.location statement) (A.Lambda binder continuation)
      bind <- sugar (C.location statement) (SugarKey "do.bind")
      apply2 (C.location statement) bind value lambda
    C.PatternBind p rhs -> do
      value <- expr rhs
      (bindings, patterns) <- bindPatterns [p]
      continuation <- local (\env -> env {envValues = bindings `Map.union` envValues env}) (doExpr whole rest)
      case patterns of
        [pat] -> do
          lambda <- normalizeLambda A.RequiredTotal pat continuation
          bind <- sugar (C.location statement) (SugarKey "do.bind")
          apply2 (C.location statement) bind value lambda
        _ -> failAt InvalidAbstractTree (C.location p) "missing do pattern"

sequential :: C.Expr -> [C.BlockItem] -> Resolve A.Expr
sequential whole = \case
  [] -> failAt InvalidAbstractTree (C.location whole) "empty expression block"
  [C.Located _ _ (C.Expression e)] -> expr e
  item : rest -> case C.concrete item of
    C.Expression e -> do
      value <- expr e
      remaining <- sequential whole rest
      statement <- sourceNode item (A.Effect value)
      sourceNode whole (A.Sequence [statement] remaining)
    C.LocalDeclaration d -> case C.concrete d of
      C.TypeSignature _ _ -> case rest of
        C.Located _ _ (C.LocalDeclaration next) : tailItems -> sequentialSigned whole d next (sequential whole tailItems)
        _ -> failAt MissingSignatureTarget (C.location d) "local signature has no following definition"
      _ -> sequentialDeclaration whole d (sequential whole rest)

sequentialSigned :: C.Expr -> C.Declaration -> C.Declaration -> Resolve A.Expr -> Resolve A.Expr
sequentialSigned whole signature declaration continuation = sequentialGroup whole [signature, declaration] continuation

sequentialDeclaration :: C.Expr -> C.Declaration -> Resolve A.Expr -> Resolve A.Expr
sequentialDeclaration whole d = sequentialGroup whole [d]

sequentialGroup :: C.Expr -> [C.Declaration] -> Resolve A.Expr -> Resolve A.Expr
sequentialGroup whole ds continuation = do
  -- Preallocate new identities, but resolve initializers in the previous scope.
  (bindings, _) <- localBindings ds
  group <- declarationsWith False bindings ds
  old <- asks envValues
  forM_ (Map.keys bindings) $ \spelling -> when (Map.member spelling old) (emit (diagnostic Shadowing (C.location whole) ("sequential binding shadows " <> spelling)))
  remaining <- local (\e -> e {envValues = bindings `Map.union` envValues e}) continuation
  statement <- generated "sequential binding" (C.location whole) (A.BindStatement group)
  sourceNode whole (A.Sequence [statement] remaining)

withWhere :: Int -> Maybe C.WhereClause -> Resolve A.Expr -> Resolve A.Expr
withWhere _ Nothing action = action
withWhere arity (Just w) action = case C.concrete w of
  C.WhereClause block -> do
    (bindings, _) <- localBindings (C.blockItems block)
    local (\e -> e {envValues = bindings `Map.union` envValues e}) $ do
      group <- declarationsWith True bindings (C.blockItems block)
      result <- action
      sourceNode w (A.Where (plan arity) group result)

plan :: Int -> A.WherePlan
plan 0 = A.AtInitialization
plan n = A.AfterValueParameters n

localBindings :: [C.Declaration] -> Resolve (Map Text Reference, ())
localBindings ds = do
  forM_ [p | C.Located _ _ (C.PatternBinding p _ _) <- ds] $ \p -> do
    _ <- foldM checkPattern Map.empty (patternNames p)
    pure ()
  _ <- foldM checkDeclaration Map.empty (concatMap definitionNames ds)
  names <- foldM add Map.empty (concatMap declared ds)
  pure (names, ())
  where
    definitionNames d = case C.concrete d of
      C.FunctionClause n _ _ _ _ -> [(True, n) | C.nameText n /= "_"]
      C.PatternBinding p _ _ -> [(False, n) | n <- patternNames p]
      _ -> []
    checkDeclaration seen (function, n) = case Map.lookup (C.nameText n) seen of
      Just (True, _) | function -> pure seen
      Just (_, old) -> do
        emit ((diagnostic DuplicateDeclaration (C.nameLocation n) "duplicate local declaration") {relatedSpans = [(C.nameLocation old, "earlier declaration")]})
        throwError ()
      Nothing -> pure (Map.insert (C.nameText n) (function, n) seen)
    checkPattern seen n = case Map.lookup (C.nameText n) seen of
      Just old -> do
        emit ((diagnostic DuplicatePatternBinder (C.nameLocation n) "duplicate pattern binder") {relatedSpans = [(C.nameLocation old, "first binder")]})
        throwError ()
      Nothing -> pure (Map.insert (C.nameText n) n seen)
    declared d = case C.concrete d of
      C.FunctionClause n _ _ _ _ -> [n | C.nameText n /= "_"]
      C.PatternBinding p _ _ -> patternNames p
      _ -> []
    add table n | Map.member (C.nameText n) table = pure table
    add table n = do
      i <- LocalId <$> newId
      recordOccurrence n (LocalRef i) []
      pure (Map.insert (C.nameText n) (LocalRef i) table)

declarations :: Bool -> [C.Declaration] -> Resolve A.BindingGroup
declarations recursive ds = declarationsWith recursive Map.empty ds

declarationsWith :: Bool -> Map Text Reference -> [C.Declaration] -> Resolve A.BindingGroup
declarationsWith recursive allocated ds = do
  let keys = nub [C.nameText n | C.Located _ _ decl <- ds, n <- case decl of C.FunctionClause x _ _ _ _ -> [x]; C.TypeSignature x _ -> [x]; _ -> [], C.nameText n /= "_"]
  values <- forM keys $ \key -> recover (valueDefinition allocated key ds)
  others <- forM ds $ \d -> case C.concrete d of
    C.FunctionClause n bs ps body w
      | C.nameText n == "_" -> recover $ do
          unless (null bs && null ps) (requireName n)
          wildcard <- nameNode n A.Wildcard
          rhs <- withWhere 0 w (expr body)
          sourceNode d (A.PatternDefinition wildcard rhs)
      | otherwise -> pure Nothing
    C.TypeSignature n _
      | C.nameText n == "_" -> recover (failAt ReservedName (C.nameLocation n) "a signature requires a name")
      | otherwise -> pure Nothing
    C.KindSignature n k -> case [() | C.Located _ _ decl <- ds, sameType n decl] of
      _ : _ -> pure Nothing
      [] -> recover $ do
        gid <- A.entityId <$> lookupEntity TypeNS n
        builtin <- gets (fmap fst . Map.lookupMin . Map.filter (== gid) . associations)
        case builtin of
          Just key -> do kind <- kindNode k; sourceNode d (A.OpaqueBuiltinType gid key kind)
          Nothing -> failAt MissingSignatureTarget (C.nameLocation n) "kind signature has no type declaration or builtin association"
    C.PragmaDeclaration p -> do
      -- BUILTIN is checked once during association collection.
      case C.concrete p of
        C.Pragma n _ | C.nameText n == "BUILTIN" -> pure ()
        _ -> case validatePragma DeclarationDirective p of Left err -> emit err; Right _ -> pure ()
      pure Nothing
    _ -> recover (otherDeclaration allocated ds d)
  -- Restore declaration source order after grouping clauses.
  let allDeclarations = catMaybes values ++ catMaybes others
      sorted = sortNodes allDeclarations
  pure (A.BindingGroup (if recursive then A.Recursive else A.Sequential) sorted)
  where
    sameType n = \case
      C.TypeAlias name _ _ -> C.nameText name == C.nameText n
      C.DataDeclaration name _ _ -> C.nameText name == C.nameText n
      C.TraitDeclaration _ name _ _ -> C.nameText name == C.nameText n
      _ -> False
    sortNodes = map snd . Map.toAscList . Map.fromList . map (\d -> ((start (A.nodeSpan d), A.nodeId d), d))

valueDefinition :: Map Text Reference -> Text -> [C.Declaration] -> Resolve A.Declaration
valueDefinition allocated key ds = do
  let clauses = [d | d@(C.Located _ _ (C.FunctionClause n _ _ _ _)) <- ds, C.nameText n == key]
      signatures = [(d, s) | d@(C.Located _ _ (C.TypeSignature n s)) <- ds, C.nameText n == key]
      names = [n | C.Located _ _ decl <- ds, n <- case decl of C.FunctionClause x _ _ _ _ | C.nameText x == key -> [x]; C.TypeSignature x _ | C.nameText x == key -> [x]; _ -> []]
  n <- case names of x : _ -> pure x; [] -> throwError ()
  ref <- case Map.lookup key allocated of
    Just r -> pure r
    Nothing -> do e <- lookupEntity ValueNS n; pure (GlobalRef (A.entityId e))
  forM_ (drop 1 signatures) $ \(d, _) -> case C.concrete d of
    C.TypeSignature name _ -> emit (diagnostic DuplicateSignature (C.nameLocation name) "duplicate signature")
    _ -> pure ()
  annotation <- case signatures of (_, s) : _ -> traverse (const (scheme s)) (Just ()); [] -> pure Nothing
  builtin <- case ref of GlobalRef gid -> gets (fmap fst . Map.lookupMin . Map.filter (== gid) . associations); _ -> pure Nothing
  case clauses of
    [] -> case builtin of
      Just builtinKey -> nameNode n (A.ValueDefinition ref annotation (A.BuiltinBody builtinKey))
      Nothing -> failAt MissingSignatureTarget (C.nameLocation n) "signature has no declaration or builtin implementation"
    first : rest -> do
      let arity d = case C.concrete d of C.FunctionClause _ _ ps _ _ -> length ps; _ -> 0
          written = arity first
      forM_ rest $ \later -> do
        when (written == 0) (emit ((diagnostic DuplicateDeclaration (C.nameLocation (clauseName later)) "duplicate zero-argument definition") {relatedSpans = [(C.location first, "earlier declaration")]}))
        when (arity later /= written) (emit ((diagnostic ClauseArityMismatch (headSpan later) "clauses have different written value arities") {relatedSpans = [(headSpan first, "first clause head")]}))
      resolved <- catMaybes <$> mapM (recover . resolveClause) clauses
      case resolved of
        c : cs -> sourceNode first (A.ValueDefinition ref annotation (A.ClausesBody written (c :| cs)))
        [] -> throwError ()
  where
    clauseName d = case C.concrete d of C.FunctionClause n _ _ _ _ -> n; _ -> nFallback d
    nFallback d = C.Name (C.location d) (C.origin d) key C.LowerName C.Alphabetic
    headSpan d = case C.concrete d of
      C.FunctionClause n bs ps _ _ -> let spans = map C.location bs ++ map C.location ps in (C.nameLocation n) {end = case reverse spans of s : _ -> end s; [] -> end (C.nameLocation n)}
      _ -> C.location d

resolveClause :: C.Declaration -> Resolve A.Clause
resolveClause d = case C.concrete d of
  C.FunctionClause _ bs ps body w -> do
    (types, (patterns, result, whereGroup)) <- withTypes bs $ do
      (bindings, patterns) <- bindPatterns ps
      local (\e -> e {envValues = bindings `Map.union` envValues e}) $ do
        (whereBindings, _) <- case w of Nothing -> pure (Map.empty, ()); Just (C.Located _ _ (C.WhereClause block)) -> localBindings (C.blockItems block)
        local (\e -> e {envValues = whereBindings `Map.union` envValues e}) $ do
          group <- case w of Nothing -> pure (A.BindingGroup A.Recursive []); Just (C.Located _ _ (C.WhereClause block)) -> declarationsWith True whereBindings (C.blockItems block)
          result <- expr body
          pure (patterns, result, group)
    sourceNode d (A.Clause types patterns result whereGroup (plan (length ps)))
  _ -> failAt InvalidAbstractTree (C.location d) "not a function clause"

otherDeclaration :: Map Text Reference -> [C.Declaration] -> C.Declaration -> Resolve A.Declaration
otherDeclaration allocated siblings d = case C.concrete d of
  C.PatternBinding p rhs w -> do
    result <- withWhere 0 w (expr rhs)
    patterns <- local (\e -> e {envValues = allocated `Map.union` envValues e}) (patternNode p)
    sourceNode d (A.PatternDefinition patterns result)
  C.TypeAlias n ps t -> do
    gid <- A.entityId <$> lookupEntity TypeNS n
    (parameters, body) <- withParameters ps (typeNode False t)
    k <- kindSignature n
    sourceNode d (A.AliasDefinition gid parameters k body)
  C.DataDeclaration n ps body -> do
    gid <- A.entityId <$> lookupEntity TypeNS n
    k <- kindSignature n
    (parameters, result) <- withParameters ps $ case body of
      C.Constructors block -> do
        cs <- forM (C.blockItems block) $ \c -> case C.concrete c of
          C.Constructor name ts -> do ctor <- A.entityId <$> lookupEntity ConstructorNS name; args <- mapM (typeNode False) ts; sourceNode c (ctor, args)
        pure (Left cs)
      C.Fields block -> do
        fs <- forM (C.blockItems block) $ \f -> case C.concrete f of C.FieldSignature name t -> do ty <- typeNode False t; sourceNode f (C.nameText name, ty)
        pure (Right fs)
    sourceNode d (case result of Left cs -> A.DataDefinition gid parameters k cs; Right fs -> A.RecordDefinition gid parameters k (globalInNamespace gid ConstructorNS) fs)
  C.TraitDeclaration cs n p block -> do
    gid <- A.entityId <$> lookupEntity TypeNS n
    (parameters, (supers, methods)) <- withParameters [p] $ do
      supers <- mapM (predicate False) cs
      methods <- forM (C.blockItems block) $ \method -> case C.concrete method of
        C.TypeSignature name s -> do methodId <- A.entityId <$> lookupEntity ValueNS name; sig <- scheme s; sourceNode method (A.MethodDefinition methodId sig)
        _ -> failAt InvalidAbstractTree (C.location method) "invalid trait member"
      pure (supers, methods)
    case parameters of
      [parameter] -> sourceNode d (A.TraitDefinition gid parameter supers methods)
      _ -> throwError ()
  C.Implementation cs headConstraint block -> do
    owner <- asks (headerId . envHeader)
    ident <- ImplementationId . (owner,) <$> newId
    modify' (\s -> s {implementations = ident : implementations s})
    let vars = concat [freeTypes t | C.Located _ _ (C.Constraint _ t) <- headConstraint : cs]
    (types, (context, head', members)) <- implicitTypes vars $ do
      context <- mapM (predicate False) cs
      head' <- predicate False headConstraint
      -- Member names denote the trait's method identities, never new globals.
      env <- ask
      let traitId = fst (A.nodeValue head')
          entities = Map.unions (Map.fromList [(A.entityId x, x) | x <- Map.elems (envOwn env)] : map allEntities (Map.elems (scopeInterfaces (envScope env))))
          memberNames = Map.fromList [(name, GlobalRef gid) | (gid@(GlobalId _ ValueNS name), entity) <- Map.toList entities, A.entityOwner entity == Just traitId]
      let memberRefs = Map.fromList [(C.nameText n, ref) | C.Located _ _ (C.FunctionClause n _ _ _ _) <- C.blockItems block, Just ref <- [Map.lookup (C.nameText n) memberNames]]
      forM_ [n | C.Located _ _ (C.FunctionClause n _ _ _ _) <- C.blockItems block, Map.notMember (C.nameText n) memberNames] $ \n ->
        if C.nameText n == "_"
          then emit (diagnostic ReservedName (C.nameLocation n) "an implementation member requires a name")
          else emit (diagnostic MissingExport (C.nameLocation n) "trait has no such method")
      let namedMember member = case C.concrete member of
            C.FunctionClause n _ _ _ _ -> C.nameText n /= "_"
            _ -> True
      group <- local (\e -> e {envValues = memberRefs `Map.union` envValues e}) (declarationsWith True memberRefs (filter namedMember (C.blockItems block)))
      pure (context, head', A.declarations group)
    sourceNode d (A.ImplementationDefinition ident types context head' members)
  _ -> failAt InvalidAbstractTree (C.location d) "unexpected declaration in conversion"
  where
    kindSignature n = case [k | C.Located _ _ (C.KindSignature name k) <- siblings, C.nameText name == C.nameText n] of
      k : _ -> Just <$> kindNode k
      [] -> pure Nothing
    globalInNamespace (GlobalId owner _ spelling) ns = GlobalId owner ns spelling
    globalInNamespace gid _ = gid

withParameters :: [C.TypeParameter] -> Resolve a -> Resolve ([A.TypeBinder], a)
withParameters parameters = withTypes [C.Located (C.location p) (C.origin p) (C.TypeBinder n k) | p@(C.Located _ _ (C.TypeParameter n k)) <- parameters]

collectBuiltins :: [C.Pragma] -> Resolve ()
collectBuiltins pragmas = forM_ [p | p@(C.Located _ _ (C.Pragma n _)) <- pragmas, C.nameText n == "BUILTIN"] $ \p -> do
  _ <- recover $ case validatePragma ModuleDirective p of
    Left err -> emit err >> throwError ()
    Right directive | directiveName directive == "BUILTIN" -> case C.concrete p of
      C.Pragma _ [C.Located _ _ (C.IdentifierArgument key), C.Located _ _ (C.IdentifierArgument target)] -> do
        requireName target
        keys <- asks (builtinKeys . envConfig)
        unless (Set.member (C.nameText key) keys) (failAt UnknownBuiltin (C.nameLocation key) "unknown compiler builtin key")
        own <- asks envOwn
        let ns = if C.nameSpace target == C.LowerName then ValueNS else TypeNS
        entity <- maybe (failAt UnresolvedName (C.nameLocation target) "builtin target is not declared in this module") pure (Map.lookup (ns, C.nameText target) own)
        table <- gets associations
        when (Map.member (C.nameText key) table || A.entityId entity `elem` Map.elems table) (failAt ConflictingBuiltinAssociation (C.nameLocation key) "conflicting builtin association")
        modify' (\s -> s {associations = Map.insert (C.nameText key) (A.entityId entity) (associations s)})
      _ -> throwError ()
    Right _ -> pure ()
  pure ()

plainLiteral :: C.Literal -> Resolve L.Literal
plainLiteral = \case
  C.IntegerLiteral t -> pure (L.IntegerLiteral t)
  C.FloatLiteral t -> pure (L.FloatLiteral t)
  C.CharLiteral t -> case decode (T.unpack (T.dropEnd 1 (T.drop 1 t))) of
    [c] -> pure (L.CharacterLiteral c)
    _ -> throwError () -- impossible after validated parsing
  C.StringLiteralText t -> pure (L.StringLiteral (T.pack (decode (T.unpack (T.dropEnd 1 (T.drop 1 t))))))

decode :: String -> String
decode = \case
  '\\' : c : rest -> escaped c : decode rest
  '{' : '{' : rest -> '{' : decode rest
  '}' : '}' : rest -> '}' : decode rest
  c : rest -> c : decode rest
  [] -> []

escaped :: Char -> Char
escaped = \case 'n' -> '\n'; 'r' -> '\r'; 't' -> '\t'; c -> c

-- Parsed strings are already lexically valid. The scanner separates escapes
-- before interpolation and never reparses expressions or performs file IO.
stringParts :: Text -> [Either Text Text]
stringParts raw = scan [] (T.unpack (T.dropEnd 1 (T.drop 1 raw)))
  where
    scan acc [] = [Left (T.pack (reverse acc))]
    scan acc ('\\' : c : rest) = scan (escaped c : acc) rest
    scan acc ('{' : '{' : rest) = scan ('{' : acc) rest
    scan acc ('}' : '}' : rest) = scan ('}' : acc) rest
    scan acc ('{' : rest) = let (name, tail') = break (== '}') rest in Left (T.pack (reverse acc)) : Right (T.pack name) : scan [] (drop 1 tail')
    scan acc (c : rest) = scan (c : acc) rest

stringExpr :: C.Expr -> Text -> Resolve A.Expr
stringExpr original raw = do
  let parts = stringParts raw
      s = C.location original
  if all isPlain parts
    then sourceNode original (A.Literal (L.StringLiteral (T.concat [t | Left t <- parts])))
    else do
      requirePrelude s
      values <- mapM segment parts
      append <- sugar s (SugarKey "string.append")
      case values of
        v : vs -> foldM (apply2 s append) v vs
        [] -> sourceNode original (A.Literal (L.StringLiteral ""))
  where
    isPlain (Left _) = True
    isPlain _ = False
    segment (Left t) = generated "interpolation literal" (C.location original) (A.Literal (L.StringLiteral t))
    segment (Right spelling) = do
      let components = map T.strip (T.splitOn "." spelling)
          makeName t = C.Name (C.location original) (GeneratedOrigin "interpolation" (C.location original)) t (if t == T.toLower t then C.LowerName else C.UpperName) C.Alphabetic
      value <- case reverse components of
        [name] -> valueRef (makeName name)
        terminal : prefix -> do e <- qualified ValueNS (map makeName (reverse prefix)) (makeName terminal); generated "interpolation reference" (C.location original) (A.Ref (GlobalRef (A.entityId e)))
        [] -> throwError ()
      showMethod <- sugar (C.location original) (SugarKey "string.show")
      generated "interpolation show" (C.location original) (A.Apply showMethod value)
