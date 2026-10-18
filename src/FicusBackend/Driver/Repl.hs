-- | Interactive compilation and execution. Core exists only while preparing
-- a command; a session retains source snapshots, inferred types and closures.
module FicusBackend.Driver.Repl
  ( ReplOptions (..),
    Session,
    ReplCommand (..),
    parseCommand,
    newSession,
    loadSession,
    submit,
    inspectType,
  )
where

import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Compile qualified as C
import Ficus.Elaborate (checkedCore, checkedTypes)
import Ficus.Error.Diagnostic qualified as D
import Ficus.Library.Contracts
import Ficus.Resolve
import Ficus.Resolve.Provider qualified as P
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Concrete qualified as Concrete
import Ficus.Syntax.Core qualified as Core
import Ficus.Syntax.Core.Validate (validatedModule)
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Syntax.Parser (parseModule)
import Ficus.Type
import Ficus.Util.Source
import FicusBackend.Driver.Run (lowerCompilation)
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
    sessionLoaded :: Maybe ModuleId,
    sessionImports :: [Text],
    sessionDeclarations :: [Text],
    sessionTypes :: Map GlobalId (Scheme Core.CoreType),
    sessionInstance :: Maybe R.Instance
  }

data ReplCommand = Load FilePath | TypeOf Text | Quit | Submit Text | InvalidCommand Text deriving (Eq, Show)

parseCommand :: Text -> ReplCommand
parseCommand input = case T.words stripped of
  [] -> Submit ""
  command : arguments
    | ":" `T.isPrefixOf` command ->
        let argument = T.strip (T.drop (T.length command) stripped)
         in case command of
              ":q" -> quit arguments
              ":quit" -> quit arguments
              ":l" -> load argument
              ":load" -> load argument
              ":t" -> typeOf argument
              ":type" -> typeOf argument
              _ -> InvalidCommand "unknown command; use :load FILE, :type NAME, or :quit"
  _ -> Submit stripped
  where
    stripped = T.strip input
    quit [] = Quit
    quit _ = InvalidCommand ":quit takes no arguments"
    load argument
      | T.null argument = InvalidCommand ":load requires a file"
      | otherwise = Load (T.unpack (unquote argument))
    typeOf argument
      | T.null argument = InvalidCommand ":type requires a name"
      | otherwise = TypeOf argument
    unquote value
      | T.length value >= 2 && T.isPrefixOf "\"" value && T.isSuffixOf "\"" value = T.dropEnd 1 (T.drop 1 value)
      | otherwise = value

replOwner :: ModuleId
replOwner = ModuleId ("FicusInteractive" :| ["Session"])

anchor :: Span
anchor = Span "<repl>" (Position 1 1 0) (Position 1 1 0)

newSession :: ReplOptions -> IO (Either [D.Diagnostic] Session)
newSession options = do
  roots <- if null (replRoots options) then pure <$> getCurrentDirectory else mapM makeAbsolute (replRoots options)
  libraries <- mapM makeAbsolute (replLibraries options)
  prelude <- traverse makeAbsolute (replPrelude options)
  let config = P.ProviderConfig (nub (roots ++ libraries)) (maybe P.PreludeFromRoots P.PreludeFile prelude)
      session = Session options config Map.empty Nothing [] [] Map.empty Nothing
  compileSession session "" >>= install session

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
        [owner] | owner /= replOwner -> do
          searchRoots <- mapM makeAbsolute (roots ++ replLibraries options)
          let candidate =
                session
                  { sessionProvider = (sessionProvider session) {P.sourceRoots = nub searchRoots},
                    sessionSources = snapshots result,
                    sessionLoaded = Just owner,
                    sessionImports = [],
                    sessionDeclarations = []
                  }
          compileSession candidate "" >>= install candidate
        _ -> pure (Left [message "cannot select the loaded module (reserved interactive module or ambiguous identity)"])

sourceText :: Session -> Text -> Text
sourceText session suffix =
  T.unlines
    ( maybe [] (\owner -> ["use " <> moduleText owner <> " (..)"]) (sessionLoaded session)
        ++ sessionImports session
        ++ sessionDeclarations session
        ++ [suffix]
    )

provider :: Session -> Text -> P.ModuleProvider IO
provider session source owner
  | owner == replOwner = pure (Right (P.Source "<repl>" source))
  | otherwise = case Map.lookup owner (sessionSources session) of
      Just cached -> pure (Right cached)
      Nothing -> P.fileProvider (sessionProvider session) owner

