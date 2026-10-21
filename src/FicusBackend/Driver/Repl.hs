-- | Interactive compilation and execution. Core exists only while preparing
-- a command; a session retains source snapshots, inferred types and closures.
module FicusBackend.Driver.Repl
  ( Session,
    sessionDiagnostics,
    sessionDiagnosticSources,
    ReplCommand (..),
    parseCommand,
    readCommand,
    helpText,
    newSession,
    loadSession,
    submit,
    inspectType,
    inspectKind,
  )
where

import Control.Monad (forM)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Compile qualified as C
import Ficus.Elaborate (checkedCore, checkedTypes)
import Ficus.Error.Diagnostic qualified as D
import Ficus.Library.Contracts
import Ficus.ModuleOptions (ModuleOptions (..))
import Ficus.Resolve
import Ficus.Resolve.Discovery (discoverModules)
import Ficus.Resolve.Header (scanHeader)
import Ficus.Resolve.Provider qualified as P
import Ficus.Resolve.Scope
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Concrete qualified as Concrete
import Ficus.Syntax.Core qualified as Core
import Ficus.Syntax.Core.Validate (validatedModule)
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Syntax.Parser (parseModule)
import Ficus.Type
import Ficus.Util.Source
import FicusBackend.Lower.Runtime
import FicusBackend.Runtime qualified as R
import FicusBackend.Runtime.AST qualified as Runtime
import System.Directory (getCurrentDirectory, makeAbsolute)
import System.FilePath (normalise, takeDirectory)

data Session = Session
  { sessionOptions :: ModuleOptions,
    sessionProvider :: P.ProviderConfig,
    sessionSources :: Map ModuleId P.Source,
    sessionScopes :: Map ModuleId NameSummary,
    sessionVisible :: NameSummary,
    sessionNext :: Int,
    sessionImports :: [Text],
    sessionTypes :: Map GlobalId (Scheme Core.CoreType),
    sessionTypeInfo :: Map GlobalId TypeInfo,
    sessionValues :: Map (ModuleId, Reference) R.Value,
    sessionLayouts :: Maybe RuntimeLayouts,
    sessionDiagnostics :: [D.Diagnostic],
    sessionDiagnosticSources :: Map FilePath Text
  }

-- Only compact display metadata survives compilation, alongside value schemes.
data TypeInfo = TypeInfo Text Bool

data ReplCommand = Load FilePath | TypeOf Text | KindOf Text | Help | Quit | Submit Text | InvalidCommand Text deriving (Eq, Show)

helpText :: Text
helpText =
  T.unlines
    [ ":help, :h          Show this help",
      ":load FILE, :l FILE  Load or reload a file and its dependencies",
      ":type EXPR, :t EXPR  Infer a term expression's type without evaluation",
      ":kind TYPE, :k TYPE  Infer a type-level expression's kind",
      ":quit, :q          Exit the REPL",
      ":{                 Begin multiline input; end with :} on its own line",
      "Enter expressions or declarations; use declarations bring modules into scope."
    ]

parseCommand :: Text -> ReplCommand
parseCommand input = case T.words stripped of
  [] -> Submit ""
  command : arguments
    | ":" `T.isPrefixOf` command ->
        let argument = T.strip (T.drop (T.length command) stripped)
         in case command of
              ":q" -> quit arguments
              ":quit" -> quit arguments
              ":h" -> help arguments
              ":help" -> help arguments
              ":l" -> load argument
              ":load" -> load argument
              ":t" -> typeOf argument
              ":type" -> typeOf argument
              ":k" -> kindQuery argument
              ":kind" -> kindQuery argument
              ":}" -> InvalidCommand "no multiline input is open"
              _ -> InvalidCommand "unknown command; use :help for available commands"
  _ -> Submit stripped
  where
    stripped = T.strip input
    quit [] = Quit
    quit _ = InvalidCommand ":quit takes no arguments"
    help [] = Help
    help _ = InvalidCommand ":help takes no arguments"
    load argument
      | T.null argument = InvalidCommand ":load requires a file"
      | otherwise = Load (T.unpack (unquote argument))
    typeOf argument
      | T.null argument = InvalidCommand ":type requires an expression or name"
      | otherwise = TypeOf argument
    kindQuery argument
      | T.null argument = InvalidCommand ":kind requires a type-level expression"
      | otherwise = KindOf argument
    unquote value
      | T.length value >= 2 && T.isPrefixOf "\"" value && T.isSuffixOf "\"" value = T.dropEnd 1 (T.drop 1 value)
      | otherwise = value

