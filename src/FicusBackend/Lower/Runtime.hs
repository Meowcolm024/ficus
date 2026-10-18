-- | Link dependency-ordered, closed Core modules and lower to validated Runtime.
-- Core is independently accepted here; holes are rejected before any erasure.
module FicusBackend.Lower.Runtime (LoweredProgram (..), lowerProgram) where

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
import FicusBackend.Runtime.AST qualified as R
import FicusBackend.Runtime.Error qualified as E
import FicusBackend.Runtime.Validate
import Text.Read (readMaybe)

data LoweredProgram = LoweredProgram {loweredProgram :: ValidatedProgram, loweredGlobals :: Map N.GlobalId R.GlobalIndex} deriving (Eq, Show)

data Representation = Erased | Immediate R.RuntimeLiteral | Boxed R.ConstructorIndex

data Context = Context
  { currentModule :: N.ModuleId,
    locals :: Map N.Reference R.Address,
    globals :: Map (N.ModuleId, N.Reference) R.GlobalIndex,
    constructors :: Map C.ConstructorId Representation,
    records :: Map N.GlobalId C.ConstructorId,
    dictionaries :: Map N.GlobalId (R.ConstructorIndex, Int)
  }

data LowerState = LowerState {nextFunction :: Int, functions :: IntMap.IntMap R.Function}

type Lower = StateT LowerState (Either [E.RuntimeError])

lowerProgram :: [C.CoreModule C.CoreType] -> Either [E.RuntimeError] LoweredProgram
lowerProgram modules = do
  unless (null holes) (Left holes)
  mapM_ checkCore modules
  let allBindings = [(C.coreId tree, binding) | tree <- modules, group <- C.coreBindings tree, binding <- C.groupBindings group]
      indexed = zip [0 ..] allBindings
      globalTable = Map.fromList [(key owner (C.bindingReference (C.nodeValue binding)), R.GlobalIndex index') | (index', (owner, binding)) <- indexed]
      providers = Map.fromList [(key owner (C.bindingReference (C.nodeValue binding)), C.bindingScheme (C.nodeValue binding)) | (_, (owner, binding)) <- indexed]
  unless (length allBindings == Map.size globalTable) (Left [E.RuntimeError E.InvalidCore origin "duplicate linked Core declaration"])
  mapM_ (checkImports providers) modules
  let (representations, layouts, dictionaryLayouts) = representationTables origin modules
      recordTable = Map.unions [Map.map (C.recordConstructor . C.nodeValue) (C.coreRecords tree) | tree <- modules]
      action = fmap concat $ forM modules $ \tree -> do
        let context = Context (C.coreId tree) Map.empty globalTable representations recordTable dictionaryLayouts
        mapM (lowerGroup context) (C.coreBindings tree)
  (initializers, state) <- runStateT action (LowerState 0 IntMap.empty)
  let debug = V.fromList [fromCore binding (case C.bindingReference (C.nodeValue binding) of N.GlobalRef ident -> (Just ident, T.pack (show ident)); N.LocalRef _ -> (Nothing, "$discard")) | (_, (_, binding)) <- indexed]
      program = R.Program origin (SourceOrigin origin) (V.fromList (IntMap.elems (functions state))) debug layouts (V.fromList P.allPrimitives) initializers
  checked <- validateProgram program
  pure (LoweredProgram checked (Map.fromList [(ident, index') | ((_, N.GlobalRef ident), index') <- Map.toList globalTable]))
  where
    origin = case modules of tree : _ -> C.coreSpan tree; [] -> Span "<runtime>" (Position 1 1 0) (Position 1 1 0)
    holes = [E.RuntimeError E.ExpressionHole (C.nodeSpan hole) "an expression hole prevents Runtime generation" | tree <- modules, group <- C.coreBindings tree, binding <- C.groupBindings group, hole <- C.expressionHoles (C.bindingBody (C.nodeValue binding))]
    checkCore tree = case acceptCore tree of
      Right _ -> Right ()
      Left errors -> Left [E.RuntimeError E.InvalidCore (TypeError.diagnosticSpan problem) (TypeError.diagnosticMessage problem) | problem <- errors]
    checkImports providers tree = mapM_ check (Map.toList (C.coreImports tree))
      where
        check (reference, expected) = case Map.lookup (key (C.coreId tree) reference) providers of
          Nothing -> Left [E.RuntimeError E.MissingGlobal (C.coreSpan tree) "Core import has no linked definition"]
          Just actual ->
            let substitution = S.fromBindings [(C.BoundVariable (quantifierId a), Variable (C.BoundVariable (quantifierId b)) (quantifierKind b)) | (a, b) <- zip (quantifiers expected) (quantifiers actual)]
                agrees = length (explicitQuantifiers expected) == length (explicitQuantifiers actual) && map quantifierKind (quantifiers expected) == map quantifierKind (quantifiers actual) && S.apply substitution (schemeType expected) == schemeType actual
             in unless agrees (Left [E.RuntimeError E.InvalidCore (C.coreSpan tree) "linked Core import has an incompatible scheme"])

