module CLI (main) where

import Control.Monad.IO.Class (liftIO)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Version (showVersion)
import Ficus.Compile qualified as Compile
import Ficus.Error.Diagnostic qualified as Diagnostic
import Ficus.Error.Pretty (prettyDiagnosticRelativeTo, prettyDiagnosticWithOptionalSourceRelativeTo)
import Ficus.Library.Contracts
import Ficus.Resolve (frontendModules)
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Concrete.Pretty (prettyModule)
import Ficus.Syntax.Name (ModuleId)
import Ficus.Syntax.Parser (parseModule)
import Ficus.Util.Source (Position (..), Span (..))
import FicusBackend.Driver.Repl qualified as Repl
import FicusBackend.Driver.Run qualified as Run
import FicusBackend.Runtime qualified as Runtime
import Options.Applicative
import Paths_ficus qualified as Paths
import System.Console.Haskeline
import System.Directory (getCurrentDirectory, makeAbsolute)
import System.Exit (exitFailure)
import System.FilePath (normalise)
import System.IO (stderr)
import System.IO.Error (tryIOError)

data Command = Format (Maybe FilePath) | Compile Compile.CompileOptions | Run FilePath [String] Repl.ReplOptions | Repl (Maybe FilePath) Repl.ReplOptions

main :: IO ()
main = do
  commandToRun <- execParser commandInfo
  case commandToRun of
    Compile options -> do
      libraries <- if null (Compile.libraryRoots options) then pure <$> Paths.getDataFileName "library" else pure (Compile.libraryRoots options)
      result <- Compile.compileFiles libraryResolveConfig librarySugarRegistry (options {Compile.libraryRoots = libraries})
      directory <- getCurrentDirectory
      mapM_ (printDiagnostic directory (Compile.compileSources result)) (Compile.compileDiagnostics result)
      if Compile.compileSucceeded result then pure () else exitFailure
    Run file arguments options -> do
      configured <- configure options
      result <- Compile.compileFiles libraryResolveConfig librarySugarRegistry (Compile.CompileOptions (file :| []) (Repl.replRoots configured) (Repl.replLibraries configured) (Repl.replPrelude configured))
      report (Compile.compileSources result) (Compile.compileDiagnostics result)
      if not (Compile.compileSucceeded result)
        then exitFailure
        else do
          owner <- selectedModule file result
          case owner >>= (\ident -> Run.prepareRun ident result) of
            Left errors -> report (Compile.compileSources result) errors >> exitFailure
            Right plan ->
              Run.executeRun Runtime.ioEffects plan (map T.pack arguments) >>= \case
                Left problem -> report (Compile.compileSources result) [Diagnostic.toDiagnostic problem] >> exitFailure
                Right (Just message) -> T.hPutStrLn stderr message >> exitFailure
                Right Nothing -> pure ()
    Repl file options -> do
      configured <- configure options
      initial <- Repl.newSession configured
      case initial of
        Left errors -> report Map.empty errors >> exitFailure
        Right session -> do
          loaded <- case file of
            Nothing -> pure session
            Just path -> Repl.loadSession session path >>= either (\errors -> report Map.empty errors >> pure session) pure
          runInputT defaultSettings (replLoop loaded)
    Format path -> do
      let sourceName = case path of Nothing -> "<stdin>"; Just "-" -> "<stdin>"; Just file -> file
      input <- tryIOError (case path of Nothing -> T.getContents; Just "-" -> T.getContents; Just file -> T.readFile file)
      case input of
        Left err -> T.hPutStrLn stderr (T.pack (show err)) >> exitFailure
        Right source -> case parseModule sourceName source of
          Left diagnostic -> do
            directory <- getCurrentDirectory
            T.hPutStrLn stderr (prettyDiagnosticRelativeTo directory source diagnostic)
            exitFailure
          Right concreteModule -> T.putStr (prettyModule concreteModule)

printDiagnostic :: (Diagnostic.ToDiagnostic d) => FilePath -> Map.Map FilePath T.Text -> d -> IO ()
printDiagnostic directory sources diagnostic = do
  let file = sourceFile (Diagnostic.diagnosticSpan (Diagnostic.toDiagnostic diagnostic))
  T.hPutStrLn stderr (prettyDiagnosticWithOptionalSourceRelativeTo directory (Map.lookup file sources) diagnostic)

versionText :: String
versionText = showVersion Paths.version