-- | Collect a complete submission before parsing or executing any source.
-- Keeping the line reader injectable lets terminal and scripted input share
-- the same delimiter handling without depending on a terminal library here.
readCommand :: (Monad m) => (Text -> m (Maybe Text)) -> m (Maybe ReplCommand)
readCommand readLine = do
  input <- readLine "ficus> "
  case input of
    Nothing -> pure Nothing
    Just line
      | T.strip line == ":{" -> multiline []
      | otherwise -> pure (Just (parseCommand line))
  where
    multiline reversed = do
      input <- readLine "ficus| "
      case input of
        Nothing -> pure Nothing
        Just line
          | T.strip line == ":}" -> pure (Just (Submit (T.unlines (reverse reversed))))
          | otherwise -> multiline (line : reversed)

replOwner :: Session -> ModuleId
replOwner session = ModuleId ("FicusInteractive" :| ["Cell" <> T.justifyRight 12 '0' (T.pack (show (sessionNext session)))])

replPath :: Session -> FilePath
replPath session = "<repl:" ++ show (sessionNext session) ++ ">"

anchor :: Span
anchor = Span "<repl>" (Position 1 1 0) (Position 1 1 0)

newSession :: ModuleOptions -> IO (Either [D.Diagnostic] Session)
newSession options = do
  roots <- if null (sourceRoots options) then pure <$> getCurrentDirectory else mapM makeAbsolute (sourceRoots options)
  libraries <- mapM makeAbsolute (libraryRoots options)
  prelude <- traverse makeAbsolute (preludeFile options)
  let config = P.ProviderConfig (nub (roots ++ libraries)) (maybe P.PreludeFromRoots P.PreludeFile prelude)
      session = Session options config Map.empty Map.empty Map.empty 0 [] Map.empty Map.empty Map.empty Nothing [] Map.empty
  compileSession session "" >>= install R.ioEffects session

loadSession :: Session -> FilePath -> IO (Either [D.Diagnostic] Session)
loadSession session file = do
  absolute <- normalise <$> makeAbsolute file
  let options = sessionOptions session
      roots = if null (sourceRoots options) then [takeDirectory absolute] else sourceRoots options
  result <- C.compileFiles libraryResolveConfig librarySugarRegistry (options {sourceRoots = roots}) (absolute :| [])
  if not (C.compileSucceeded result)
    then pure (Left (C.compileDiagnostics result))
    else do
      let owners = [owner | (owner, tree) <- Map.toList (frontendModules (C.compileFrontend result)), normalise (sourceFile (A.abstractSpan tree)) == absolute]
      case owners of
        [owner] | not (interactiveOwner owner) -> do
          searchRoots <- mapM makeAbsolute (roots ++ libraryRoots options)
          let ordinary = Map.findWithDefault Map.empty owner (Map.map A.abstractExports (frontendModules (C.compileFrontend result)))
              candidate =
                session
                  { sessionProvider = (sessionProvider session) {P.sourceRoots = nub searchRoots},
                    sessionSources = snapshots result,
                    sessionScopes = Map.empty,
                    sessionVisible = ordinary,
                    sessionNext = 0,
                    sessionImports = [],
                    sessionTypes = Map.empty,
                    sessionTypeInfo = Map.empty,
                    sessionValues = Map.empty,
                    sessionLayouts = Nothing
                  }
          installed <- compileSession candidate "" >>= install R.ioEffects candidate
          pure (withDiagnostics (session {sessionSources = Map.empty}) result <$> installed)
        _ -> pure (Left [message "cannot select the loaded module (reserved interactive module or ambiguous identity)"])