compileSession :: Session -> Text -> IO C.CompileResult
compileSession session suffix = C.compileProvided libraryResolveConfig librarySugarRegistry (provider session (sourceText session suffix)) [(replOwner, anchor)]

snapshots :: C.CompileResult -> Map ModuleId P.Source
snapshots result =
  Map.fromList
    [ (owner, P.Source file text)
    | (owner, tree) <- Map.toList (frontendModules (C.compileFrontend result)),
      owner /= replOwner,
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

install :: Session -> C.CompileResult -> IO (Either [D.Diagnostic] Session)
install session result = case lowerCompilation result of
  Left diagnostics -> pure (Left diagnostics)
  Right lowered -> do
    initialized <- R.initialize R.ioEffects (R.compileProgram (loweredProgram lowered))
    pure $ case initialized of
      Left problem -> Left [D.toDiagnostic problem]
      Right instance' -> Right session {sessionSources = snapshots result, sessionTypes = types result, sessionInstance = Just instance'}

-- A successful declaration/import replaces the session transactionally.
-- Expression errors return diagnostics and leave the caller's session intact.
submit :: R.Effects -> Session -> Text -> IO (Either [D.Diagnostic] (Session, Maybe Text))
submit effects session input
  | T.null (T.strip input) = pure (Right (session, Nothing))
  | otherwise = case parseModule "<repl>" normalized of
      Right tree | not (null (Concrete.moduleImports tree)) && null (Concrete.moduleDeclarations tree) && null (Concrete.modulePragmas tree) -> do
        let candidate = session {sessionImports = sessionImports session ++ [normalized]}
        result <- compileSession candidate ""
        installed <- install candidate result
        pure ((\next -> (next, Nothing)) <$> installed)
      Right tree | null (Concrete.moduleImports tree) && not (null (Concrete.moduleDeclarations tree)) && null (Concrete.modulePragmas tree) -> do
        let candidate = session {sessionDeclarations = sessionDeclarations session ++ [input]}
        result <- compileSession candidate ""
        installed <- install candidate result
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
      case lowerCompilation result of
        Left diagnostics -> pure (Left diagnostics)
        Right lowered -> case Map.lookup (GlobalId replOwner ValueNS valueName) (loweredGlobals lowered) of
          Nothing -> pure (Left [message "interactive expression has no runtime address"])
          Just address -> case R.selectEntry (loweredProgram lowered) address of
            Left problem -> pure (Left [D.toDiagnostic problem])
            Right entry -> do
              outcome <- R.runProgram effects (R.compileProgram (loweredProgram lowered)) entry [R.LiteralValue Runtime.Unit]
              pure $ case outcome of
                Left problem -> Left [D.toDiagnostic problem]
                Right (R.LiteralValue (Runtime.String output)) -> Right (session, Just output)
                Right _ -> Left [message "interactive Debug result is not a string"]

inspectType :: Session -> Text -> IO (Either [D.Diagnostic] Text)
inspectType session name = do
  let queryName = freshName session "ficusReplInspect"
      suffix = queryName <> " () = " <> name
      source = sourceText session suffix
      queryLine = length (T.lines source)
  resolved <- resolveSources libraryResolveConfig librarySugarRegistry (provider session source) [replOwner]
  let errors = filter ((== D.Error) . D.diagnosticSeverity) (map D.toDiagnostic (frontendDiagnostics resolved))
  pure $
    if not (null errors)
      then Left errors
      else case Map.lookup replOwner (frontendModules resolved) of
        Nothing -> Left [message "type query did not resolve"]
        Just tree -> case [A.occurrenceReference occurrence | occurrence <- A.abstractOccurrences tree, line (start (A.occurrenceSpan occurrence)) == queryLine, A.occurrenceSpelling occurrence /= queryName] of
          [GlobalRef ident] -> case Map.lookup ident (sessionTypes session) of
            Just scheme -> Right (name <> " : " <> renderScheme scheme)
            Nothing -> Left [message "no inferred value type is available for this name"]
          _ -> Left [message ":type expects one value or constructor name"]

freshName :: Session -> Text -> Text
freshName session = choose
  where
    source = sourceText session ""
    choose candidate
      | candidate `T.isInfixOf` source = choose (candidate <> "'")
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
