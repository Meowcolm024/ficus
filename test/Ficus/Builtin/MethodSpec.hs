module Ficus.Builtin.MethodSpec (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Compile
import Ficus.Elaborate (checkedCore)
import Ficus.Error.Diagnostic qualified as D
import Ficus.Library.Contracts
import Ficus.ModuleOptions (ModuleOptions (..))
import Ficus.Parser.PrettySpec (assertRoundTrip)
import Ficus.Resolve (FrontendResult (..))
import Ficus.Syntax.Abstract.Validate (validateAbstract)
import Ficus.Syntax.Concrete (validateConcrete)
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Core.Validate (validateCore, validatedModule)
import Ficus.Syntax.Name
import Ficus.Syntax.Parser (parseModule)
import Ficus.Util.Source
import FicusBackend.Driver.Repl qualified as Repl
import FicusBackend.Error qualified as Backend
import FicusBackend.Lower.Runtime
import FicusBackend.Runtime qualified as Runtime
import FicusBackend.Runtime.AST qualified as Runtime
import FicusBackend.Runtime.Direct (runDirect)
import Test.Tasty
import Test.Tasty.HUnit

root :: FilePath
root = "test/fixtures/compile/builtin-methods/"

compileFixture :: String -> IO CompileResult
compileFixture name = compileFiles libraryResolveConfig librarySugarRegistry (ModuleOptions [root] ["library"] (Just (root ++ "Prelude.ficus"))) ((root ++ name ++ ".ficus") :| [])

requireRight :: (Show e) => Either e a -> IO a
requireRight = either (\problem -> assertFailure (show problem) >> fail "builtin member fixture failed") pure

execute :: String -> Text -> IO ()
execute name expected = do
  compiled <- compileFixture name
  assertBool (show (compileDiagnostics compiled)) (compileSucceeded compiled)
  lowered <- requireRight (lowerProgram [validatedModule (checkedCore checked) | owner <- compileOrder compiled, Just checked <- [Map.lookup owner (compileModules compiled)]])
  ident <- case Map.lookup (GlobalId (ModuleId (T.pack name :| [])) ValueNS "check") (loweredGlobals lowered) of
    Just value -> pure value
    Nothing -> assertFailure "missing test entry" >> fail "missing entry"
  entry <- requireRight (Runtime.selectEntry (loweredProgram lowered) ident)
  let effects = Runtime.Effects (\_ _ -> pure ()) (\_ _ -> pure "")
      arguments = [Runtime.LiteralValue Runtime.Unit]
  compiledValue <- Runtime.runProgram effects (Runtime.compileProgram (loweredProgram lowered)) entry arguments
  directValue <- runDirect effects (loweredProgram lowered) ident arguments
  fmap Runtime.observe compiledValue @?= Right (Runtime.LiteralObservation (Runtime.String expected))
  fmap Runtime.observe directValue @?= fmap Runtime.observe compiledValue

negative :: String -> Text -> (Int, Int, Int, Int) -> TestTree
negative name code expected = testCase name $ do
  result <- compileFixture name
  compileSucceeded result @?= False
  let problems = filter ((== code) . D.diagnosticCode) (compileDiagnostics result)
  assertBool (show (compileDiagnostics result)) (not (null problems))
  mapM_ (\problem -> let location = D.diagnosticSpan problem in (line (start location), column (start location), line (end location), column (end location)) @?= expected) problems

tests :: TestTree
tests =
  testGroup
    "builtin trait members"
    [ testCase "renamed trait members register and validate" $ do
        result <- compileFixture "Render"
        assertBool (show (compileDiagnostics result)) (compileSucceeded result)
        mapM_
          ( \(path, source) -> do
              concrete <- requireRight (parseModule path source)
              validateConcrete concrete @?= Right ()
              assertRoundTrip concrete
          )
          (Map.toList (compileSources result))
        mapM_ (\tree -> validateAbstract tree @?= Right ()) (Map.elems (frontendModules (compileFrontend result)))
        mapM_ (\checked -> validateCore (validatedModule (checkedCore checked)) @?= []) (Map.elems (compileModules result)),
      negative "Duplicate" "N0112" (5, 13, 5, 16),
      negative "Repeated" "N0112" (4, 13, 4, 17),
      negative "WrongTarget" "N0105" (3, 18, 3, 23),
      negative "WrongResult" "T0501" (2, 21, 2, 27),
      negative "WrongArgument" "T0501" (2, 21, 2, 27),
      negative "Lazy" "T0501" (2, 21, 2, 27),
      negative "Quantified" "T0501" (2, 21, 2, 27),
      negative "Constrained" "T0501" (3, 21, 3, 27),
      negative "ImportClash" "N0112" (3, 13, 3, 16),
      negative "ImportDebugClash" "N0112" (3, 13, 3, 17),
      negative "LocalClash" "N0112" (4, 13, 4, 16),
      testCase "diamond imports share one canonical registration" (execute "Diamond" "shown"),
      testCase "interpolation uses the registered SHOW member" (execute "Interpolation" "value=shown"),
      testCase "REPL output uses the registered DEBUG member" $ do
        session <- Repl.newSession (ModuleOptions [root] ["library"] (Just (root ++ "Prelude.ficus"))) >>= requireRight
        let effects = Runtime.Effects (\_ _ -> pure ()) (\_ _ -> pure "")
        (_, output) <- Repl.submit effects session "1" >>= requireRight
        output @?= Just "debugged",
      testCase "symbolic DEBUG members use ordinary qualified calls" $ do
        session <- Repl.newSession (ModuleOptions [root] ["library"] (Just (root ++ "Symbolic.ficus"))) >>= requireRight
        let effects = Runtime.Effects (\_ _ -> pure ()) (\_ _ -> pure "")
        (_, output) <- Repl.submit effects session "1" >>= requireRight
        output @?= Just "debugged",
      testCase "independent entry modules cannot register different SHOW methods" $ do
        compiled <- compileFiles libraryResolveConfig librarySugarRegistry (ModuleOptions [root] [] Nothing) ((root ++ "Render.ficus") :| [root ++ "OtherShow.ficus"])
        compileSucceeded compiled @?= False
        let problems = filter ((== "N0112") . D.diagnosticCode) (compileDiagnostics compiled)
        assertBool (show (compileDiagnostics compiled)) (not (null problems))
        mapM_ (\problem -> let location = D.diagnosticSpan problem in (line (start location), column (start location), line (end location), column (end location)) @?= (3, 13, 3, 16)) problems,
      testCase "linking independently compiled registrations rejects conflicts" $ do
        results <- mapM compileFixture ["Render", "OtherShow"]
        mapM_ (\compiled -> assertBool (show (compileDiagnostics compiled)) (compileSucceeded compiled)) results
        let modules = [validatedModule (checkedCore checked) | compiled <- results, checked <- Map.elems (compileModules compiled)]
        case (modules, lowerProgram modules) of
          (first : _, Left problems) -> do
            map Backend.errorKind problems @?= [Backend.InvalidCore]
            map Backend.errorSpan problems @?= [C.coreSpan first]
          _ -> assertFailure "linking accepted conflicting SHOW registrations",
      testCase "interpolation requires SHOW registration" $ do
        compiled <- compileFiles libraryResolveConfig librarySugarRegistry (ModuleOptions [root] [] (Just (root ++ "EmptyPrelude.ficus"))) ((root ++ "Missing.ficus") :| [])
        let problems = filter ((== "N0121") . D.diagnosticCode) (compileDiagnostics compiled)
        map (\problem -> let location = D.diagnosticSpan problem in (line (start location), column (start location), line (end location), column (end location))) problems @?= [(2, 12, 2, 20)],
      testCase "interactive output requires DEBUG registration" $ do
        session <- Repl.newSession (ModuleOptions [root] [] (Just (root ++ "EmptyPrelude.ficus"))) >>= requireRight
        let effects = Runtime.Effects (\_ _ -> pure ()) (\_ _ -> pure "")
        Repl.submit effects session "1" >>= \case
          Left problems -> do
            map D.diagnosticCode problems @?= ["R0104"]
            map (\problem -> let location = D.diagnosticSpan problem in (sourceFile location, line (start location), column (start location), line (end location), column (end location))) problems @?= [("<repl>", 1, 1, 1, 1)]
          Right _ -> assertFailure "REPL accepted a missing DEBUG registration",
      testCase "Core independently rejects an incorrect registered method" $ do
        compiled <- compileFixture "Render"
        assertBool (show (compileDiagnostics compiled)) (compileSucceeded compiled)
        core <- case Map.lookup (ModuleId ("Render" :| [])) (compileModules compiled) of
          Just checked -> pure (validatedModule (checkedCore checked))
          Nothing -> assertFailure "missing Core" >> fail "missing Core"
        let malformed = core {C.coreBuiltins = Map.insert "SHOW" (GlobalId (ModuleId ("Render" :| [])) ValueNS "check") (C.coreBuiltins core)}
        let problems = map D.toDiagnostic (validateCore malformed)
        map D.diagnosticCode problems @?= ["T0099"]
        map D.diagnosticSpan problems @?= [C.coreSpan core]
    ]