interactiveOwner :: ModuleId -> Bool
interactiveOwner (ModuleId (first :| _)) = first == "FicusInteractive"

sourceText :: Session -> Text -> Text
sourceText session suffix = T.unlines (dependencies ++ sessionImports session ++ [suffix])
  where
    owners = Set.toAscList (Map.keysSet (sessionScopes session) `Set.union` Set.fromList [owner | entity <- Map.elems (sessionVisible session), GlobalId owner _ _ <- [entityId entity]])
    dependencies = ["use " <> moduleText owner <> " as FicusReplDependency" <> T.pack (show index) | (index, owner) <- zip [0 :: Int ..] owners]

provider :: Session -> Text -> P.ModuleProvider IO
provider session source owner
  | owner == replOwner session = pure (Right (P.Source (replPath session) source))
  | otherwise = case Map.lookup owner (sessionSources session) of
      Just cached -> pure (Right cached)
      Nothing -> P.fileProvider (sessionProvider session) owner

scopes :: Session -> Map ModuleId NameSummary
scopes session = Map.insert (replOwner session) (sessionVisible session) (sessionScopes session)

compileSession :: Session -> Text -> IO C.CompileResult
compileSession session suffix = C.compileInteractiveProvided (scopes session) libraryResolveConfig librarySugarRegistry (provider session (sourceText session suffix)) [(replOwner session, anchor {sourceFile = replPath session})]

snapshots :: C.CompileResult -> Map ModuleId P.Source
snapshots result =
  Map.fromList
    [ (owner, P.Source file text)
    | (owner, tree) <- Map.toList (frontendModules (C.compileFrontend result)),
      let file = sourceFile (A.abstractSpan tree),
      Just text <- [Map.lookup file (C.compileSources result)]
    ]

types :: C.CompileResult -> Map GlobalId (Scheme Core.CoreType)
types result =
  Map.unions
    [ Map.fromList [(ident, scheme) | (GlobalRef ident, scheme) <- Map.toList (checkedTypes checked)]
        `Map.union` Map.fromList [(ident, Core.constructorScheme (Core.nodeValue descriptor)) | (Core.DataConstructor ident, descriptor) <- Map.toList (Core.coreConstructors core)]
    | checked <- Map.elems (C.compileModules result),
      let core = validatedModule (checkedCore checked)
    ]

typeInfo :: C.CompileResult -> Map GlobalId TypeInfo
typeInfo result = Map.mapWithKey describe kinds
  where
    cores = [validatedModule (checkedCore checked) | checked <- Map.elems (C.compileModules result)]
    kinds = Map.unions (map Core.coreKinds cores)
    traitParameters = Map.unions [Map.map (quantifierKind . Core.dictionaryParameter . Core.nodeValue) (Core.coreDictionaries core) | core <- cores]
    describe ident kind = TypeInfo displayKind (Map.member ident traitParameters)
      where
        -- Core represents dictionary types with a Type result. Interactive
        -- inspection presents the source trait's Constraint result instead.
        displayKind = case Map.lookup ident traitParameters of
          Just parameter -> domain parameter <> " -> Constraint"
          Nothing -> renderKind kind
        domain TypeKind = "Type"
        domain parameter = "(" <> renderKind parameter <> ")"

lowerSession :: Session -> C.CompileResult -> Either [D.Diagnostic] LoweredProgram
lowerSession session result
  | not (C.compileSucceeded result) = Left (C.compileDiagnostics result)
  | otherwise =
      either
        (Left . map D.toDiagnostic)
        Right
        ( lowerProgramWithLayouts
            (sessionLayouts session)
            [validatedModule (checkedCore checked) | owner <- C.compileOrder result, Just checked <- [Map.lookup owner (C.compileModules result)]]
        )

initializeSession :: R.Effects -> Session -> LoweredProgram -> IO (Either [D.Diagnostic] R.Instance)
initializeSession effects session lowered = do
  let cached = Map.fromList [(address, value) | (ident, value) <- Map.toList (sessionValues session), Just address <- [Map.lookup ident (loweredBindings lowered)]]
  either (Left . pure . D.toDiagnostic) Right <$> R.initializeWith effects (R.compileProgram (loweredProgram lowered)) cached

