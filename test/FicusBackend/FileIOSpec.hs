module FicusBackend.FileIOSpec (tests) where

import Control.Exception (bracket)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Ficus.Compile
import Ficus.Elaborate (checkedCore)
import Ficus.Library.Contracts
import Ficus.ModuleOptions (ModuleOptions (..))
import Ficus.Syntax.Core.Validate (validateCore, validatedModule)
import Ficus.Syntax.Name
import FicusBackend.Lower.Runtime
import FicusBackend.Runtime qualified as R
import FicusBackend.Runtime.AST qualified as A
import FicusBackend.Runtime.Direct (runDirect)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import Test.Tasty
import Test.Tasty.HUnit

requireRight :: (Show e) => Either e a -> IO a
requireRight = either (\problem -> assertFailure (show problem) >> fail "file IO fixture failed") pure

loadFixture :: String -> IO LoweredProgram
loadFixture name = do
  result <- compileFiles libraryResolveConfig librarySugarRegistry (ModuleOptions [] ["library"] Nothing) (("test/fixtures/compile/file-io/" ++ name ++ ".ficus") :| [])
  assertBool (show (compileDiagnostics result)) (compileSucceeded result)
  mapM_ (\checked -> validateCore (validatedModule (checkedCore checked)) @?= []) (Map.elems (compileModules result))
  requireRight (lowerProgram [validatedModule (checkedCore checked) | owner <- compileOrder result, Just checked <- [Map.lookup owner (compileModules result)]])

withFile :: Text -> (FilePath -> IO a) -> IO a
withFile initial action = bracket create removeFile $ \path -> do
  TIO.writeFile path initial
  action path
  where
    create = do
      directory <- getTemporaryDirectory
      (path, handle) <- openTempFile directory "ficus-file-io"
      hClose handle
      pure path

execution :: IO LoweredProgram -> ModuleId -> Text -> Text -> Text -> Text -> TestTree
execution resource owner member initial expected expectedContents = testCase (show member) $ do
  lowered <- resource
  ident <- maybe (assertFailure "missing file IO entry" >> fail "missing entry") pure (Map.lookup (GlobalId owner ValueNS member) (loweredGlobals lowered))
  entry <- requireRight (R.selectEntry (loweredProgram lowered) ident)
  let execute action = withFile initial $ \path -> do
        result <- action [R.LiteralValue (A.String (T.pack path))]
        fmap R.observe result @?= Right (R.LiteralObservation (A.String expected))
        contents <- TIO.readFile path
        contents @?= expectedContents
        pure (fmap R.observe result, contents)
  compiled <- execute (R.runProgram R.ioEffects (R.compileProgram (loweredProgram lowered)) entry)
  direct <- execute (runDirect R.ioEffects (loweredProgram lowered) ident)
  direct @?= compiled

tests :: TestTree
tests =
  testGroup
    "file IO"
    [ withResource (loadFixture "FileIO") (\_ -> pure ()) $ \resource ->
        testGroup
          "standard library"
          [ execution resource (ModuleId ("FileIO" :| [])) member "hello" expected contents
          | (member, expected, contents) <- [("roundTrip", "a😀\r\nb", "a😀\r\nb"), ("append", "first|last", "first|last"), ("truncate", "", ""), ("readWrite", "Hello", "Hello"), ("missing", "openFile", "hello"), ("closedRead", "read", "hello"), ("closedWrite", "write", ""), ("readOnlyWrite", "write", "hello"), ("writeOnlyRead", "read", ""), ("closeStandard", "close", "hello"), ("zeroClosedRead", "", "hello"), ("doubleClose", "closed", "hello")]
          ],
      withResource (loadFixture "RenamedFileIO") (\_ -> pure ()) $ \resource -> execution resource (ModuleId ("RenamedFileIO" :| [])) "check" "" "renamed" "renamed"
    ]
