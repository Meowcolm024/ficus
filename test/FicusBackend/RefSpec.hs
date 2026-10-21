module FicusBackend.RefSpec (tests) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Compile
import Ficus.Elaborate (checkedCore)
import Ficus.Error.Type qualified as E
import Ficus.ModuleOptions (ModuleOptions (..))
import Ficus.Resolve.Support (fixtureConfig, fixtureSugar)
import Ficus.Syntax.Core.Validate (validateCore, validatedModule)
import Ficus.Syntax.Name
import Ficus.Util.Source
import FicusBackend.Lower.Runtime
import FicusBackend.Runtime qualified as R
import FicusBackend.Runtime.AST qualified as A
import FicusBackend.Runtime.Direct (runDirect)
import Test.Tasty
import Test.Tasty.HUnit

root :: FilePath
root = "test/fixtures/compile/ref/"

compileFixture :: String -> IO CompileResult
compileFixture name = compileFiles fixtureConfig fixtureSugar (ModuleOptions [] ["test/fixtures/support"] Nothing) ((root ++ name ++ ".ficus") :| [])

requireRight :: (Show e) => Either e a -> IO a
requireRight = either (\problem -> assertFailure (show problem) >> fail "reference fixture failed") pure

loadFixture :: String -> IO LoweredProgram
loadFixture name = do
  compiled <- compileFixture name
  assertBool (show (compileDiagnostics compiled)) (compileSucceeded compiled)
  mapM_ (\checked -> validateCore (validatedModule (checkedCore checked)) @?= []) (Map.elems (compileModules compiled))
  requireRight (lowerProgram [validatedModule (checkedCore checked) | owner <- compileOrder compiled, Just checked <- [Map.lookup owner (compileModules compiled)]])

entryGlobal :: String -> Text -> LoweredProgram -> IO A.GlobalIndex
entryGlobal owner name lowered = case Map.lookup (GlobalId (ModuleId (T.pack owner :| [])) ValueNS name) (loweredGlobals lowered) of
  Just ident -> pure ident
  Nothing -> assertFailure "missing reference fixture entry" >> fail "missing entry"

capture :: (R.Effects -> IO (Either R.RuntimeError R.Value)) -> IO (Either R.RuntimeError R.Observation, [Text])
capture action = do
  output <- newIORef []
  let effects = R.Effects (\_ text -> modifyIORef' output (<> [text])) (\_ _ -> pure "")
  result <- action effects
  trace <- readIORef output
  pure (fmap R.observe result, trace)

execution :: String -> Text -> R.Observation -> [Text] -> TestTree
execution file member expected trace = testCase (T.unpack member) $ do
  lowered <- loadFixture file
  ident <- entryGlobal file member lowered
  entry <- requireRight (R.selectEntry (loweredProgram lowered) ident)
  let arguments = [R.LiteralValue A.Unit]
  compiled <- capture (\effects -> R.runProgram effects (R.compileProgram (loweredProgram lowered)) entry arguments)
  direct <- capture (\effects -> runDirect effects (loweredProgram lowered) ident arguments)
  compiled @?= (Right expected, trace)
  direct @?= compiled

negative :: String -> E.TypeCode -> (Int, Int, Int, Int) -> TestTree
negative name kind expectedSpan = testCase name $ do
  result <- compileFixture name
  compileSucceeded result @?= False
  let matching = filter ((== kind) . E.diagnosticCode) (compileTypeDiagnostics result)
  assertBool (show (compileDiagnostics result)) (not (null matching))
  map (\diagnostic -> let origin = E.diagnosticSpan diagnostic in (line (start origin), column (start origin), line (end origin), column (end origin))) matching @?= replicate (length matching) expectedSpan

tests :: TestTree
tests =
  testGroup
    "mutable references"
    [ testGroup
        "execution"
        [ execution "Positive" "roundTrip" (integer 15) [],
          execution "Positive" "aliasing" (integer 2) [],
          execution "Positive" "independent" (integer 1) [],
          execution "Positive" "functionValue" (integer 8) [],
          execution "Positive" "freshPolymorphic" (R.LiteralObservation (A.Boolean True)) [],
          execution "Positive" "effectOrder" (integer 1) ["ref", "updater", "apply"],
          execution "Positive" "readTiming" (R.AggregateObservation A.pairConstructor [integer 1, integer 2]) [],
          execution "Positive" "referenceDebug" (R.LiteralObservation (A.String "Ref (1);Ref (2)")) [],
          execution "Positive" "aliasAllocation" (integer 6) [],
          execution "Positive" "cyclicValue" R.RefObservation [],
          execution "Renamed" "check" (R.LiteralObservation (A.Boolean True)) [],
          testCase "a failed updater does not write its result" $ do
            lowered <- loadFixture "Failure"
            failed <- entryGlobal "Failure" "failUpdate" lowered >>= requireRight . R.selectEntry (loweredProgram lowered)
            current <- entryGlobal "Failure" "current" lowered >>= requireRight . R.selectEntry (loweredProgram lowered)
            let effects = R.Effects (\_ _ -> pure ()) (\_ _ -> pure "")
            instance' <- R.initialize effects (R.compileProgram (loweredProgram lowered)) >>= requireRight
            R.evaluateEntry instance' failed [R.LiteralValue A.Unit] >>= \case
              Left problem -> assertBool (T.unpack (R.errorMessage problem)) ("Prelude.ficus" `T.isInfixOf` R.errorMessage problem)
              Right _ -> assertFailure "updater should fail"
            observed <- R.evaluateEntry instance' current [R.LiteralValue A.Unit]
            fmap R.observe observed @?= Right (integer 1)
        ],
      testGroup
        "builtin contracts"
        [ negative "WrongUpdater" E.BuiltinContractMismatch (5, 1, 5, 3),
          negative "SpecializedAllocation" E.BuiltinContractMismatch (5, 1, 5, 3),
          negative "MissingAssociation" E.BuiltinContractMismatch (5, 1, 5, 3)
        ],
      testGroup
        "generalization"
        [ negative "MixedCell" E.TypeMismatch (5, 26, 5, 31),
          negative "CapturedGetter" E.TypeMismatch (7, 14, 7, 19),
          negative "SharedFactory" E.TypeMismatch (8, 27, 8, 32),
          negative "PolymorphicSignature" E.InvalidAnnotation (3, 12, 3, 16),
          negative "Unresolved" E.UnresolvedWeakType (2, 14, 2, 17),
          negative "GlobalCell" E.ExpansiveInitializer (2, 8, 2, 17),
          negative "FunctionCell" E.TypeMismatch (6, 14, 6, 17)
        ]
    ]
  where
    integer = R.LiteralObservation . A.Integer
