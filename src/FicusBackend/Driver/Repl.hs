-- | Interactive compilation and execution. Core exists only while preparing
-- a command; a session retains source snapshots, inferred types and closures.
module FicusBackend.Driver.Repl
  ( ReplOptions (..),
    Session,
    ReplCommand (..),
    parseCommand,
    helpText,
    newSession,
    loadSession,
    submit,
    inspectType,
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

-- Empty project roots infer the loaded file's directory, or cwd without a file.
data ReplOptions = ReplOptions
  {replRoots :: [FilePath], replLibraries :: [FilePath], replPrelude :: Maybe FilePath}

data Session = Session
  { sessionOptions :: ReplOptions,
    sessionProvider :: P.ProviderConfig,
    sessionSources :: Map ModuleId P.Source,
    sessionScopes :: Map ModuleId NameSummary,
    sessionVisible :: NameSummary,
    sessionNext :: Int,
    sessionImports :: [Text],
    sessionTypes :: Map GlobalId (Scheme Core.CoreType),
    sessionTypeInfo :: Map GlobalId TypeInfo,
    sessionValues :: Map (ModuleId, Reference) R.Value,
    sessionLayouts :: Maybe RuntimeLayouts
  }

-- Only compact display metadata survives compilation, alongside value schemes.
data TypeInfo = TypeInfo Kind (Maybe Text)

data ReplCommand = Load FilePath | TypeOf Text | Help | Quit | Submit Text | InvalidCommand Text deriving (Eq, Show)

helpText :: Text
helpText =
  T.unlines
    [ ":help, :h          Show this help",
      ":load FILE, :l FILE  Load or reload a file and its dependencies",
      ":type NAME, :t NAME  Inspect a value, constructor, type, or trait",
      ":quit, :q          Exit the REPL",
      "Enter expressions or declarations; use/import declarations bring modules into scope."
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
      | T.null argument = InvalidCommand ":type requires a name"
      | otherwise = TypeOf argument
    unquote value
      | T.length value >= 2 && T.isPrefixOf "\"" value && T.isSuffixOf "\"" value = T.dropEnd 1 (T.drop 1 value)
      | otherwise = value

replOwner :: Session -> ModuleId
replOwner session = ModuleId ("FicusInteractive" :| ["Cell" <> T.justifyRight 12 '0' (T.pack (show (sessionNext session)))])

replPath :: Session -> FilePath
replPath session = "<repl:" ++ show (sessionNext session) ++ ">"

anchor :: Span
anchor = Span "<repl>" (Position 1 1 0) (Position 1 1 0)

newSession :: ReplOptions -> IO (Either [D.Diagnostic] Session)
newSession options = do
  roots <- if null (replRoots options) then pure <$> getCurrentDirectory else mapM makeAbsolute (replRoots options)
  libraries <- mapM makeAbsolute (replLibraries options)
  prelude <- traverse makeAbsolute (replPrelude options)
  let config = P.ProviderConfig (nub (roots ++ libraries)) (maybe P.PreludeFromRoots P.PreludeFile prelude)
      session = Session options config Map.empty Map.empty Map.empty 0 [] Map.empty Map.empty Map.empty Nothing
  compileSession session "" >>= install R.ioEffects session

loadSession :: Session -> FilePath -> IO (Either [D.Diagnostic] Session)
loadSession session file = do
  absolute <- normalise <$> makeAbsolute file
  let options = sessionOptions session
      roots = if null (replRoots options) then [takeDirectory absolute] else replRoots options
  result <- C.compileFiles libraryResolveConfig librarySugarRegistry (C.CompileOptions (absolute :| []) roots (replLibraries options) (replPrelude options))
  if not (C.compileSucceeded result)
    then pure (Left (C.compileDiagnostics result))
    else do
      let owners = [owner | (owner, tree) <- Map.toList (frontendModules (C.compileFrontend result)), normalise (sourceFile (A.abstractSpan tree)) == absolute]
      case owners of
        [owner] | not (interactiveOwner owner) -> do
          searchRoots <- mapM makeAbsolute (roots ++ replLibraries options)
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
          compileSession candidate "" >>= install R.ioEffects candidate
        _ -> pure (Left [message "cannot select the loaded module (reserved interactive module or ambiguous identity)"])

interactiveOwner :: ModuleId -> Bool
interactiveOwner (ModuleId (first :| _)) = first == "FicusInteractive"

sourceText :: Session -> Text -> Text
sourceText session suffix = T.unlines (dependencies ++ sessionImports session ++ [suffix])
  where
    owners = Set.toAscList (Set.fromList [owner | entity <- Map.elems (sessionVisible session), GlobalId owner _ _ <- [entityId entity]])
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
    kinds = Map.unions [Core.coreKinds (validatedModule (checkedCore checked)) | checked <- Map.elems (C.compileModules result)]
    traits =
      Map.fromList
        [ (ident, T.strip (T.take (offset (end site) - offset (start site) + 1) (T.drop (offset (start site)) source)))
        | tree <- Map.elems (frontendModules (C.compileFrontend result)),
          declaration <- A.declarations (A.abstractDeclarations tree),
          A.TraitDefinition ident _ _ _ <- [A.nodeValue declaration],
          let site = A.nodeSpan declaration,
          Just source <- [Map.lookup (sourceFile site) (C.compileSources result)]
        ]
    describe ident kind = TypeInfo kind (Map.lookup ident traits)

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
            session
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

-- A successful declaration/import replaces the session transactionally.
-- Expression errors return diagnostics and leave the caller's session intact.
submit :: R.Effects -> Session -> Text -> IO (Either [D.Diagnostic] (Session, Maybe Text))
submit effects session input
  | T.null (T.strip input) = pure (Right (session, Nothing))
  | otherwise = case parseModule "<repl>" normalized of
      Right tree | not (null (Concrete.moduleImports tree)) && null (Concrete.moduleDeclarations tree) && null (Concrete.modulePragmas tree) -> do
        let candidate = session {sessionImports = sessionImports session ++ [normalized]}
        result <- compileSession candidate ""
        installed <- install effects candidate result
        pure ((\next -> (next, Nothing)) <$> installed)
      Right tree | null (Concrete.moduleImports tree) && not (null (Concrete.moduleDeclarations tree)) && null (Concrete.modulePragmas tree) -> do
        result <- compileSession session input
        installed <- install effects session result
        pure ((\next -> (next, Nothing)) <$> installed)
      _ -> evaluateExpression
  where
    normalized = case T.stripPrefix "import " (T.strip input) of
      Just imported -> "use " <> imported <> if length (T.words imported) == 1 then " (..)" else ""
      Nothing -> input
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
                Right (R.LiteralValue (Runtime.String output)) -> Right (session, Just output)
                Right _ -> Left [message "interactive Debug result is not a string"]

inspectType :: Session -> Text -> IO (Either [D.Diagnostic] Text)
inspectType session name = do
  typeReference <- resolveQuery (freshName session "FicusReplInspect") " = "
  case typeReference >>= lookupTypeInfo of
    Right (TypeInfo kind declaration) -> pure (Right (name <> " : " <> renderKind kind <> maybe "" ("\n" <>) declaration))
    Left _ -> do
      valueReference <- resolveQuery (freshName session "ficusReplInspect") " () = "
      pure $ do
        ident <- valueReference
        case Map.lookup ident (sessionTypes session) of
          Just scheme -> Right (name <> " : " <> renderScheme scheme)
          Nothing -> Left [message "no inferred value type is available for this name"]
  where
    lookupTypeInfo ident = case Map.lookup ident (sessionTypeInfo session) of
      Just info -> Right info
      Nothing -> case ident of
        IntrinsicId intrinsic -> Right (TypeInfo (primitiveKind intrinsic) Nothing)
        _ -> Left [message "no inferred kind is available for this name"]
    resolveQuery queryName separator = do
      let source = sourceText session (queryName <> separator <> name)
          queryLine = length (T.lines source)
      graph <- discoverModules (provider session source) [replOwner session]
      let resolved = resolveGraphWithNames (scopes session) libraryResolveConfig librarySugarRegistry graph
          errors = filter ((== D.Error) . D.diagnosticSeverity) (map D.toDiagnostic (frontendDiagnostics resolved))
      pure $
        if not (null errors)
          then Left errors
          else case Map.lookup (replOwner session) (frontendModules resolved) of
            Nothing -> Left [message "type query did not resolve"]
            Just tree -> case [A.occurrenceReference occurrence | occurrence <- A.abstractOccurrences tree, line (start (A.occurrenceSpan occurrence)) == queryLine, A.occurrenceSpelling occurrence /= queryName] of
              [GlobalRef ident] -> Right ident
              _ -> Left [message ":type expects one value, constructor, type, or trait name"]

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
