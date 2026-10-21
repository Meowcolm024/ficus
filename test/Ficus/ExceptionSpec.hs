module Ficus.ExceptionSpec (tests) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Compile
import Ficus.Elaborate (checkedCore)
import Ficus.Error.Diagnostic qualified as D
import Ficus.Error.Type qualified as E
import Ficus.ModuleOptions (ModuleOptions (..))
import Ficus.Resolve.Support (fixtureConfig, fixtureSugar)
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Core.Validate (validateCore, validatedModule)
import Ficus.Syntax.Name
import Ficus.Type qualified as Ty
import Ficus.Util.Source
import FicusBackend.Driver.Repl qualified as Repl
import FicusBackend.Lower.Runtime
import FicusBackend.Runtime qualified as R
import FicusBackend.Runtime.AST qualified as A
import FicusBackend.Runtime.Direct (runDirect)
import Test.Tasty
import Test.Tasty.HUnit

compileFixture :: String -> IO CompileResult
compileFixture name = compileFiles fixtureConfig fixtureSugar (ModuleOptions [] ["test/fixtures/support", "library"] (Just "test/fixtures/support/Prelude.ficus")) (("test/fixtures/compile/exceptions/" ++ name ++ ".ficus") :| [])

requireRight :: (Show e) => Either e a -> IO a
requireRight = either (\problem -> assertFailure (show problem) >> fail "exception fixture failed") pure

