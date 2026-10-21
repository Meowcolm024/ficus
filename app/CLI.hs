module CLI (main) where

import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Version (showVersion)
import Ficus.Compile qualified as Compile
import Ficus.Error.Diagnostic qualified as Diagnostic
import Ficus.Error.Pretty (DiagnosticStyle (..), prettyDiagnosticWithStyleRelativeTo)
import Ficus.Library.Contracts
import Ficus.ModuleOptions (ModuleOptions (..))
import Ficus.Resolve (frontendModules)
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Concrete.Pretty (prettyModule)
import Ficus.Syntax.Name (ModuleId)
import Ficus.Syntax.Parser (parseModule)
import Ficus.Util.Source (Position (..), Span (..))
import FicusBackend.Driver.Repl qualified as Repl
import FicusBackend.Driver.Run qualified as Run
import FicusBackend.Runtime qualified as Runtime
import FicusLsp qualified as Lsp
import Options.Applicative
import Paths_ficus qualified as Paths
import System.Console.ANSI (hSupportsANSIColor)
import System.Console.Haskeline
import System.Directory (getCurrentDirectory, makeAbsolute)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.FilePath (normalise)
import System.IO (stderr)
import System.IO.Error (tryIOError)

data Command = Format (Maybe FilePath) | Compile (NonEmpty FilePath) ModuleOptions | Run FilePath [String] ModuleOptions | Repl (Maybe FilePath) ModuleOptions | Lsp ModuleOptions

data CLIOptions = CLIOptions Bool Command

main :: IO ()
main = do
  CLIOptions noColor commandToRun <- execParser commandInfo
  diagnosticStyle <- if noColor then pure Plain else terminalDiagnosticStyle
  case commandToRun of
    Lsp options -> do
      configured <- configure options
      status <- Lsp.run configured
      if status == 0 then pure () else exitWith (ExitFailure status)
    Compile files options -> do
      configured <- configure options
      result <- Compile.compileFiles libraryResolveConfig librarySugarRegistry configured files
      directory <- getCurrentDirectory
      mapM_ (printDiagnostic diagnosticStyle directory (Compile.compileSources result)) (Compile.compileDiagnostics result)
      if Compile.compileSucceeded result then pure () else exitFailure
    Run file arguments options -> do
      configured <- configure options
      result <- Compile.compileFiles libraryResolveConfig librarySugarRegistry configured (file :| [])
      report diagnosticStyle (Compile.compileSources result) (Compile.compileDiagnostics result)
      if not (Compile.compileSucceeded result)
        then exitFailure
        else do
          owner <- selectedModule file result
          case owner >>= (\ident -> Run.prepareRun ident result) of
            Left errors -> report diagnosticStyle (Compile.compileSources result) errors >> exitFailure
            Right plan ->
              Run.executeRun Runtime.ioEffects plan (map T.pack arguments) >>= \case
                Left problem -> report diagnosticStyle (Compile.compileSources result) [Diagnostic.toDiagnostic problem] >> exitFailure
                Right (Just message) -> T.hPutStrLn stderr message >> exitFailure
                Right Nothing -> pure ()
    Repl file options -> do
      configured <- configure options
      initial <- Repl.newSession configured
      case initial of
        Left errors -> report diagnosticStyle Map.empty errors >> exitFailure
        Right session -> do
          loaded <- case file of
            Nothing -> pure session
            Just path -> Repl.loadSession session path >>= either (\errors -> report diagnosticStyle Map.empty errors >> pure session) pure
          report diagnosticStyle (Repl.sessionDiagnosticSources loaded) (Repl.sessionDiagnostics loaded)
          runInputT defaultSettings (replLoop diagnosticStyle loaded)
    Format path -> do
      let sourceName = case path of Nothing -> "<stdin>"; Just "-" -> "<stdin>"; Just file -> file
      input <- tryIOError (case path of Nothing -> T.getContents; Just "-" -> T.getContents; Just file -> T.readFile file)
      case input of
        Left err -> T.hPutStrLn stderr (T.pack (show err)) >> exitFailure
        Right source -> case parseModule sourceName source of
          Left diagnostic -> do
            directory <- getCurrentDirectory
            printDiagnostic diagnosticStyle directory (Map.singleton sourceName source) diagnostic
            exitFailure
          Right concreteModule -> T.putStr (prettyModule concreteModule)

printDiagnostic :: (Diagnostic.ToDiagnostic d) => DiagnosticStyle -> FilePath -> Map.Map FilePath T.Text -> d -> IO ()
printDiagnostic diagnosticStyle directory sources diagnostic = do
  let file = sourceFile (Diagnostic.diagnosticSpan (Diagnostic.toDiagnostic diagnostic))
  T.hPutStrLn stderr (prettyDiagnosticWithStyleRelativeTo diagnosticStyle directory (Map.lookup file sources) diagnostic)

terminalDiagnosticStyle :: IO DiagnosticStyle
terminalDiagnosticStyle = do
  terminal <- hSupportsANSIColor stderr
  pure $ if terminal then Ansi else Plain

versionText :: String
versionText = showVersion Paths.version

