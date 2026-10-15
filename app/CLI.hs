module CLI (main) where

import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Version (showVersion)
import Ficus.Error.Pretty (prettyDiagnostic)
import Ficus.Syntax.Concrete.Pretty (prettyModule)
import Ficus.Syntax.Parser (parseModule)
import Options.Applicative
import Paths_ficus qualified as Paths
import System.Exit (exitFailure)
import System.IO (stderr)
import System.IO.Error (tryIOError)

data Command = Version | Format (Maybe FilePath)

main :: IO ()
main = do
  commandToRun <- execParser commandInfo
  case commandToRun of
    Version -> putStrLn versionText
    Format path -> do
      let sourceName = case path of Nothing -> "<stdin>"; Just "-" -> "<stdin>"; Just file -> file
      input <- tryIOError (case path of Nothing -> T.getContents; Just "-" -> T.getContents; Just file -> T.readFile file)
      case input of
        Left err -> T.hPutStrLn stderr (T.pack (show err)) >> exitFailure
        Right source -> case parseModule sourceName source of
          Left diagnostic -> T.hPutStrLn stderr (prettyDiagnostic source diagnostic) >> exitFailure
          Right concreteModule -> T.putStr (prettyModule concreteModule)

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
        )
    formatCommand = Format <$> optional (strArgument (metavar "FILE" <> help "Source file; omit or use - for stdin")) <**> helper