key :: N.ModuleId -> N.Reference -> (N.ModuleId, N.Reference)
key _ reference@(N.GlobalRef (N.GlobalId owner _ _)) = (owner, reference)
key owner reference = (owner, reference)

fromCore :: C.Node a -> b -> R.Node b
fromCore source = R.Node (C.nodeSpan source) (C.nodeOrigin source)

generated :: C.Node a -> b -> R.Node b
generated source = R.Node (C.nodeSpan source) (GeneratedOrigin "runtime lowering" (C.nodeSpan source))

failure :: E.ErrorKind -> C.Node a -> T.Text -> Lower b
failure kind source message = throwError [E.RuntimeError kind (C.nodeSpan source) message]

representationTables :: Span -> [C.CoreModule C.CoreType] -> (Map C.ConstructorId Representation, V.Vector (R.Node R.ConstructorLayout), Map N.GlobalId (R.ConstructorIndex, Int))
representationTables origin modules = (allRepresentations, V.fromList (intrinsicLayouts ++ nominalLayouts ++ dictionaryLayouts), dictionaryIndices)
  where
    descriptors = Map.unions (map C.coreConstructors modules)
    families = Map.fromListWith (+) [(C.constructorOwner (C.nodeValue node), 1 :: Int) | node <- Map.elems descriptors]
    isWrapper node = let descriptor = C.nodeValue node in C.constructorArity descriptor == 1 && Map.lookup (C.constructorOwner descriptor) families == Just 1
    boxed = [(ident, node) | (ident, node) <- Map.toAscList descriptors, not (isWrapper node)]
    nominalIndices = Map.fromList [(ident, R.ConstructorIndex index') | (index', (ident, _)) <- zip [3 ..] boxed]
    nominalRepresentations = Map.fromList [(ident, Erased) | (ident, node) <- Map.toList descriptors, isWrapper node] `Map.union` Map.map Boxed nominalIndices
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
    intrinsicLayouts = [R.Node origin (GeneratedOrigin "intrinsic layout" origin) (R.ConstructorLayout (R.FrameSize size) name) | (size, name) <- [(0, "[]"), (2, "::"), (2, "(*)")]]
    nominalLayouts = [fromCore node (R.ConstructorLayout (R.FrameSize (C.constructorArity (C.nodeValue node))) (T.pack (show ident))) | (ident, node) <- boxed]
    traits = Map.toAscList (Map.unions (map C.coreDictionaries modules))
    dictionaryIndices = Map.fromList [(ident, (R.ConstructorIndex index', length (C.dictionarySuperclasses (C.nodeValue node)))) | (index', (ident, node)) <- zip [3 + length boxed ..] traits]
    dictionaryLayouts = [fromCore node (R.ConstructorLayout (R.FrameSize (length (C.dictionarySuperclasses (C.nodeValue node)) + length (C.dictionaryMethods (C.nodeValue node)))) (T.pack (show ident))) | (ident, node) <- traits]

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
    (first : _, Just values) -> pure (generated first (R.GlobalGroup (case group of C.Recursive _ -> True; _ -> False) values))
    _ -> throwError [E.RuntimeError E.InvalidCore (Span "<runtime>" (Position 1 1 0) (Position 1 1 0)) "empty Core binding group"]

lowerBinding :: Context -> C.Binding C.CoreType -> Lower R.Binding
lowerBinding context source = do
  body <- expression context (C.bindingBody (C.nodeValue source))
  pure (fromCore source (R.Binding body (C.expansiveOrigin (C.bindingFacts (C.nodeValue source)))))

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
    Just address -> pure (fromCore source (R.Load address))
    Nothing -> fromCore source . R.Global <$> globalIndex context source reference
  C.Literal literal -> fromCore source . R.Literal <$> decodeLiteral source literal
  C.Lambda {} -> lowerLambda context source
  C.Apply f x -> do
    function <- expression context f
    argument <- expression context x
    pure (fromCore source (R.Call function (argument NE.:| [])))
  C.Let binding body -> do
    initializer <- lowerBinding context binding
    rest <- expression (withFrame [C.bindingReference (C.nodeValue binding)] context) body
    pure (fromCore source (R.Let initializer rest))
  C.LetRec bindings body -> do
    let inner = withFrame (map (C.bindingReference . C.nodeValue) (NE.toList bindings)) context
    initializers <- traverse (lowerBinding inner) bindings
    rest <- expression inner body
    pure (fromCore source (R.LetRec initializers rest))
  C.Construct constructor _ fields ->
    representation context source constructor >>= \case
      Erased -> case fields of [field] -> expression context field; _ -> failure E.InvalidCore source "wrapper has the wrong arity"
      Immediate literal -> pure (fromCore source (R.Literal literal))
      Boxed tag -> fromCore source . R.Construct tag <$> mapM (expression context) fields
  C.Case receiver alternatives fallback -> lowerCase context source receiver alternatives fallback
  C.If arms fallback -> do
    conditions <- forM arms $ \arm -> do
      let (test, body) = C.nodeValue arm
      condition <- expression context test
      result <- expression context body
      pure (fromCore arm (condition, result))
    rest <- traverse (expression context) fallback
    pure (fromCore source (R.If conditions rest))
  C.SelectField receiver (C.FieldId owner index') -> do
    constructor <- maybe (failure E.InvalidCore source "missing record descriptor") pure (Map.lookup owner (records context))
    representation context source constructor >>= \case
      Erased -> expression context receiver
      Boxed tag -> fromCore source . (\value -> R.Select value tag (R.FieldIndex index')) <$> expression context receiver
      Immediate _ -> failure E.InvalidCore source "record has an immediate representation"
  C.Dictionary owner _ supers methods -> do
    (tag, _) <- dictionary context source owner
    fields <- mapM (expression context) (supers ++ map (snd . C.nodeValue) methods)
    pure (fromCore source (R.Construct tag fields))
  C.SelectMethod receiver owner index' _ -> do
    (tag, offset) <- dictionary context source owner
    value <- expression context receiver
    pure (fromCore source (R.Select value tag (R.FieldIndex (offset + index'))))
  C.SelectSuperclass receiver owner index' -> do
    (tag, _) <- dictionary context source owner
    value <- expression context receiver
    pure (fromCore source (R.Select value tag (R.FieldIndex index')))
  C.ScopeTypes _ body -> expression context body
  C.Primitive primitive arguments -> do
    values <- mapM (expression context) arguments
    index' <- maybe (failure E.InvalidCore source "primitive is absent from the shared registry") pure (P.primitiveIndex primitive)
    pure (fromCore source (R.Primitive (R.PrimitiveIndex index') values))
  C.Fail -> pure (fromCore source R.MatchFailure)

lowerCase :: Context -> C.Expr C.CoreType -> C.Expr C.CoreType -> [C.Alternative C.CoreType] -> C.Expr C.CoreType -> Lower R.Expr
lowerCase context source receiver alternatives fallback = do
  value <- expression context receiver
  case alternatives of
    first : _
      | (C.ConstructorTest constructor _ [binder], body) <- C.nodeValue first ->
          representation context first constructor >>= \case
            Erased -> do
              result <- expression (withFrame [C.binderReference binder] context) body
              pure (fromCore source (R.Let (generated receiver (R.Binding value Nothing)) result))
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
        pure (fromCore arm (runtimeTest, branch))
      rest <- expression context fallback
      pure (fromCore source (R.Case value arms rest))

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
  let function = fromCore source (R.Function (R.Arity (length parameters)) (R.FrameSize (length parameters)) (R.CaptureLayout (length captured)) roles lowered)
  modify' (\s -> s {functions = IntMap.insert ident function (functions s)})
  pure (fromCore source (R.Closure (R.FunctionIndex ident) [generated source address | (_, address) <- captured]))

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