commandInfo :: ParserInfo CLIOptions
commandInfo =
  info
    ((CLIOptions <$> switch (long "no-color" <> help "Disable ANSI colors in diagnostics") <*> commands) <**> simpleVersioner versionText <**> helper)
    (fullDesc <> progDesc "Ficus language tools")
  where
    commands =
      hsubparser
        ( command "format" (info formatCommand (progDesc "Pretty-print a source file or stdin to stdout"))
            <> command "run" (info runCommand (progDesc "Run a file with a valid main entry point"))
            <> command "repl" (info replCommand (progDesc "Start an interactive session, optionally loading a file"))
            <> command "lsp" (info (Lsp <$> searchOptions) (progDesc "Start the Language Server Protocol server on stdin/stdout"))
            <> command "compile" (info compileCommand (progDesc "Typecheck and elaborate source modules; emit no artifacts" <> footer "Library discovery options are for early development and are subject to change."))
        )
    formatCommand = Format <$> optional (strArgument (metavar "FILE" <> help "Source file; omit or use - for stdin")) <**> helper
    -- some rejects empty input and renders one repeated-argument help entry;
    -- its nonempty result makes the conversion to NonEmpty safe.
    compileCommand =
      Compile
        <$> (NE.fromList <$> some inputFile)
        <*> searchOptions

    inputFile = strArgument (metavar "FILE..." <> help "Ficus source files to check")

    runCommand = Run <$> strArgument (metavar "FILE") <*> many (strArgument (metavar "ARGS...")) <*> searchOptions
    replCommand = Repl <$> optional (strArgument (metavar "FILE")) <*> searchOptions
    searchOptions =
      ModuleOptions
        <$> many (strOption (long "source-root" <> metavar "DIR" <> help "Project source root (repeatable); defaults to input file directories or cwd"))
        <*> many (strOption (long "library" <> metavar "DIR" <> help "Library source root (repeatable); defaults to bundled library"))
        <*> optional (strOption (long "prelude" <> metavar "FILE" <> help "Override the Prelude file"))

configure :: ModuleOptions -> IO ModuleOptions
configure options = do
  libraries <- if null (libraryRoots options) then pure <$> Paths.getDataFileName "library" else pure (libraryRoots options)
  pure (options {libraryRoots = libraries})

report :: DiagnosticStyle -> Map.Map FilePath T.Text -> [Diagnostic.Diagnostic] -> IO ()
report diagnosticStyle sources errors = do
  directory <- getCurrentDirectory
  forM_ errors $ \problem ->
    if Diagnostic.diagnosticCode problem == "R0001" && sourceFile (Diagnostic.diagnosticSpan problem) == "<runtime>"
      then T.hPutStrLn stderr ("error[R0001]: " <> Diagnostic.diagnosticMessage problem)
      else printDiagnostic diagnosticStyle directory sources problem

selectedModule :: FilePath -> Compile.CompileResult -> IO (Either [Diagnostic.Diagnostic] ModuleId)
selectedModule file result = do
  absolute <- normalise <$> makeAbsolute file
  pure $ case [owner | (owner, tree) <- Map.toList (frontendModules (Compile.compileFrontend result)), normalise (sourceFile (A.abstractSpan tree)) == absolute] of
    [owner] -> Right owner
    _ -> Left [Diagnostic.Diagnostic "R0101" Diagnostic.Error (Span absolute (Position 1 1 0) (Position 1 1 0)) "cannot select a unique entry module" Nothing []]

replLoop :: DiagnosticStyle -> Repl.Session -> InputT IO ()
replLoop diagnosticStyle session = handleInterrupt (outputStrLn "Interrupted." >> replLoop diagnosticStyle session) $ withInterrupt $ do
  input <- Repl.readCommand (\prompt -> fmap T.pack <$> getInputLine (T.unpack prompt))
  case input of
    Nothing -> pure ()
    Just commandToRun -> case commandToRun of
      Repl.Quit -> pure ()
      Repl.Help -> outputStrLn (T.unpack Repl.helpText) >> replLoop diagnosticStyle session
      Repl.InvalidCommand message -> outputStrLn (T.unpack message) >> replLoop diagnosticStyle session
      Repl.Load file -> do
        result <- liftIO (Repl.loadSession session file)
        case result of
          Left errors -> liftIO (report diagnosticStyle Map.empty errors) >> replLoop diagnosticStyle session
          Right next -> do
            liftIO (report diagnosticStyle (Repl.sessionDiagnosticSources next) (Repl.sessionDiagnostics next))
            outputStrLn ("Loaded " ++ file)
            replLoop diagnosticStyle next
      Repl.TypeOf name -> do
        result <- liftIO (Repl.inspectType session name)
        either (liftIO . report diagnosticStyle Map.empty) (outputStrLn . T.unpack) result
        replLoop diagnosticStyle session
      Repl.KindOf name -> do
        result <- liftIO (Repl.inspectKind session name)
        either (liftIO . report diagnosticStyle Map.empty) (outputStrLn . T.unpack) result
        replLoop diagnosticStyle session
      Repl.Submit source -> do
        result <- liftIO (Repl.submit Runtime.ioEffects session source)
        case result of
          Left errors -> liftIO (report diagnosticStyle Map.empty errors) >> replLoop diagnosticStyle session
          Right (next, output) -> do
            liftIO (report diagnosticStyle (Repl.sessionDiagnosticSources next) (Repl.sessionDiagnostics next))
            maybe (pure ()) (outputStrLn . T.unpack) output
            replLoop diagnosticStyle next
