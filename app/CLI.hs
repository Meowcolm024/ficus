module CLI (main) where

import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Version (showVersion)
import Ficus.Compile qualified as Compile
import Ficus.Error.Diagnostic qualified as Diagnostic
import Ficus.Error.Pretty (prettyDiagnosticRelativeTo)
import Ficus.Library.Contracts
import Ficus.Resolve (frontendDiagnostics)
import Ficus.Syntax.Concrete.Pretty (prettyModule)
import Ficus.Syntax.Parser (parseModule)
import Ficus.Util.Source (sourceFile)
import Options.Applicative
import Paths_ficus qualified as Paths
import System.Directory (getCurrentDirectory)
import System.Exit (exitFailure)
import System.IO (stderr)
import System.IO.Error (tryIOError)

data Command = Version | Format (Maybe FilePath) | Compile Compile.CompileOptions

main :: IO ()
main = do
  commandToRun <- execParser commandInfo
  case commandToRun of
    Version -> putStrLn versionText
    Compile options -> do
      libraries <- if null (Compile.libraryRoots options) then pure <$> Paths.getDataFileName "library" else pure (Compile.libraryRoots options)
      result <- Compile.compileFiles libraryResolveConfig librarySugarRegistry (options {Compile.libraryRoots = libraries})
      directory <- getCurrentDirectory
      mapM_ (printDiagnostic directory (Compile.compileSources result)) (frontendDiagnostics (Compile.compileFrontend result))
      if Compile.compileSucceeded result then pure () else exitFailure
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
  T.hPutStrLn stderr (prettyDiagnosticRelativeTo directory (Map.findWithDefault "" file sources) diagnostic)

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
        ( command "version" (info (pure Version <**> helper) (progDesc "Print the Ficus version"))
            <> command "format" (info formatCommand (progDesc "Pretty-print a source file or stdin to stdout"))
            <> command "compile" (info compileCommand (progDesc "Check parsing and name resolution; emit no artifacts" <> footer "Library discovery options are for early development and are subject to change."))
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
