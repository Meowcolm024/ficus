-- | Link dependency-ordered, closed Core modules and lower to validated Runtime.
-- Core is independently accepted here; holes are rejected before any erasure.
module FicusBackend.Lower.Runtime (LoweredProgram (..), RuntimeLayouts, lowerProgram, lowerProgramWithLayouts) where

import Control.Monad (forM, unless)
import Control.Monad.Except (throwError)
import Control.Monad.State.Strict (StateT, gets, modify', runStateT)
import Data.IntMap.Strict qualified as IntMap
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Vector qualified as V
import Ficus.Error.Type qualified as TypeError
import Ficus.Primitive.Registry qualified as P
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Core.Validate (acceptCore)
import Ficus.Syntax.Literal qualified as L
import Ficus.Syntax.Name qualified as N
import Ficus.Type (Type (..), explicitQuantifiers, quantifierId, quantifierKind, quantifiers, schemeType)
import Ficus.Type.Substitution qualified as S
import Ficus.Util.Source
import FicusBackend.Error qualified as E
import FicusBackend.Runtime.AST qualified as R
import FicusBackend.Runtime.Validate
import Text.Read (readMaybe)

data LoweredProgram = LoweredProgram {loweredProgram :: ValidatedProgram, loweredGlobals :: Map N.GlobalId R.GlobalIndex, loweredConstructors :: Map C.ConstructorId R.ConstructorIndex, loweredBindings :: Map (N.ModuleId, N.Reference) R.GlobalIndex, loweredLayouts :: RuntimeLayouts} deriving (Eq, Show)

-- | Stable layout identities let retained REPL closures exchange aggregates
-- with newly compiled code. The table contains Runtime metadata, never Core.
data RuntimeLayouts = RuntimeLayouts (Map N.GlobalId R.ConstructorIndex) (V.Vector (R.Node R.ConstructorLayout)) (Map N.GlobalId R.ConstructorIndex) deriving (Eq, Show)

data Representation = Erased | Immediate R.RuntimeLiteral | Boxed R.ConstructorIndex

data Context = Context
  { currentModule :: N.ModuleId,
    locals :: Map N.Reference R.Address,
    globals :: Map (N.ModuleId, N.Reference) R.GlobalIndex,
    constructors :: Map C.ConstructorId Representation,
    records :: Map N.GlobalId C.ConstructorId,
    dictionaries :: Map N.GlobalId (R.ConstructorIndex, Int),
    typeTokens :: Map N.GlobalId R.ConstructorIndex
  }

data LowerState = LowerState {nextFunction :: Int, functions :: IntMap.IntMap R.Function}

type Lower = StateT LowerState (Either [E.BackendError])

lowerProgram :: [C.CoreModule C.CoreType] -> Either [E.BackendError] LoweredProgram
lowerProgram = lowerProgramWithLayouts Nothing

lowerProgramWithLayouts :: Maybe RuntimeLayouts -> [C.CoreModule C.CoreType] -> Either [E.BackendError] LoweredProgram
lowerProgramWithLayouts previousLayouts modules = do
  unless (null holes) (Left holes)
  mapM_ checkCore modules
  let allBindings = [(C.coreId tree, binding) | tree <- modules, group <- C.coreBindings tree, binding <- C.groupBindings group]
      indexed = zip [0 ..] allBindings
      globalTable = Map.fromList [(key owner (C.bindingReference (C.nodeValue binding)), R.GlobalIndex index') | (index', (owner, binding)) <- indexed]
      providers = Map.fromList [(key owner (C.bindingReference (C.nodeValue binding)), C.bindingScheme (C.nodeValue binding)) | (_, (owner, binding)) <- indexed]
  unless (length allBindings == Map.size globalTable) (Left [E.BackendError E.InvalidCore origin "duplicate linked Core declaration"])
  mapM_ (checkImports providers) modules
  let (representations, layouts, dictionaryLayouts, layoutState) = representationTables previousLayouts modules
      recordTable = Map.unions [Map.map (C.recordConstructor . C.nodeValue) (C.coreRecords tree) | tree <- modules]
      action = fmap concat $ forM modules $ \tree -> do
        let RuntimeLayouts _ _ tokens = layoutState
            context = Context (C.coreId tree) Map.empty globalTable representations recordTable dictionaryLayouts tokens
        mapM (lowerGroup context) (C.coreBindings tree)
  (initializers, state) <- runStateT action (LowerState 0 IntMap.empty)
  let program = R.Program (V.fromList (IntMap.elems (functions state))) (length indexed) layouts (V.fromList P.allPrimitives) initializers
  checked <- validateProgram program
  pure (LoweredProgram checked (Map.fromList [(ident, index') | ((_, N.GlobalRef ident), index') <- Map.toList globalTable]) (Map.mapMaybe (\case Boxed tag -> Just tag; _ -> Nothing) representations) globalTable layoutState)
  where
    origin = case modules of tree : _ -> C.coreSpan tree; [] -> Span "<runtime>" (Position 1 1 0) (Position 1 1 0)
    holes = [E.BackendError E.ExpressionHole (C.nodeSpan hole) "an expression hole prevents Runtime generation" | tree <- modules, group <- C.coreBindings tree, binding <- C.groupBindings group, hole <- C.expressionHoles (C.bindingBody (C.nodeValue binding))]
    checkCore tree = case acceptCore tree of
      Right _ -> Right ()
      Left errors -> Left [E.BackendError E.InvalidCore (TypeError.diagnosticSpan problem) (TypeError.diagnosticMessage problem) | problem <- errors]
    checkImports providers tree = mapM_ check (Map.toList (C.coreImports tree))
      where
        check (reference, expected) = case Map.lookup (key (C.coreId tree) reference) providers of
          Nothing -> Left [E.BackendError E.MissingGlobal (C.coreSpan tree) "Core import has no linked definition"]
          Just actual ->
            let substitution = S.fromBindings [(C.BoundVariable (quantifierId a), Variable (C.BoundVariable (quantifierId b)) (quantifierKind b)) | (a, b) <- zip (quantifiers expected) (quantifiers actual)]
                agrees = length (explicitQuantifiers expected) == length (explicitQuantifiers actual) && map quantifierKind (quantifiers expected) == map quantifierKind (quantifiers actual) && S.apply substitution (schemeType expected) == schemeType actual
             in unless agrees (Left [E.BackendError E.InvalidCore (C.coreSpan tree) "linked Core import has an incompatible scheme"])

key :: N.ModuleId -> N.Reference -> (N.ModuleId, N.Reference)
key _ reference@(N.GlobalRef (N.GlobalId owner _ _)) = (owner, reference)
key owner reference = (owner, reference)

errorContext :: C.Node a -> T.Text
errorContext source =
  let site = C.nodeSpan source
      position = start site
   in T.pack (sourceFile site) <> ":" <> T.pack (show (line position)) <> ":" <> T.pack (show (column position)) <> ": "

-- Only source-level failures need a location payload. Operand-contract errors
-- on other primitives indicate a broken Runtime invariant.
primitiveContext :: C.Node a -> P.Primitive nominal -> T.Text
primitiveContext source primitive = case primitive of
  P.Throw _ -> errorContext source
  P.IntDivide -> errorContext source
  P.IntRemainder -> errorContext source
  P.FloatToInt -> errorContext source
  P.HandleRead _ -> errorContext source
  P.HandleWrite _ -> errorContext source
  _ -> ""

failure :: E.ErrorKind -> C.Node a -> T.Text -> Lower b
failure kind source message = throwError [E.BackendError kind (C.nodeSpan source) message]

representationTables :: Maybe RuntimeLayouts -> [C.CoreModule C.CoreType] -> (Map C.ConstructorId Representation, V.Vector (R.Node R.ConstructorLayout), Map N.GlobalId (R.ConstructorIndex, Int), RuntimeLayouts)
representationTables previous modules = (allRepresentations, layouts, dictionaryIndices, RuntimeLayouts indices layouts tokenIndices)
  where
    descriptors = Map.unions (map C.coreConstructors modules)
    families = Map.fromListWith (+) [(C.constructorOwner (C.nodeValue node), 1 :: Int) | node <- Map.elems descriptors]
    isWrapper node = let descriptor = C.nodeValue node in C.constructorArity descriptor == 1 && Map.lookup (C.constructorOwner descriptor) families == Just 1
    boxed = [(ident, node) | (ident, node) <- Map.toAscList descriptors, not (isWrapper node)]
    traits = Map.toAscList (Map.unions (map C.coreDictionaries modules))
    intrinsicLayouts = V.fromList [R.Node (R.ConstructorLayout (R.FrameSize size)) | size <- [0, 2, 2]]
    initial = case previous of Nothing -> (Map.empty, intrinsicLayouts); Just (RuntimeLayouts known table _) -> (known, table)
    candidates =
      [(ident, R.Node (R.ConstructorLayout (R.FrameSize (C.constructorArity (C.nodeValue node))))) | (C.DataConstructor ident, node) <- boxed]
        ++ [(ident, R.Node (R.ConstructorLayout (R.FrameSize (length (C.dictionarySuperclasses (C.nodeValue node)) + length (C.dictionaryMethods (C.nodeValue node)))))) | (ident, node) <- traits]
    allocate (known, table) (ident, descriptor) = case Map.lookup ident known of
      Just _ -> (known, table)
      Nothing -> (Map.insert ident (R.ConstructorIndex (V.length table)) known, V.snoc table descriptor)
    (indices, aggregateLayouts) = foldl allocate initial candidates
    previousTokens = case previous of Nothing -> Map.empty; Just (RuntimeLayouts _ _ tokens) -> tokens
    tokenCandidates =
      Map.toAscList
        ( Map.fromList
            [ (ident, R.Node (R.ConstructorLayout (R.FrameSize (length arguments))))
            | tree <- modules,
              group <- C.coreBindings tree,
              binding <- C.groupBindings group,
              node <- descendants (C.bindingBody (C.nodeValue binding)),
              C.ExceptionDictionary _ ty _ <- [C.formOf node],
              Just (ident, arguments) <- [nominalHead ty]
            ]
        )
    (tokenIndices, layouts) = foldl allocate (previousTokens, aggregateLayouts) tokenCandidates
    descendants node = node : concatMap descendants (C.children node)
    nominalRepresentations =
      Map.fromList [(ident, Erased) | (ident, node) <- Map.toList descriptors, isWrapper node]
        `Map.union` Map.fromList [(constructor, Boxed tag) | (constructor@(C.DataConstructor ident), _) <- boxed, Just tag <- [Map.lookup ident indices]]
    allRepresentations =
      Map.fromList
        [ (C.DataConstructor (N.IntrinsicId N.TrueConstructor), Immediate (R.Boolean True)),
          (C.DataConstructor (N.IntrinsicId N.FalseConstructor), Immediate (R.Boolean False)),
          (C.DataConstructor (N.IntrinsicId N.NilConstructor), Boxed R.nilConstructor),
          (C.DataConstructor (N.IntrinsicId N.ConsConstructor), Boxed R.consConstructor),
          (C.PairConstructor, Boxed R.pairConstructor),
          (C.UnitConstructor, Immediate R.Unit)
        ]
        `Map.union` nominalRepresentations
    dictionaryIndices = Map.fromList [(ident, (tag, length (C.dictionarySuperclasses (C.nodeValue node)))) | (ident, node) <- traits, Just tag <- [Map.lookup ident indices]]

withFrame :: [N.Reference] -> Context -> Context
withFrame references context = context {locals = Map.fromList [(reference, R.Local (R.FrameDepth 0) (R.SlotIndex index')) | (index', reference) <- zip [0 ..] references] `Map.union` Map.map shift (locals context)}
  where
    shift (R.Local (R.FrameDepth depth) slot) = R.Local (R.FrameDepth (depth + 1)) slot
    shift capture = capture

lowerGroup :: Context -> C.BindingGroup C.CoreType -> Lower (R.Node R.GlobalGroup)
lowerGroup context group = do
  bindings <- forM (C.groupBindings group) $ \binding -> do
    ident <- globalIndex context binding (C.bindingReference (C.nodeValue binding))
    value <- lowerBinding context binding
    pure (ident, value)
  case (C.groupBindings group, NE.nonEmpty bindings) of
    (_ : _, Just values) -> pure (R.Node (R.GlobalGroup (case group of C.Recursive _ -> True; _ -> False) values))
    _ -> throwError [E.BackendError E.InvalidCore (Span "<runtime>" (Position 1 1 0) (Position 1 1 0)) "empty Core binding group"]

lowerBinding :: Context -> C.Binding C.CoreType -> Lower R.Binding
lowerBinding context source = do
  body <- expression context (C.bindingBody (C.nodeValue source))
  pure (R.Node (R.Binding body (maybe False (const True) (C.expansiveOrigin (C.bindingFacts (C.nodeValue source))))))

globalIndex :: Context -> C.Node a -> N.Reference -> Lower R.GlobalIndex
globalIndex context source reference = maybe (failure E.MissingGlobal source "unlinked Core reference") pure (Map.lookup (key (currentModule context) reference) (globals context))

representation :: Context -> C.Node a -> C.ConstructorId -> Lower Representation
representation context source ident = maybe (failure E.InvalidCore source "missing constructor representation") pure (Map.lookup ident (constructors context))

dictionary :: Context -> C.Node a -> N.GlobalId -> Lower (R.ConstructorIndex, Int)
dictionary context source owner = maybe (failure E.InvalidCore source "missing dictionary layout") pure (Map.lookup owner (dictionaries context))

expression :: Context -> C.Expr C.CoreType -> Lower R.Expr
expression context source = case C.formOf source of
  C.Hole _ -> failure E.ExpressionHole source "an expression hole prevents Runtime generation"
  C.Var reference _ -> case Map.lookup reference (locals context) of
    Just address -> pure (R.Node (R.Load address))
    Nothing -> R.Node . R.Global <$> globalIndex context source reference
  C.Literal literal -> R.Node . R.Literal <$> decodeLiteral source literal
  C.Lambda {} -> lowerLambda context source
  C.Apply f x -> do
    function <- expression context f
    argument <- expression context x
    pure (R.Node (R.Call function (argument NE.:| [])))
  C.Let binding body -> do
    initializer <- lowerBinding context binding
    rest <- expression (withFrame [C.bindingReference (C.nodeValue binding)] context) body
    pure (R.Node (R.Let initializer rest))
  C.LetRec bindings body -> do
    let inner = withFrame (map (C.bindingReference . C.nodeValue) (NE.toList bindings)) context
    initializers <- traverse (lowerBinding inner) bindings
    rest <- expression inner body
    pure (R.Node (R.LetRec initializers rest))
  C.Construct constructor _ fields ->
    representation context source constructor >>= \case
      Erased -> case fields of [field] -> expression context field; _ -> failure E.InvalidCore source "wrapper has the wrong arity"
      Immediate literal -> pure (R.Node (R.Literal literal))
      Boxed tag -> R.Node . R.Construct tag <$> mapM (expression context) fields
  C.Case receiver alternatives fallback -> lowerCase context receiver alternatives fallback
  C.If arms fallback -> do
    conditions <- forM arms $ \arm -> do
      let (test, body) = C.nodeValue arm
      condition <- expression context test
      result <- expression context body
      pure (R.Node (condition, result))
    rest <- maybe (pure (R.Node (R.Raise (errorContext source <> "no conditional branch matched")))) (expression context) fallback
    pure (R.Node (R.If conditions rest))
  C.SelectField receiver (C.FieldId owner index') -> do
    constructor <- maybe (failure E.InvalidCore source "missing record descriptor") pure (Map.lookup owner (records context))
    representation context source constructor >>= \case
      Erased -> expression context receiver
      Boxed tag -> R.Node . (\value -> R.Select value tag (R.FieldIndex index')) <$> expression context receiver
      Immediate _ -> failure E.InvalidCore source "record has an immediate representation"
  C.ExceptionDictionary _ ty arguments -> do
    ident <- maybe (failure E.InvalidCore source "exception token has no nominal head") (pure . fst) (nominalHead ty)
    tag <- maybe (failure E.InvalidCore source "missing exception identity") pure (Map.lookup ident (typeTokens context))
    values <- mapM (expression context) arguments
    pure (R.Node (R.TypeToken tag values))
  C.Dictionary owner _ supers methods -> do
    (tag, _) <- dictionary context source owner
    fields <- mapM (expression context) (supers ++ map (snd . C.nodeValue) methods)
    pure (R.Node (R.Construct tag fields))
  C.SelectMethod receiver owner index' _ -> do
    (tag, offset) <- dictionary context source owner
    value <- expression context receiver
    pure (R.Node (R.Select value tag (R.FieldIndex (offset + index'))))
  C.SelectSuperclass receiver owner index' -> do
    (tag, _) <- dictionary context source owner
    value <- expression context receiver
    pure (R.Node (R.Select value tag (R.FieldIndex index')))
  C.ScopeTypes _ body -> expression context body
  C.Primitive primitive arguments -> do
    values <- mapM (expression context) arguments
    index' <- maybe (failure E.InvalidCore source "primitive is absent from the shared registry") pure (P.primitiveIndex primitive)
    pure (R.Node (R.Primitive (R.PrimitiveIndex index') values (primitiveContext source primitive)))
  C.Fail -> pure (R.Node (R.Raise (errorContext source <> "pattern match failed")))

lowerCase :: Context -> C.Expr C.CoreType -> [C.Alternative C.CoreType] -> C.Expr C.CoreType -> Lower R.Expr
lowerCase context receiver alternatives fallback = do
  value <- expression context receiver
  case alternatives of
    first : _
      | (C.ConstructorTest constructor _ [binder], body) <- C.nodeValue first ->
          representation context first constructor >>= \case
            Erased -> do
              result <- expression (withFrame [C.binderReference binder] context) body
              pure (R.Node (R.Let (R.Node (R.Binding value False)) result))
            _ -> ordinary value
    _ -> ordinary value
  where
    ordinary value = do
      arms <- forM alternatives $ \arm -> do
        let (test, body) = C.nodeValue arm
        (runtimeTest, references) <- case test of
          C.LiteralTest literal -> (,[]) . R.LiteralTest <$> decodeLiteral arm literal
          C.ConstructorTest constructor _ binders ->
            representation context arm constructor >>= \case
              Immediate literal -> pure (R.LiteralTest literal, [])
              Boxed tag -> pure (R.ConstructorTest tag (R.FrameSize (length binders)), map C.binderReference binders)
              Erased -> failure E.InvalidCore arm "wrapper alternative has invalid fields"
        branch <- expression (withFrame references context) body
        pure (R.Node (runtimeTest, branch))
      rest <- expression context fallback
      pure (R.Node (R.Case value arms rest))

lowerLambda :: Context -> C.Expr C.CoreType -> Lower R.Expr
lowerLambda context source = do
  ident <- gets nextFunction
  modify' (\s -> s {nextFunction = ident + 1})
  let (parameters, aliases, body) = lambdaChain source
      needed = freeReferences body `Set.difference` Map.keysSet aliases
      captured = Map.toAscList (Map.restrictKeys (locals context) needed)
      captures = Map.fromList [(reference, R.Capture (R.CaptureIndex index')) | (index', (reference, _)) <- zip [0 ..] captured]
      arguments = Map.map (R.Local (R.FrameDepth 0) . R.SlotIndex) aliases
      inner = context {locals = arguments `Map.union` captures}
      roles = V.fromList [case C.nodeValue binder of (_, _, C.ValueBinder, _) -> R.ValueParameter; _ -> R.EvidenceParameter | binder <- parameters]
  lowered <- expression inner body
  let function = R.Node (R.Function (R.Arity (length parameters)) (R.FrameSize (length parameters)) (R.CaptureLayout (length captured)) roles lowered)
  modify' (\s -> s {functions = IntMap.insert ident function (functions s)})
  pure (R.Node (R.Closure (R.FunctionIndex ident) [R.Node address | (_, address) <- captured]))

-- Crossing parameter aliases is safe: an argument cell is already initialized.
-- Matches, where groups, calls and all other lets stop arity raising.
lambdaChain :: C.Expr C.CoreType -> ([C.Binder C.CoreType], Map N.Reference Int, C.Expr C.CoreType)
lambdaChain = go [] Map.empty
  where
    go parameters aliases source = case C.formOf source of
      C.Lambda binder body -> go (parameters ++ [binder]) (Map.insert (C.binderReference binder) (length parameters) aliases) body
      C.ScopeTypes _ body -> go parameters aliases body
      C.Let binding body | null (quantifiers (C.bindingScheme (C.nodeValue binding))), C.Var reference [] <- C.formOf (C.bindingBody (C.nodeValue binding)), Just slot <- Map.lookup reference aliases -> go parameters (Map.insert (C.bindingReference (C.nodeValue binding)) slot aliases) body
      _ -> (parameters, aliases, source)

freeReferences :: C.Expr ty -> Set.Set N.Reference
freeReferences source = case C.formOf source of
  C.Var reference _ -> Set.singleton reference
  C.Lambda binder body -> Set.delete (C.binderReference binder) (freeReferences body)
  C.Let binding body -> freeReferences (C.bindingBody (C.nodeValue binding)) `Set.union` Set.delete (C.bindingReference (C.nodeValue binding)) (freeReferences body)
  C.LetRec bindings body -> Set.unions (freeReferences body : map (freeReferences . C.bindingBody . C.nodeValue) (NE.toList bindings)) `Set.difference` Set.fromList (map (C.bindingReference . C.nodeValue) (NE.toList bindings))
  C.Case receiver alternatives fallback -> Set.unions (freeReferences receiver : freeReferences fallback : [freeReferences body `Set.difference` Set.fromList (case test of C.ConstructorTest _ _ binders -> map C.binderReference binders; _ -> []) | arm <- alternatives, let (test, body) = C.nodeValue arm])
  _ -> Set.unions (map freeReferences (C.children source))

decodeLiteral :: C.Node a -> L.Literal -> Lower R.RuntimeLiteral
decodeLiteral source literal = case literal of
  L.IntegerLiteral spelling -> maybe bad (pure . R.Integer . fromInteger) (readMaybe (T.unpack spelling))
  L.FloatLiteral spelling -> maybe bad (pure . R.Floating) (readMaybe (T.unpack spelling))
  L.CharacterLiteral character -> pure (R.Character character)
  L.StringLiteral string -> pure (R.String string)
  where
    bad = failure E.InvalidLiteral source "invalid numeric literal in Core"

nominalHead :: Type v -> Maybe (N.GlobalId, [Type v])
nominalHead = go []
  where
    go arguments (Application f x) = go (x : arguments) f
    go arguments (Constructor ident _) = Just (ident, arguments)
    go _ _ = Nothing
