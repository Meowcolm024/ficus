module FicusBackend.CompilerSpec (tests) where

import Control.Exception (bracket)
import Data.Aeson qualified as J
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import Ficus.Compile
import Ficus.Elaborate (checkedCore)
import Ficus.Library.Contracts
import Ficus.ModuleOptions (ModuleOptions (..))
import Ficus.Primitive.Registry qualified as P
import Ficus.Syntax.Core.Validate (validatedModule)
import Ficus.Syntax.Name
import FicusBackend.Driver.JavaScript
import FicusBackend.Error qualified as E
import FicusBackend.JavaScript.Emit
import FicusBackend.Lower.Runtime
import FicusBackend.Pass.Normalize
import FicusBackend.Pass.TailCalls
import FicusBackend.Pass.Traversal (children)
import FicusBackend.Pipeline
import FicusBackend.Runtime qualified as R
import FicusBackend.Runtime.AST qualified as A
import FicusBackend.Runtime.Direct
import System.Directory (getTemporaryDirectory, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath (takeBaseName)
import System.IO (hClose, openTempFile)
import System.Process (readProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck qualified as QC

requireRight :: (Show e) => Either e a -> IO a
requireRight = either (\problem -> assertFailure (show problem) >> fail "compiler fixture failed") pure

compileFixture :: FilePath -> IO (CompileResult, LoweredProgram)
compileFixture file = do
  let prelude = if "lazy-arrows" `T.isInfixOf` T.pack file || "compile/exceptions" `T.isInfixOf` T.pack file then Just "test/fixtures/support/Prelude.ficus" else Nothing
  compiled <- compileFiles libraryResolveConfig librarySugarRegistry (ModuleOptions [] ["library"] prelude) (file :| [])
  assertBool (show (compileDiagnostics compiled)) (compileSucceeded compiled)
  lowered <- requireRight (lowerProgram [validatedModule (checkedCore checked) | owner <- compileOrder compiled, Just checked <- [Map.lookup owner (compileModules compiled)]])
  pure (compiled, lowered)

capture :: (R.Effects -> IO (Either R.RuntimeError R.Value)) -> IO (Either R.RuntimeError R.Observation, Text)
capture action = do
  output <- newIORef ""
  result <- action (R.Effects (\_ text -> modifyIORef' output (<> text)) (\_ _ -> pure ""))
  trace <- readIORef output
  pure (fmap R.observe result, trace)

execute :: R.ValidatedProgram -> A.GlobalIndex -> [R.Value] -> R.Effects -> IO (Either R.RuntimeError R.Value)
execute checked ident arguments effects = do
  entry <- requireRight (R.selectEntry checked ident)
  R.runProgram effects (R.compileProgram checked) entry arguments

withScript :: Text -> (FilePath -> IO a) -> IO a
withScript source action = bracket create removeFile action
  where
    create = do
      directory <- getTemporaryDirectory
      (file, handle) <- openTempFile directory "ficus-compiler.mjs"
      TIO.hPutStr handle source
      hClose handle
      pure file

observeJS :: Text
observeJS =
  T.unlines
    [ "function observe(value){",
      "if(typeof value==='bigint')return String(value);",
      "if(value===null||typeof value!=='object')return value;",
      "if(Array.isArray(value))return value.map(observe);",
      "if('tag' in value)return [value.tag,...value.fields.map(observe)];",
      "if('ref' in value)return 'ref';",
      "if('code' in value)return 'function';",
      "throw new Error('unhandled test observation');}"
    ]

observation :: R.Observation -> J.Value
observation value = case value of
  R.LiteralObservation literal -> case literal of
    A.Integer valueInt -> J.toJSON (show valueInt)
    A.Floating float -> J.toJSON float
    A.String text -> J.toJSON text
    A.Character character -> J.toJSON (T.singleton character)
    A.Boolean boolean -> J.toJSON boolean
    A.Unit -> J.Null
  R.AggregateObservation (A.ConstructorIndex tag) fields -> J.toJSON (J.toJSON tag : map observation fields)
  R.VectorObservation fields -> J.toJSON (map observation fields)
  R.ByteObservation byte -> J.toJSON byte
  R.RefObservation -> J.String "ref"
  R.FunctionObservation _ _ -> J.String "function"
  _ -> J.String "unsupported observation"

resultJSON :: Either R.RuntimeError R.Observation -> J.Value
resultJSON = either (\failure -> J.object ["error" J..= R.errorMessage failure]) (\value -> J.object ["ok" J..= observation value])

javascript :: R.ValidatedProgram -> A.GlobalIndex -> [Text] -> IO (ExitCode, Text, Text)
javascript checked (A.GlobalIndex ident) arguments = do
  support <- TIO.readFile "runtime/javascript.mjs"
  normalized <- requireRight (validateNormalized (R.validatedProgram checked))
  let code =
        support
          <> emitProgram normalized
          <> observeJS
          <> T.unlines
            [ "try {const run=createProgram();const value=run(" <> T.pack (show ident) <> ",[" <> T.intercalate "," arguments <> "]);",
              "console.log('\\n@RESULT '+JSON.stringify({ok:observe(value)}));}",
              "catch(error){console.log('\\n@RESULT '+JSON.stringify({error:error.message}));}"
            ]
  withScript code $ \file -> do
    (status, out, err) <- readProcessWithExitCode "node" ["--stack_size=256", file] ""
    pure (status, T.pack out, T.pack err)

compareJS :: R.ValidatedProgram -> A.GlobalIndex -> [Text] -> (Either R.RuntimeError R.Observation, Text) -> Assertion
compareJS checked ident arguments (expected, trace) = do
  (status, out, err) <- javascript checked ident arguments
  assertEqual (T.unpack err) ExitSuccess status
  err @?= ""
  let (actualTrace, encoded) = T.breakOnEnd "\n@RESULT " out
  T.dropEnd (T.length "\n@RESULT ") actualTrace @?= trace
  J.eitherDecodeStrict (T.encodeUtf8 encoded) @?= Right (resultJSON expected)

sourceGroup :: FilePath -> [Text] -> TestTree
sourceGroup path members = withResource (compileFixture path) (const (pure ())) $ \resource ->
  testGroup
    (takeBaseName path)
    [ testCase (T.unpack member) $ do
        (_, lowered) <- resource
        ident <- maybe (assertFailure "missing fixture member" >> fail "missing member") pure (Map.lookup (GlobalId (ModuleId (T.pack (takeBaseName path) :| [])) ValueNS member) (loweredGlobals lowered))
        normalized <- requireRight (normalizeProgram (loweredProgram lowered))
        normalizeProgram (normalizedProgram normalized) @?= Right normalized
        optimized <- requireRight (optimizeTailCalls normalized)
        optimizeTailCalls optimized @?= Right optimized
        let checked = normalizedProgram optimized
            arguments = [R.LiteralValue A.Unit]
        baseline <- capture (\effects -> runDirect effects (loweredProgram lowered) ident arguments)
        actual <- capture (execute checked ident arguments)
        actual @?= baseline
        compareJS checked ident ["null"] actual
    | member <- members
    ]

smallProgram :: A.Expr -> A.Program
smallProgram expression = A.Program V.empty 1 (V.fromList [A.Node (A.ConstructorLayout (A.FrameSize n)) | n <- [0, 2, 2]]) Map.empty Map.empty Nothing (V.fromList P.allPrimitives) [A.Node (A.GlobalGroup False ((A.GlobalIndex 0, A.Node (A.Binding expression True)) :| []))]

primitive :: P.Primitive () -> [A.Expr] -> A.Expr
primitive operation arguments = A.Node (A.Primitive (A.PrimitiveIndex (maybe (-1) id (P.primitiveIndex operation))) arguments "")

integer :: Int64 -> A.Expr
integer = A.Node . A.Literal . A.Integer

tests :: TestTree
tests =
  testGroup
    "multipass compiler"
    [ sourceGroup "test/fixtures/backend/compiler/Order.ficus" ["ordered", "failure", "firstBoundary", "lastBoundary", "capture", "record", "failedStore"],
      sourceGroup "test/fixtures/backend/compiler/Primitives.ficus" ["integers", "floats", "unicode", "vectors", "convert", "conversionError", "catchAll", "matchError"],
      sourceGroup "test/fixtures/lazy-arrows/Execution.ficus" ["repeated", "skipped", "shared", "patternOnce", "patternUnused", "wildcardConstructor", "unitDemand", "operandOrder", "forwarded", "mixedOrder", "partialCalls", "captured", "changing", "closureDemand", "repeatedFailure", "skipFailure", "skipDivergence", "clauseAttempts", "clauseOrder", "lambda", "annotatedLambda", "annotatedVariable", "annotatedWildcard", "lambdaPattern", "higherOrder", "typeApplication", "polymorphic", "method", "recordField", "strictMatch", "shortCircuit", "calleeOrder", "patternBeforeStrict"],
      sourceGroup "test/fixtures/compile/exceptions/Positive.ficus" ["normal", "caught", "nested", "handlerThrows", "mismatched", "alias", "parameterized", "phantom", "polymorphic", "superclass", "functionResult", "partial", "skipArgument", "outsideHandler", "outsideAction", "failedStore", "completedStore", "listPayload", "productPayload", "primitiveMismatch", "strictOrder", "noReplay", "uncaught", "mismatchedMatch", "handlerFailure"],
      sourceGroup "test/fixtures/compile/exceptions/SomeException.ficus" ["integer", "boolean", "custom", "primitive", "unpack", "rethrow", "manual", "normal", "nearest", "evidence", "rethrowValue", "repack"],
      withResource (compileFixture "test/fixtures/backend/compiler/TailCalls.ficus") (const (pure ())) $ \resource ->
        testGroup
          "deep tail transfers"
          [ testCase (T.unpack member) $ do
              (_, lowered) <- resource
              ident <- maybe (assertFailure "missing tail member" >> fail "missing tail member") pure (Map.lookup (GlobalId (ModuleId ("TailCalls" :| [])) ValueNS member) (loweredGlobals lowered))
              optimized <- requireRight (optimizeProgram (loweredProgram lowered))
              let arguments = map (R.LiteralValue . A.Integer) numbers
                  expectedResult = (Right (R.LiteralObservation (A.Integer expected)), "")
              actual <- capture (execute optimized ident arguments)
              actual @?= expectedResult
              compareJS optimized ident (map (\n -> T.pack (show n) <> "n") numbers) expectedResult
          | (member, numbers, expected) <- [("self", [200000, 0], 200000), ("mutual", [200000], 7), ("local", [200000], 9), ("indirect", [200000], 11), ("dictionary", [200000], 12), ("swap", [200001, 1, 2], 21), ("lazyChain", [200000], 13), ("protected", [200000], 19), ("pending", [40], 40)]
          ],
      testCase "JavaScript literals escape control characters and source delimiters" $ do
        let value = "\NUL\n\r\t\"'\\${text}`\x2028\x2029😀"
        checked <- requireRight (R.validateProgram (smallProgram (A.Node (A.Literal (A.String value)))))
        optimized <- requireRight (optimizeProgram checked)
        compareJS optimized (A.GlobalIndex 0) [] (Right (R.LiteralObservation (A.String value)), ""),
      withResource (compileFixture "test/fixtures/compile/file-io/FileIO.ficus") (const (pure ())) $ \resource ->
        testGroup
          "JavaScript file modes"
          [ testCase (T.unpack member) $ do
              (_, lowered) <- resource
              ident <- maybe (assertFailure "missing IO member" >> fail "missing IO member") pure (Map.lookup (GlobalId (ModuleId ("FileIO" :| [])) ValueNS member) (loweredGlobals lowered))
              optimized <- requireRight (optimizeProgram (loweredProgram lowered))
              withScript "hello" $ \path -> do
                compareJS optimized ident [stringLiteral (T.pack path)] (Right (R.LiteralObservation (A.String expected)), "")
                TIO.readFile path >>= (@?= contents)
          | (member, expected, contents) <- [("roundTrip", "a😀\r\nb", "a😀\r\nb"), ("append", "first|last", "first|last"), ("truncate", "", ""), ("readWrite", "Hello", "Hello"), ("missing", "openFile", "hello"), ("closedRead", "read", "hello"), ("closedWrite", "write", ""), ("readOnlyWrite", "write", "hello"), ("writeOnlyRead", "read", ""), ("closeStandard", "close", "hello"), ("zeroClosedRead", "", "hello"), ("doubleClose", "closed", "hello")]
          ],
      testCase "standard input counts code points without losing line endings" $ do
        (compiled, _) <- compileFixture "test/fixtures/backend/compiler/InputMain.ficus"
        support <- TIO.readFile "runtime/javascript.mjs"
        code <- requireRight (compileJavaScript support (ModuleId ("InputMain" :| [])) compiled)
        withScript code $ \script -> do
          (status, out, err) <- readProcessWithExitCode "node" [script] "😀a\r\nz"
          (status, out, err) @?= (ExitSuccess, "😀a\r\nz", ""),
      testCase "validators reject tail transfers in initializers and non-normal operands" $ do
        let invalid = smallProgram (A.Node (A.TailCall (integer 1) (integer 2)))
        case R.validateProgram invalid of
          Right _ -> assertFailure "invalid tail transfer accepted"
          Left errors -> mapM_ (\problem -> (E.errorKind problem, E.errorSpan problem) @?= (E.InvalidProgram, E.runtimeSpan)) errors
        let unnormalized = smallProgram (primitive P.IntAdd [primitive P.IntAdd [integer 1, integer 2], integer 3])
        case validateNormalized unnormalized of
          Right _ -> assertFailure "complex ANF operand accepted"
          Left errors -> mapM_ (\problem -> (E.errorKind problem, E.errorSpan problem) @?= (E.InvalidProgram, E.runtimeSpan)) errors,
      testCase "tail pass leaves calls with pending work unmarked" $ do
        (_, lowered) <- compileFixture "test/fixtures/backend/compiler/TailCalls.ficus"
        optimized <- requireRight (optimizeProgram (loweredProgram lowered))
        let allNodes expression = expression : concatMap allNodes (children expression)
            nodes = concatMap (allNodes . A.functionBody . A.nodeValue) (A.programFunctions (R.validatedProgram optimized))
        assertBool "no marked tail calls" (any (\node -> case A.nodeValue node of A.TailCall _ _ -> True; _ -> False) nodes)
        assertBool "non-tail calls were erased" (any (\node -> case A.nodeValue node of A.Call _ _ -> True; _ -> False) nodes),
      localOption (QC.QuickCheckTests 30) $ QC.testProperty "arithmetic ANF agrees with independent oracle and both backends" $ \(a :: Int64) (b :: Int64) (c :: Int64) -> QC.ioProperty $ do
        checked <- requireRight (R.validateProgram (smallProgram (primitive P.IntMultiply [primitive P.IntAdd [integer a, integer b], primitive P.IntSubtract [integer c, integer a]])))
        optimized <- requireRight (optimizeProgram checked)
        let expected = (Right (R.LiteralObservation (A.Integer ((a + b) * (c - a)))), "")
        capture (\effects -> runDirect effects checked (A.GlobalIndex 0) []) >>= (@?= expected)
        capture (execute optimized (A.GlobalIndex 0) []) >>= (@?= expected)
        compareJS optimized (A.GlobalIndex 0) [] expected
        pure True,
      testGroup "standalone programs" [entryTest name arguments expected status | (name, arguments, expected, status) <- [("UnitMain", [], "", ExitSuccess), ("OkMain", [], "", ExitSuccess), ("ErrMain", [], "entry failed\n", ExitFailure 1), ("ArgsMain", ["hello", "world"], "hello\n", ExitSuccess)]],
      testCase "standalone file IO and command-line arguments" $ do
        (compiled, _) <- compileFixture "test/fixtures/backend/compiler/FileMain.ficus"
        support <- TIO.readFile "runtime/javascript.mjs"
        code <- requireRight (compileJavaScript support (ModuleId ("FileMain" :| [])) compiled)
        withScript "" $ \path -> withScript code $ \script -> do
          (status, out, err) <- readProcessWithExitCode "node" [script, path] ""
          (status, out, err) @?= (ExitSuccess, "a😀\n\r\nb\n\nread\n", "")
          TIO.readFile path >>= (@?= "a😀\r\nb")
    ]

entryTest :: String -> [String] -> String -> ExitCode -> TestTree
entryTest name arguments expected status = testCase name $ do
  (compiled, _) <- compileFixture ("test/fixtures/backend/driver/" <> name <> ".ficus")
  support <- TIO.readFile "runtime/javascript.mjs"
  code <- requireRight (compileJavaScript support (ModuleId (T.pack name :| [])) compiled)
  withScript code $ \script -> do
    (actual, out, err) <- readProcessWithExitCode "node" (script : arguments) ""
    actual @?= status
    if status == ExitSuccess then (out, err) @?= (expected, "") else (out, err) @?= ("", expected)
