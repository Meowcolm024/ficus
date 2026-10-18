module FicusBackend.DriverSpec (tests) where

import Control.Exception (bracket)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Ficus.Compile
import Ficus.Error.Diagnostic qualified as D
import Ficus.Library.Contracts
import Ficus.Syntax.Name
import Ficus.Util.Source
import FicusBackend.Driver.Repl qualified as Repl
import FicusBackend.Driver.Run
import FicusBackend.Runtime qualified as R
import FicusBackend.Runtime.Value (StandardHandle (..))
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.FilePath (takeFileName, (</>))
import System.IO (hClose, openTempFile)
import Test.Tasty
import Test.Tasty.HUnit

root :: FilePath
root = "test/fixtures/backend/driver"

quiet :: R.Effects
quiet = R.Effects (\_ _ -> pure ()) (\_ _ -> pure "")

options :: Repl.ReplOptions
options = Repl.ReplOptions [] ["library"] Nothing

requireRight :: (Show e) => Either e a -> IO a
requireRight = either (\problem -> assertFailure (show problem) >> fail "fixture failed") pure

session :: IO Repl.Session
session = Repl.newSession options >>= requireRight

result :: Repl.Session -> Text -> Text -> Assertion
result current source expected = do
  (_, output) <- Repl.submit quiet current source >>= requireRight
  output @?= Just expected

fixture :: Text -> IO CompileResult
fixture name = compileFiles libraryResolveConfig librarySugarRegistry (CompileOptions ((root </> T.unpack name ++ ".ficus") :| []) [] ["library"] Nothing)

plan :: Text -> IO RunPlan
plan name = do
  compiled <- fixture name
  requireRight (prepareRun (ModuleId (name :| [])) compiled)

tests :: TestTree
tests =
  testGroup
    "backend drivers"
    [ testGroup
        "run"
        [ testCase "Unit entry succeeds" $ do
            prepared <- plan "UnitMain"
            executeRun quiet prepared [] >>= (@?= Right Nothing),
          testCase "Result Ok succeeds" $ do
            prepared <- plan "OkMain"
            executeRun quiet prepared [] >>= (@?= Right Nothing),
          testCase "Result Err returns the application error" $ do
            prepared <- plan "ErrMain"
            executeRun quiet prepared [] >>= (@?= Right (Just "entry failed")),
          testCase "command line arguments exclude the executable and source file" $ do
            output <- newIORef []
            prepared <- plan "ArgsMain"
            executeRun (R.Effects (\handle text -> modifyIORef' output (<> [(handle, text)])) (\_ _ -> pure "")) prepared ["hello", "world"] >>= (@?= Right Nothing)
            readIORef output >>= (@?= [(StandardOutput, "hello\n")]),
          testCase "an imported main is not automatically invoked" $ do
            prepared <- plan "LocalMain"
            executeRun quiet prepared [] >>= (@?= Right Nothing),
          testCase "division by zero returns a structured error" $ do
            prepared <- plan "DivisionMain"
            executeRun quiet prepared [] >>= \case
              Left problem -> R.errorKind problem @?= R.PrimitiveFailure
              Right value -> assertFailure (show value),
          invalidEntry "BadMain" 3,
          invalidEntry "PolyMain" 3,
          testCase "missing and reexported main are rejected" $
            mapM_
              ( \name -> do
                  compiled <- fixture name
                  case prepareRun (ModuleId (name :| [])) compiled of
                    Right _ -> assertFailure "entry accepted"
                    Left errors -> do
                      map D.diagnosticCode errors @?= ["R0101"]
                      map (line . start . D.diagnosticSpan) errors @?= [1]
              )
              ["NoMain", "ReexportMain"]
        ],
      testGroup
        "repl"
        [ testCase "command aliases and arguments" $ do
            map Repl.parseCommand [":q", ":quit"] @?= replicate 2 Repl.Quit
            map Repl.parseCommand [":l Foo.ficus", ":load Foo.ficus"] @?= replicate 2 (Repl.Load "Foo.ficus")
            map Repl.parseCommand [":t id", ":type id"] @?= replicate 2 (Repl.TypeOf "id")
            Repl.parseCommand ":load \"some folder/Foo.ficus\"" @?= Repl.Load "some folder/Foo.ficus",
          testCase "expressions execute without a main" $ session >>= \current -> result current "1 + 2" "3",
          testCase "division by zero leaves the session usable" $ do
            current <- session
            Repl.submit quiet current "1 / 0" >>= \case
              Left errors -> do
                map D.diagnosticCode errors @?= ["R0002"]
                -- Runtime primitives retain their builtin definition's source site.
                map (takeFileName . sourceFile . D.diagnosticSpan) errors @?= ["Int.ficus"]
                map (\d -> let location = start (D.diagnosticSpan d) in (line location, column location)) errors @?= [(10, 1)]
              Right _ -> assertFailure "division succeeded"
            result current "6 * 7" "42",
          testCase "declarations retain inferred types and execute" $ do
            current <- session
            (next, _) <- Repl.submit quiet current "double x = x + x" >>= requireRight
            result next "double 21" "42"
            Repl.inspectType next "double" >>= (@?= Right "double : Add a => a -> a"),
          testCase "type inspection retains polymorphism and constraints" $ do
            current <- session
            Repl.inspectType current "id" >>= (@?= Right "id : {a} -> a -> a")
            Repl.inspectType current "show" >>= (@?= Right "show : Show a => a -> String"),
          testCase "loading brings file definitions into scope" $ do
            current <- session
            loaded <- Repl.loadSession current (root </> "Values.ficus") >>= requireRight
            result loaded "value + 1" "42"
            Repl.inspectType loaded "value" >>= (@?= Right "value : Int"),
          testCase "interactive imports work" $ do
            current <- session
            (next, _) <- Repl.submit quiet current "import Data.Vec" >>= requireRight
            result next "vecLength (listToVec [1, 2, 3])" "3",
          testCase "failed imports preserve the previous environment" $ do
            current <- session
            Repl.submit quiet current "import MissingModule" >>= \case
              Left _ -> pure ()
              Right _ -> assertFailure "missing import accepted"
            result current "1 + 1" "2",
          testCase "reload replaces values and failed reload retains the snapshot" $ withDirectory $ \directory -> do
            let file = directory </> "Reload.ficus"
            TIO.writeFile file "value = 1\n"
            current <- session
            first <- Repl.loadSession current file >>= requireRight
            TIO.writeFile file "value = 2\n"
            result first "value" "1"
            second <- Repl.loadSession first file >>= requireRight
            result second "value" "2"
            TIO.writeFile file "value = missing\n"
            Repl.loadSession second file >>= \case
              Left _ -> pure ()
              Right _ -> assertFailure "invalid reload accepted"
            result second "value" "2"
        ]
    ]
  where
    invalidEntry name expectedLine = testCase ("reject invalid main in " ++ T.unpack name) $ do
      compiled <- fixture name
      assertBool (show (compileDiagnostics compiled)) (compileSucceeded compiled)
      case prepareRun (ModuleId (name :| [])) compiled of
        Right _ -> assertFailure "invalid main accepted"
        Left errors -> do
          map D.diagnosticCode errors @?= ["R0101"]
          map (line . start . D.diagnosticSpan) errors @?= [expectedLine]

withDirectory :: (FilePath -> IO a) -> IO a
withDirectory = bracket allocate removeDirectoryRecursive
  where
    allocate = do
      temporary <- getTemporaryDirectory
      (path, handle) <- openTempFile temporary "ficus-repl"
      hClose handle
      removeFile path
      createDirectory path
      pure path