commandInfo :: ParserInfo Command
commandInfo =
  info
    (commands <**> simpleVersioner versionText <**> helper)
    (fullDesc <> progDesc "Ficus language tools")
  where
    commands =
      hsubparser
        ( command "format" (info formatCommand (progDesc "Pretty-print a source file or stdin to stdout"))
            <> command "run" (info runCommand (progDesc "Run a file with a valid main entry point"))
            <> command "repl" (info replCommand (progDesc "Start an interactive session, optionally loading a file"))
            <> command "compile" (info compileCommand (progDesc "Typecheck and elaborate source modules; emit no artifacts" <> footer "Library discovery options are for early development and are subject to change."))
        )
    formatCommand = Format <$> optional (strArgument (metavar "FILE" <> help "Source file; omit or use - for stdin")) <**> helper
    -- some rejects empty input and renders one repeated-argument help entry;
    -- its nonempty result makes the conversion to NonEmpty safe.
    compileCommand =
      Compile
        <$> ( Compile.CompileOptions
                <$> (NE.fromList <$> some inputFile)
                <*> many (strOption (long "source-root" <> metavar "DIR" <> help "Project source root (repeatable); defaults to input file directories"))
                <*> many (strOption (long "library" <> metavar "DIR" <> help "Standard library source root (repeatable); defaults to bundled library"))
                <*> optional (strOption (long "prelude" <> metavar "FILE" <> help "Source file for the canonical Prelude module"))
            )

    inputFile = strArgument (metavar "FILE..." <> help "Ficus source files to check")

    runCommand = Run <$> strArgument (metavar "FILE") <*> many (strArgument (metavar "ARGS...")) <*> searchOptions
    replCommand = Repl <$> optional (strArgument (metavar "FILE")) <*> searchOptions
    searchOptions =
      Repl.ReplOptions
        <$> many (strOption (long "source-root" <> metavar "DIR" <> help "Project source root (repeatable)"))
        <*> many (strOption (long "library" <> metavar "DIR" <> help "Library source root (repeatable)"))
        <*> optional (strOption (long "prelude" <> metavar "FILE" <> help "Override the Prelude file"))

configure :: Repl.ReplOptions -> IO Repl.ReplOptions
configure options = do
  libraries <- if null (Repl.replLibraries options) then pure <$> Paths.getDataFileName "library" else pure (Repl.replLibraries options)
  pure (options {Repl.replLibraries = libraries})

report :: Map.Map FilePath T.Text -> [Diagnostic.Diagnostic] -> IO ()
report sources errors = do
  directory <- getCurrentDirectory
  mapM_ (printDiagnostic directory sources) errors

selectedModule :: FilePath -> Compile.CompileResult -> IO (Either [Diagnostic.Diagnostic] ModuleId)
selectedModule file result = do
  absolute <- normalise <$> makeAbsolute file
  pure $ case [owner | (owner, tree) <- Map.toList (frontendModules (Compile.compileFrontend result)), normalise (sourceFile (A.abstractSpan tree)) == absolute] of
    [owner] -> Right owner
    _ -> Left [Diagnostic.Diagnostic "R0101" Diagnostic.Error (Span absolute (Position 1 1 0) (Position 1 1 0)) "cannot select a unique entry module" Nothing []]

replLoop :: Repl.Session -> InputT IO ()
replLoop session = handleInterrupt (outputStrLn "Interrupted." >> replLoop session) $ withInterrupt $ do
  input <- getInputLine "ficus> "
  case input of
    Nothing -> pure ()
    Just line -> case Repl.parseCommand (T.pack line) of
      Repl.Quit -> pure ()
      Repl.Help -> outputStrLn (T.unpack Repl.helpText) >> replLoop session
      Repl.InvalidCommand message -> outputStrLn (T.unpack message) >> replLoop session
      Repl.Load file -> do
        result <- liftIO (Repl.loadSession session file)
        case result of
          Left errors -> liftIO (report Map.empty errors) >> replLoop session
          Right next -> outputStrLn ("Loaded " ++ file) >> replLoop next
      Repl.TypeOf name -> do
        result <- liftIO (Repl.inspectType session name)
        either (liftIO . report Map.empty) (outputStrLn . T.unpack) result
        replLoop session
      Repl.Submit source -> do
        result <- liftIO (Repl.submit Runtime.ioEffects session source)
        case result of
          Left errors -> liftIO (report Map.empty errors) >> replLoop session
          Right (next, output) -> do
            maybe (pure ()) (outputStrLn . T.unpack) output
            replLoop next
