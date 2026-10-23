module FicusBackend.LazyArrowSpec (tests) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Compile
import Ficus.Elaborate (checkedCore)
import Ficus.Error.Type qualified as E
import Ficus.ModuleOptions (ModuleOptions (..))
import Ficus.Resolve (FrontendResult (..))
import Ficus.Resolve.Support (fixtureConfig, fixtureSugar)
import Ficus.Syntax.Abstract.Validate (validateAbstract)
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Core.Validate (validateCore, validatedModule)
import Ficus.Syntax.Name
import Ficus.Util.Source
import FicusBackend.Lower.Runtime
import FicusBackend.Runtime qualified as R
import FicusBackend.Runtime.AST qualified as A
import FicusBackend.Runtime.Direct (runDirect)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck qualified as QC

root :: FilePath
root = "test/fixtures/lazy-arrows/"

compileFixture :: String -> IO CompileResult
compileFixture name = compileFiles fixtureConfig fixtureSugar (ModuleOptions [] ["test/fixtures/support"] Nothing) ((root ++ name ++ ".ficus") :| [])

requireRight :: (Show e) => Either e a -> IO a
requireRight = either (\problem -> assertFailure (show problem) >> fail "lazy arrow fixture failed") pure

loadFixture :: String -> IO LoweredProgram
loadFixture name = do
  compiled <- compileFixture name
  assertBool (show (compileDiagnostics compiled)) (compileSucceeded compiled)
  mapM_ (\tree -> validateAbstract tree @?= Right ()) (Map.elems (frontendModules (compileFrontend compiled)))
  mapM_ (\checked -> validateCore (validatedModule (checkedCore checked)) @?= []) (Map.elems (compileModules compiled))
  requireRight (lowerProgram [validatedModule (checkedCore checked) | owner <- compileOrder compiled, Just checked <- [Map.lookup owner (compileModules compiled)]])

entryGlobal :: String -> Text -> LoweredProgram -> IO A.GlobalIndex
entryGlobal owner name lowered = case Map.lookup (GlobalId (ModuleId (T.pack owner :| [])) ValueNS name) (loweredGlobals lowered) of
  Just ident -> pure ident
  Nothing -> assertFailure "missing lazy arrow fixture entry" >> fail "missing entry"

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
    "call-by-name arrows"
    [ testGroup
        "execution"
        [ execution "Execution" member (integer result) output
        | (member, result, output) <-
            [ ("repeated", 2, ["demand", "demand"]),
              ("skipped", 0, []),
              ("shared", 2, ["demand"]),
              ("patternOnce", 2, ["box"]),
              ("patternUnused", 0, ["box"]),
              ("wildcardConstructor", 0, ["box"]),
              ("unitDemand", 0, ["unit"]),
              ("operandOrder", 6, ["left", "right", "left", "right"]),
              ("forwarded", 2, ["demand", "demand"]),
              ("mixedOrder", 5, ["strict", "left", "right", "left", "right"]),
              ("partialCalls", 4, ["strict", "demand", "demand"]),
              ("captured", 10, []),
              ("changing", 3, []),
              ("closureDemand", 3, []),
              ("repeatedFailure", 3, ["throw", "throw"]),
              ("skipFailure", 0, []),
              ("skipDivergence", 0, []),
              ("clauseAttempts", 2, []),
              ("clauseOrder", 7, ["first", "first"]),
              ("lambda", 2, ["demand", "demand"]),
              ("annotatedLambda", 2, ["demand", "demand"]),
              ("annotatedVariable", 2, ["demand", "demand"]),
              ("annotatedWildcard", 0, []),
              ("lambdaPattern", 0, ["box"]),
              ("higherOrder", 2, ["demand", "demand"]),
              ("typeApplication", 0, []),
              ("polymorphic", 8, []),
              ("method", 2, ["demand", "demand"]),
              ("recordField", 0, []),
              ("strictMatch", 0, ["demand"]),
              ("shortCircuit", 0, []),
              ("calleeOrder", 2, ["callee", "demand", "demand"]),
              ("patternBeforeStrict", 1, ["box", "strict"])
            ]
        ],
      testGroup "contextual signatures" [execution "Contextual" member (integer 2) (setup ++ ["demand", "demand"]) | (member, setup) <- [("check", []), ("checkPositional", []), ("checkBox", []), ("checkList", []), ("checkProduct", []), ("checkConditional", []), ("checkSequence", ["setup"]), ("checkUpdate", []), ("checkAlias", [])]],
      testCase "argument thunks retain the argument span" $ do
        compiled <- compileFixture "Provenance"
        assertBool (show (compileDiagnostics compiled)) (compileSucceeded compiled)
        let expressions expression = expression : concatMap expressions (C.children expression)
            allNodes = [node | checked <- Map.elems (compileModules compiled), group <- C.coreBindings (validatedModule (checkedCore checked)), binding <- C.groupBindings group, node <- expressions (C.bindingBody (C.nodeValue binding))]
            thunks = [node | node <- allNodes, GeneratedOrigin "call-by-name argument" _ <- [C.nodeOrigin node]]
        map (\node -> let location = C.nodeSpan node in (line (start location), column (start location), line (end location), column (end location))) thunks @?= [(4, 17, 4, 24)]
        mapM_ (\node -> C.nodeOrigin node @?= GeneratedOrigin "call-by-name argument" (C.nodeSpan node)) thunks,
      withResource (loadFixture "Execution") (const (pure ())) $ \program ->
        QC.testProperty "compiled and direct demands agree with the mutable-state oracle" $ QC.forAll (QC.chooseInt (-100, 100)) $ \initial -> QC.ioProperty $ do
          lowered <- program
          ident <- entryGlobal "Execution" "property" lowered
          entry <- requireRight (R.selectEntry (loweredProgram lowered) ident)
          let arguments = [R.LiteralValue (A.Integer (fromIntegral initial))]
          compiled <- capture (\effects -> R.runProgram effects (R.compileProgram (loweredProgram lowered)) entry arguments)
          direct <- capture (\effects -> runDirect effects (loweredProgram lowered) ident arguments)
          pure (compiled QC.=== (Right (integer (fromIntegral (2 * initial + 3))), []) QC..&&. direct QC.=== compiled),
      negative "WrongStrict" E.TypeMismatch (6, 15, 6, 18),
      negative "WrongLazy" E.TypeMismatch (6, 13, 6, 18),
      negative "InferredStrict" E.TypeMismatch (4, 11, 4, 18)
    ]
  where
    integer = R.LiteralObservation . A.Integer
