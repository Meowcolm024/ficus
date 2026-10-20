module Ficus.V1Spec (tests) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Ficus.Compile
import Ficus.Elaborate (checkedCore)
import Ficus.Error.Diagnostic qualified as D
import Ficus.Library.Contracts
import Ficus.Syntax.Core qualified as Core
import Ficus.Syntax.Core.Validate
import Ficus.Syntax.Name (ModuleId (..))
import Ficus.Util.Source
import FicusBackend.Driver.Run
import FicusBackend.Runtime qualified as Runtime
import System.FilePath ((</>))
import Test.Tasty
import Test.Tasty.HUnit

compileFixture :: FilePath -> IO CompileResult
compileFixture file = compileFiles libraryResolveConfig librarySugarRegistry (CompileOptions ((root </> file) :| []) [] ["library"] Nothing)
  where
    root = "test/fixtures/compile/v1"

tests :: TestTree
tests =
  testGroup "v1 features" $
    [ testCase file $ do
        result <- compileFixture file
        assertBool (show (compileDiagnostics result)) (compileSucceeded result)
        compileDiagnostics result @?= []
        mapM_ (\checked -> validateCore (validatedModule (checkedCore checked)) @?= []) (Map.elems (compileModules result))
    | file <- ["Empty.ficus", "EmptyClient.ficus", "Standalone.ficus", "StandaloneDependency.ficus", "VoidPrelude.ficus"]
    ]
      ++ [ failure "RemovedVoidKey.ficus" "N0111" [2, 13, 2, 16],
           failure "RemovedAbsurdKey.ficus" "N0111" [2, 13, 2, 18],
           failure "ConstructEmpty.ficus" "P0005" [3, 23, 3, 23],
           failure "ConstructEmptyValue.ficus" "N0001" [3, 11, 3, 15],
           failure "StandaloneArgument.ficus" "N0103" [1, 5, 1, 14],
           failure "StandalonePlacement.ficus" "N0104" [3, 5, 3, 14],
           failure "StandaloneCycle.ficus" "T0201" [3, 5, 3, 14],
           failure "StandaloneMember.ficus" "T0201" [4, 34, 4, 47],
           failure "StandaloneRestriction.ficus" "T0001" [5, 28, 5, 31]
         ]
      ++ [failure file "N0207" [2, 5, 2, 14] | file <- ["ImportBare.ficus", "ImportAlias.ficus", "ImportSelective.ficus", "ImportReexport.ficus"]]
      ++ [ testCase "empty type declarations introduce no Core constructors" $ do
             result <- compileFixture "Empty.ficus"
             case Map.lookup (ModuleId ("Empty" :| [])) (compileModules result) of
               Nothing -> assertFailure (show (compileDiagnostics result))
               Just checked -> Core.coreConstructors (validatedModule (checkedCore checked)) @?= Map.empty,
           testCase "standalone compilation does not require or select main" $ do
             result <- compileFixture "Standalone.ficus"
             compileSucceeded result @?= True
             case prepareRun (ModuleId ("Standalone" :| [])) result of
               Left problems -> map D.diagnosticCode problems @?= ["R0101"]
               Right _ -> assertFailure "missing main was accepted for execution",
           testCase "standalone initialization precedes its selected main" $ do
             result <- compileFixture "StandaloneMain.ficus"
             case prepareRun (ModuleId ("StandaloneMain" :| [])) result of
               Left problems -> assertFailure (show problems)
               Right prepared -> do
                 output <- newIORef []
                 let effects = Runtime.Effects (\_ text -> modifyIORef' output (<> [text])) (\_ _ -> pure "")
                 executeRun effects prepared [] >>= (@?= Right Nothing)
                 readIORef output >>= (@?= ["initialize\n", "42\n"]),
           testCase "implicit imports reject standalone Prelude" $ do
             result <- compileFiles libraryResolveConfig librarySugarRegistry (CompileOptions ("test/fixtures/compile/v1/implicit/Implicit.ficus" :| []) [] [] Nothing)
             assertDiagnostic result "N0207" [1, 1, 1, 1]
             Map.member (ModuleId ("Implicit" :| [])) (compileModules result) @?= False,
           testCase "inhabited empty match warns" $ do
             result <- compileFixture "Inhabited.ficus"
             assertBool (show (compileDiagnostics result)) (compileSucceeded result)
             assertDiagnostic result "T0901" [2, 19, 2, 27]
         ]

failure :: FilePath -> Text -> [Int] -> TestTree
failure file code coordinates = testCase file $ do
  result <- compileFixture file
  compileSucceeded result @?= False
  assertDiagnostic result code coordinates

assertDiagnostic :: CompileResult -> Text -> [Int] -> Assertion
assertDiagnostic result code coordinates = do
  let matches = [d | d <- compileDiagnostics result, D.diagnosticCode d == code]
      position d = let s = D.diagnosticSpan d in [line (start s), column (start s), line (end s), column (end s)]
  assertBool (show (compileDiagnostics result)) (any ((== coordinates) . position) matches)