install :: R.Effects -> Session -> C.CompileResult -> IO (Either [D.Diagnostic] Session)
install effects session result = case prepare of
  Left diagnostics -> pure (Left diagnostics)
  Right (lowered, visible) -> do
    initialized <- initializeSession effects session lowered
    case initialized of
      Left diagnostics -> pure (Left diagnostics)
      Right instance' -> do
        values <- forM (Map.toList (loweredBindings lowered)) $ \(ident, address) -> case R.selectEntry (loweredProgram lowered) address of
          Left problem -> pure (Left [D.toDiagnostic problem])
          Right entry -> fmap (either (Left . pure . D.toDiagnostic) (Right . (ident,))) (R.evaluateEntry instance' entry [])
        let source = Map.lookup (replPath session) (C.compileSources result)
            oldSources = Map.filterWithKey (\owner _ -> not (interactiveOwner owner)) (snapshots result) `Map.union` sessionSources session
            savedSources = maybe oldSources (\text -> Map.insert (replOwner session) (P.Source (replPath session) text) oldSources) source
        pure $ do
          stored <- sequence values
          Right
            (withDiagnostics session result session)
              { sessionSources = savedSources,
                sessionScopes = scopes session,
                sessionVisible = visible,
                sessionNext = sessionNext session + 1,
                sessionTypes = types result `Map.union` sessionTypes session,
                sessionTypeInfo = typeInfo result `Map.union` sessionTypeInfo session,
                sessionValues = Map.fromList stored `Map.union` sessionValues session,
                sessionLayouts = Just (loweredLayouts lowered)
              }
  where
    prepare = do
      tree <- maybe (Left [message "interactive module did not resolve"]) Right (Map.lookup (replOwner session) (frontendModules (C.compileFrontend result)))
      let own = A.abstractExports tree
          previous = sessionVisible session
          replacements = [(entityId old, entityId new) | ((TypeNS, name), new) <- Map.toList own, Just old <- [Map.lookup (TypeNS, name) previous], entityId old /= entityId new]
          collisions =
            [ new
            | (key@(ConstructorNS, _), new) <- Map.toList own,
              Just old <- [Map.lookup key previous],
              entityId old /= entityId new,
              (entityOwner old, entityOwner new) `notElem` [(Just before, Just after) | (before, after) <- replacements]
            ]
      case collisions of
        constructor : _ -> Left [(message "constructor name belongs to a different visible type") {D.diagnosticSpan = entitySpan constructor}]
        [] -> pure ()
      lowered <- lowerSession session result
      let imported = case Map.lookup (replPath session) (C.compileSources result) >>= either (const Nothing) Just . parseModule (replPath session) of
            Nothing -> Map.empty
            Just concrete ->
              let (header, _) = scanHeader (replOwner session) concrete
                  (scope, _, _) = buildScope header concrete own (frontendInterfaces (C.compileFrontend result))
               in Map.mapMaybe (\case [Candidate entity _] -> Just entity; _ -> Nothing) (openedNames scope)
          keep entity = constructorVisible (own `Map.union` previous) entity
          visible = own `Map.union` Map.filter keep previous `Map.union` Map.filter keep imported
      Right (lowered, visible)

-- Keep warnings from this command and newly loaded dependencies, with their
-- source excerpts. Older accepted cells are rechecked but must not warn again.
withDiagnostics :: Session -> C.CompileResult -> Session -> Session
withDiagnostics previous result next =
  let previousFiles = Set.fromList (map P.sourcePath (Map.elems (sessionSources previous)))
      warnings = [problem | problem <- C.compileDiagnostics result, D.diagnosticSeverity problem == D.Warning, Set.notMember (sourceFile (D.diagnosticSpan problem)) previousFiles]
      files = Set.fromList (map (sourceFile . D.diagnosticSpan) warnings)
   in next {sessionDiagnostics = warnings, sessionDiagnosticSources = Map.restrictKeys (C.compileSources result) files}

-- A successful declaration/import replaces the session transactionally.
-- Expression errors return diagnostics and leave the caller's session intact.
submit :: R.Effects -> Session -> Text -> IO (Either [D.Diagnostic] (Session, Maybe Text))
submit effects session input
  | T.null (T.strip input) = pure (Right (session {sessionDiagnostics = [], sessionDiagnosticSources = Map.empty}, Nothing))
  | otherwise = case parseModule "<repl>" input of
      Right tree | not (null (Concrete.moduleImports tree)) && null (Concrete.moduleDeclarations tree) && null (Concrete.modulePragmas tree) -> do
        let candidate = session {sessionImports = sessionImports session ++ [input]}
        result <- compileSession candidate ""
        installed <- install effects candidate result
        pure ((\next -> (next, Nothing)) <$> installed)
      Right tree | null (Concrete.moduleImports tree) && not (null (Concrete.moduleDeclarations tree)) && null (Concrete.modulePragmas tree) -> do
        result <- compileSession session input
        installed <- install effects session result
        pure ((\next -> (next, Nothing)) <$> installed)
      _ -> evaluateExpression
  where
    valueName = freshName session "ficusReplValue"
    debugName = freshName session "FicusReplDebug"
    evaluateExpression = do
      -- The thunk preserves ordinary v0 restrictions on top-level initialization.
      result <- compileSession (session {sessionImports = sessionImports session ++ ["use Class.Debug as " <> debugName]}) (valueName <> " () = " <> debugName <> ".debug (" <> input <> ")")
      case lowerSession session result of
        Left diagnostics -> pure (Left diagnostics)
        Right lowered -> case Map.lookup (GlobalId (replOwner session) ValueNS valueName) (loweredGlobals lowered) of
          Nothing -> pure (Left [message "interactive expression has no runtime address"])
          Just address -> case R.selectEntry (loweredProgram lowered) address of
            Left problem -> pure (Left [D.toDiagnostic problem])
            Right entry -> do
              initialized <- initializeSession effects session lowered
              outcome <- case initialized of
                Left diagnostics -> pure (Left diagnostics)
                Right instance' -> either (Left . pure . D.toDiagnostic) Right <$> R.evaluateEntry instance' entry [R.LiteralValue Runtime.Unit]
              pure $ case outcome of
                Left diagnostics -> Left diagnostics
                Right (R.LiteralValue (Runtime.String output)) -> Right (withDiagnostics session result session, Just output)
                Right _ -> Left [message "interactive Debug result is not a string"]

inspectType :: Session -> Text -> IO (Either [D.Diagnostic] Text)
inspectType session name = do
  valueReference <- resolveInspectionName session (freshName session "ficusReplInspect") " () = " name
  case valueReference >>= storedScheme of
    Right scheme -> pure (Right (name <> " : " <> renderScheme scheme))
    Left _ -> inferExpression
  where
    storedScheme ident = maybe (Left [message "no inferred value type is available for this name"]) Right (Map.lookup ident (sessionTypes session))
    inferExpression = do
      let queryName = freshName session "ficusReplInspect"
      -- A thunk permits ordinary expression inference and generalization,
      -- without initializing or running any compiled code.
      result <- compileSession session (queryName <> " () = (" <> name <> ")")
      pure $
        if not (C.compileSucceeded result)
          then Left (C.compileDiagnostics result)
          else case Map.lookup (GlobalId (replOwner session) ValueNS queryName) (types result) of
            Just scheme
              | Just (_, expressionType) <- functionParts (schemeType scheme) ->
                  Right (name <> " : " <> renderScheme (scheme {schemeType = expressionType}))
            _ -> Left [message "expression query has no inferred type"]

inspectKind :: Session -> Text -> IO (Either [D.Diagnostic] Text)
inspectKind session name = do
  typeReference <- resolveInspectionName session (freshName session "FicusReplInspect") " = " name
  case typeReference >>= lookupTypeInfo of
    Right (TypeInfo kind _) -> pure (Right (name <> " : " <> kind))
    Left _ -> inferExpression
  where
    inferExpression = do
      let queryName = freshName session "FicusReplInspect"
      result <- compileSession session (queryName <> " = " <> name)
      let info = typeInfo result
          tree = Map.lookup (replOwner session) (frontendModules (C.compileFrontend result))
          predicates =
            [ ()
            | Just source <- [tree],
              declaration <- A.declarations (A.abstractDeclarations source),
              A.AliasDefinition _ _ _ body <- [A.nodeValue declaration],
              A.TypeApplication trait _ <- [A.nodeValue body],
              A.TypeConstructor ident <- [A.nodeValue trait],
              Just (TypeInfo _ True) <- [Map.lookup ident info]
            ]
      pure $
        if not (C.compileSucceeded result)
          then Left (C.compileDiagnostics result)
          else case Map.lookup (GlobalId (replOwner session) TypeNS queryName) info of
            Just (TypeInfo kind _) -> Right (name <> " : " <> if null predicates then kind else "Constraint")
            Nothing -> Left [message "type-level query has no inferred kind"]
    lookupTypeInfo ident = case Map.lookup ident (sessionTypeInfo session) of
      Just info -> Right info
      Nothing -> case ident of
        IntrinsicId intrinsic -> Right (TypeInfo (renderKind (primitiveKind intrinsic)) False)
        _ -> Left [message "no inferred kind is available for this name"]

resolveInspectionName :: Session -> Text -> Text -> Text -> IO (Either [D.Diagnostic] GlobalId)
resolveInspectionName session queryName separator name = do
  let source = sourceText session (queryName <> separator <> name)
  graph <- discoverModules (provider session source) [replOwner session]
  let resolved = resolveGraphWithNames (scopes session) libraryResolveConfig librarySugarRegistry graph
      errors = filter ((== D.Error) . D.diagnosticSeverity) (map D.toDiagnostic (frontendDiagnostics resolved))
  pure $
    if not (null errors)
      then Left errors
      else case Map.lookup (replOwner session) (frontendModules resolved) of
        Nothing -> Left [message "type query did not resolve"]
        Just tree -> case map A.nodeValue (A.declarations (A.abstractDeclarations tree)) of
          [A.AliasDefinition _ _ _ body] | A.TypeConstructor ident <- A.nodeValue body -> Right ident
          [A.ValueDefinition _ _ (A.ClausesBody _ (clause :| []))] -> case A.nodeValue (A.clauseBody (A.nodeValue clause)) of
            A.Ref (GlobalRef ident) -> Right ident
            A.Constructor ident -> Right ident
            A.Method ident -> Right ident
            _ -> Left [message "query is an expression"]
          _ -> Left [message "query is not a single name"]

freshName :: Session -> Text -> Text
freshName session = choose
  where
    source = sourceText session ""
    choose candidate
      | candidate `T.isInfixOf` source || any ((== candidate) . snd) (Map.keys (sessionVisible session)) = choose (candidate <> "'")
      | otherwise = candidate

renderScheme :: Scheme Core.CoreType -> Text
renderScheme scheme = explicit <> constraints <> render (schemeType scheme)
  where
    names = Map.fromList [(quantifierId q, if index < 26 then T.singleton (toEnum (fromEnum 'a' + index)) else "a" <> T.pack (show index)) | (index, q) <- zip [0 :: Int ..] (quantifiers scheme)]
    variable (Core.BoundVariable ident) = Map.findWithDefault (renderBound ident) ident names
    variable (Core.DiagnosticVariable _) = "_"
    render = renderType variable
    explicit = T.concat ["{" <> Map.findWithDefault (quantifierName q) (quantifierId q) names <> "} -> " | q <- explicitQuantifiers scheme]
    predicates = [renderConstructor (predicateTrait predicate) <> " " <> render (predicateArgument predicate) | predicate <- schemePredicates scheme]
    constraints = case predicates of [] -> ""; [predicate] -> predicate <> " => "; _ -> "(" <> T.intercalate ", " predicates <> ") => "

message :: Text -> D.Diagnostic
message text = D.Diagnostic "R0104" D.Error anchor text Nothing []