runFixture :: String -> Text -> IO (Either R.RuntimeError R.Observation, [Text])
runFixture file member = do
  compiled <- compileFixture file
  assertBool (show (compileDiagnostics compiled)) (compileSucceeded compiled)
  mapM_ (\checked -> validateCore (validatedModule (checkedCore checked)) @?= []) (Map.elems (compileModules compiled))
  lowered <- requireRight (lowerProgram [validatedModule (checkedCore checked) | owner <- compileOrder compiled, Just checked <- [Map.lookup owner (compileModules compiled)]])
  ident <- maybe (assertFailure "missing exception entry" >> fail "missing entry") pure (Map.lookup (GlobalId (ModuleId (T.pack file :| [])) ValueNS member) (loweredGlobals lowered))
  entry <- requireRight (R.selectEntry (loweredProgram lowered) ident)
  let capture action = do
        output <- newIORef []
        let effects = R.Effects (\_ text -> modifyIORef' output (<> [text])) (\_ _ -> pure "")
        result <- action effects
        trace <- readIORef output
        pure (fmap R.observe result, trace)
      arguments = [R.LiteralValue A.Unit]
  actual <- capture (\effects -> R.runProgram effects (R.compileProgram (loweredProgram lowered)) entry arguments)
  direct <- capture (\effects -> runDirect effects (loweredProgram lowered) ident arguments)
  direct @?= actual
  pure actual

execution :: String -> Text -> Integer -> [Text] -> TestTree
execution file member expected trace =
  testCase (file ++ "." ++ T.unpack member) $
    runFixture file member >>= (@?= (Right (R.LiteralObservation (A.Integer (fromInteger expected))), trace))

failure :: Text -> Text -> TestTree
failure member message = testCase (T.unpack member) $ do
  (actual, trace) <- runFixture "Positive" member
  trace @?= []
  case actual of
    Left problem -> assertBool (show problem) (message `T.isInfixOf` R.errorMessage problem)
    Right value -> assertFailure (show value)

negative :: String -> Text -> (Int, Int, Int, Int) -> TestTree
negative name code expected = testCase name $ do
  compiled <- compileFixture name
  compileSucceeded compiled @?= False
  let matching = filter ((== code) . D.diagnosticCode) (compileDiagnostics compiled)
  assertBool (show (compileDiagnostics compiled)) (not (null matching))
  mapM_ (\problem -> let site = D.diagnosticSpan problem in (line (start site), column (start site), line (end site), column (end site)) @?= expected) matching

tests :: TestTree
tests =
  testGroup
    "exceptions"
    [ execution "Basic" "check" 7 [],
      execution "Library" "check" 21 [],
      testGroup
        "execution"
        [ execution "Positive" member expected []
        | (member, expected) <-
            [ ("normal", 4),
              ("caught", 7),
              ("nested", 4),
              ("handlerThrows", 4),
              ("mismatched", 8),
              ("alias", 9),
              ("parameterized", 6),
              ("phantom", 5),
              ("polymorphic", 10),
              ("superclass", 11),
              ("functionResult", 12),
              ("partial", 13),
              ("skipArgument", 15),
              ("outsideHandler", 16),
              ("outsideAction", 17),
              ("failedStore", 1),
              ("completedStore", 2),
              ("listPayload", 19),
              ("productPayload", 20),
              ("primitiveMismatch", 21)
            ]
        ],
      execution "Positive" "strictOrder" 14 ["action", "handler", "run", "caught"],
      execution "Positive" "noReplay" 18 ["before", "after"],
      failure "uncaught" "uncaught exception",
      failure "runtimeFailure" "integer division by zero",
      failure "handlerFailure" "integer division by zero",
      testCase "Core rejects forged or malformed exception evidence" $ do
        compiled <- compileFixture "Basic"
        checked <- maybe (assertFailure "missing Basic module" >> fail "missing module") pure (Map.lookup (ModuleId ("Basic" :| [])) (compileModules compiled))
        let tree = validatedModule (checkedCore checked)
            descendants expression = expression : concatMap descendants (C.children expression)
            tokens = [node | group <- C.coreBindings tree, binding <- C.groupBindings group, node <- descendants (C.bindingBody (C.nodeValue binding)), C.ExceptionDictionary {} <- [C.formOf node]]
        case tokens of
          [token] | C.ExceptionDictionary owner argument _ <- C.formOf token -> do
            let corrupt form =
                  let body = fmap (\value -> value {C.expressionForm = form}) token
                      binding = fmap (const (C.Binding (GlobalRef (GlobalId (C.coreId tree) ValueNS "forged")) (Ty.monomorphic (C.typeOf body)) body (C.BindingFacts 0 Nothing))) token
                   in tree {C.coreBindings = [C.NonRecursive binding]}
            mapM_
              ( \form -> do
                  let errors = validateCore (corrupt form)
                  assertBool "invalid evidence was accepted" (not (null errors))
                  mapM_ (\problem -> (E.diagnosticCode problem, E.diagnosticSpan problem) @?= (E.InvalidCoreTree, C.nodeSpan token)) errors
              )
              [C.Dictionary owner argument [] [], C.ExceptionDictionary owner argument [token]]
          _ -> assertFailure "expected one concrete exception token",
      testCase "REPL preserves exception identities across nominal rebinding" $ do
        current <- Repl.newSession (ModuleOptions [] ["library"] Nothing) >>= requireRight
        let quiet = R.Effects (\_ _ -> pure ()) (\_ _ -> pure "")
            submit current' text = fst <$> (Repl.submit quiet current' text >>= requireRight)
        imported <- submit current "use Control.Exception (..)"
        first <- submit imported "type Problem = Problem Int\nimpl Exception Problem = {}\nold () = throw (Problem 7)\nrescue action = catch action ((Problem n) -> n)"
        second <- submit first "type Problem = Problem Int\nimpl Exception Problem = {}"
        (_, value) <- Repl.submit quiet second "rescue (_ -> catch old ((Problem n) -> 0))" >>= requireRight
        value @?= Just "7",
      testCase "REPL reports an uncaught exception and remains usable" $ do
        current <- Repl.newSession (ModuleOptions [] ["library"] Nothing) >>= requireRight
        let quiet = R.Effects (\_ _ -> pure ()) (\_ _ -> pure "")
        (imported, _) <- Repl.submit quiet current "use Control.Exception (..)" >>= requireRight
        Repl.submit quiet imported "bad = throw 3 : Int" >>= \case
          Left errors -> assertBool (show errors) (any (\problem -> D.diagnosticCode problem == "R0001" && "uncaught exception" `T.isInfixOf` D.diagnosticMessage problem) errors)
          Right _ -> assertFailure "uncaught exception succeeded"
        (_, value) <- Repl.submit quiet imported "1 + 2" >>= requireRight
        value @?= Just "3",
      testGroup
        "contracts"
        [ negative "WrongTarget" "T0501" (3, 6, 3, 12),
          negative "Methods" "T0501" (3, 1, 3, 43),
          negative "Superclass" "T0501" (4, 1, 4, 30),
          negative "HigherKind" "T0501" (3, 1, 3, 37),
          negative "Conflicting" "N0112" (4, 13, 4, 21),
          negative "WrongThrow" "T0501" (5, 1, 5, 3),
          negative "WrongResult" "T0501" (5, 1, 5, 3),
          negative "WrongCatch" "T0501" (5, 1, 5, 3),
          negative "MissingAssociation" "T0501" (4, 1, 4, 3),
          negative "MissingEvidence" "T0403" (2, 6, 2, 22),
          negative "HigherKindHead" "T0403" (2, 6, 2, 26),
          negative "ConflictingImports" "T0501" (1, 1, 5, 1),
          negative "NoInstance" "T0401" (2, 12, 2, 24)
        ]
    ]
