module FicusBackend.RecordPatternSpec (tests) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Compile
import Ficus.Elaborate (checkedCore)
import Ficus.Error.Diagnostic qualified as D
import Ficus.ModuleOptions (ModuleOptions (..))
import Ficus.Resolve (frontendModules)
import Ficus.Resolve.Support (fixtureConfig, fixtureSugar)
import Ficus.Syntax.Abstract qualified as Abstract
import Ficus.Syntax.Abstract.Validate (validateAbstract)
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
root = "test/fixtures/compile/record-patterns/"

compileFixture :: String -> IO CompileResult
compileFixture name = compileFiles fixtureConfig fixtureSugar (ModuleOptions [root] ["test/fixtures/support"] Nothing) ((root ++ name ++ ".ficus") :| [])

requireRight :: (Show e) => Either e a -> IO a
requireRight = either (\problem -> assertFailure (show problem) >> fail "record pattern fixture failed") pure

execution :: String -> Text -> R.Observation -> [Text] -> TestTree
execution file member expected trace = testCase (file ++ "." ++ T.unpack member) $ do
  compiled <- compileFixture file
  assertBool (show (compileDiagnostics compiled)) (compileSucceeded compiled)
  mapM_ (\tree -> validateAbstract tree @?= Right ()) (Map.elems (frontendModules (compileFrontend compiled)))
  mapM_ (\checked -> validateCore (validatedModule (checkedCore checked)) @?= []) (Map.elems (compileModules compiled))
  lowered <- requireRight (lowerProgram [validatedModule (checkedCore checked) | owner <- compileOrder compiled, Just checked <- [Map.lookup owner (compileModules compiled)]])
  ident <- maybe (assertFailure "missing record pattern entry" >> fail "missing entry") pure (Map.lookup (GlobalId (ModuleId (T.pack file :| [])) ValueNS member) (loweredGlobals lowered))
  entry <- requireRight (R.selectEntry (loweredProgram lowered) ident)
  let capture action = do
        output <- newIORef []
        let effects = R.Effects (\_ text -> modifyIORef' output (<> [text])) (\_ _ -> pure "")
        result <- action effects
        observed <- readIORef output
        pure (fmap R.observe result, observed)
      arguments = [R.LiteralValue A.Unit]
  actual <- capture (\effects -> R.runProgram effects (R.compileProgram (loweredProgram lowered)) entry arguments)
  direct <- capture (\effects -> runDirect effects (loweredProgram lowered) ident arguments)
  actual @?= (Right expected, trace)
  direct @?= actual

failure :: String -> Text -> [Int] -> TestTree
failure name code coordinates = testCase name $ do
  compiled <- compileFixture name
  compileSucceeded compiled @?= False
  let position d = let s = D.diagnosticSpan d in [line (start s), column (start s), line (end s), column (end s)]
  assertBool (show (compileDiagnostics compiled)) (any (\d -> D.diagnosticCode d == code && position d == coordinates) (compileDiagnostics compiled))

tests :: TestTree
tests =
  testGroup
    "explicit record patterns"
    [ execution "ExistentialClient" "check" (R.LiteralObservation (A.String "23")) [],
      execution "Existential" "check" (R.LiteralObservation (A.String "42")) [],
      execution "Existential" "boolean" (R.LiteralObservation (A.String "True")) [],
      execution "Existential" "string" (R.LiteralObservation (A.String "hello")) [],
      execution "Existential" "localCheck" (R.LiteralObservation (A.String "7")) [],
      execution "Existential" "positional" (R.LiteralObservation (A.String "9")) [],
      execution "Existential" "inferred" (R.LiteralObservation (A.String "10")) [],
      execution "Existential" "omitted" (integer 12) [],
      execution "Existential" "repacked" (R.LiteralObservation (A.String "13")) [],
      execution "Existential" "forwardWhereCheck" (R.LiteralObservation (A.String "22")) [],
      execution "Existential" "whereCheck" (R.LiteralObservation (A.String "14")) [],
      execution "Existential" "lambdaCheck" (R.LiteralObservation (A.String "15")) [],
      execution "Existential" "doCheck" (R.LiteralObservation (A.String "16")) [],
      execution "Existential" "higher" (integer 17) [],
      execution "Existential" "tagged" (R.AggregateObservation A.pairConstructor [integer 18, R.LiteralObservation (A.String "19")]) [],
      execution "Existential" "independent" (integer 20) [],
      execution "Existential" "order" (R.LiteralObservation (A.String "21")) ["render", "value"],
      failure "ExistentialTypeMemberProjection" "T0302" [2, 21, 2, 23],
      failure "ExistentialInitializerScope" "N0007" [3, 57, 3, 57],
      failure "ExistentialOuterEscape" "T0305" [2, 37, 2, 45],
      failure "ExistentialLocalEscape" "T0305" [2, 41, 2, 41],
      failure "ExistentialTopEscape" "T0305" [2, 1, 2, 38],
      failure "ExistentialTypeWildcard" "N0016" [2, 37, 2, 37],
      failure "ExistentialUnknownPattern" "N0013" [2, 31, 2, 35],
      failure "ExistentialDuplicatePattern" "N0014" [2, 40, 2, 42],
      failure "ExistentialEvidence" "T0305" [2, 17, 2, 22],
      failure "ExistentialTypePattern" "N0016" [2, 43, 2, 45],
      failure "ExistentialKind" "T0003" [2, 29, 2, 33],
      failure "ExistentialMismatch" "T0001" [2, 42, 2, 45],
      failure "ExistentialEscape" "T0305" [2, 55, 2, 55],
      failure "ExistentialAnonymousEscape" "T0305" [2, 17, 2, 17],
      failure "ExistentialProjection" "T0306" [2, 7, 2, 25],
      failure "ExistentialUpdate" "T0307" [2, 19, 2, 19],
      failure "ExistentialSeparate" "T0001" [2, 35, 2, 35],
      failure "ExistentialDuplicate" "T0303" [2, 34, 2, 36],
      failure "ExistentialUnknown" "T0302" [2, 23, 2, 27],
      execution "Positive" "check" (integer 36) [],
      execution "Positive" "effect" (integer 6) ["once"],
      execution "Positive" "polymorphic" (R.AggregateObservation A.pairConstructor [integer 1, R.LiteralObservation (A.Boolean True)]) [],
      execution "Positive" "polymorphicTop" (R.AggregateObservation A.pairConstructor [integer 1, R.LiteralObservation (A.Boolean True)]) [],
      execution "Positive" "monadic" (integer 7) [],
      execution "Positive" "recursive" (integer 0) [],
      execution "TopEffect" "check" (integer 9) ["first", "discard"],
      execution "Client" "check" (integer 19) [],
      testCase "omitted field wildcards inherit their record pattern origin" $ do
        compiled <- compileFixture "Positive"
        assertBool (show (compileDiagnostics compiled)) (compileSucceeded compiled)
        let omitted =
              [ (pattern', field)
              | tree <- Map.elems (frontendModules (compileFrontend compiled)),
                declaration <- Abstract.declarations (Abstract.abstractDeclarations tree),
                Abstract.PatternDefinition pattern' _ <- [Abstract.nodeValue declaration],
                Abstract.ConstructorPattern _ fields <- [Abstract.nodeValue pattern'],
                field <- fields,
                GeneratedOrigin "omitted record field" _ <- [Abstract.nodeOrigin field]
              ]
        assertBool "expected omitted value fields" (not (null omitted))
        mapM_
          ( \(pattern', field) -> do
              Abstract.nodeValue field @?= Abstract.Wildcard
              Abstract.nodeSpan field @?= Abstract.nodeSpan pattern'
              Abstract.nodeOrigin field @?= GeneratedOrigin "omitted record field" (Abstract.nodeSpan pattern')
          )
          omitted,
      failure "Duplicate" "N0014" [2, 36, 2, 36],
      failure "Unknown" "N0013" [2, 17, 2, 17],
      failure "NonRecord" "N0003" [2, 4, 2, 6],
      failure "RecursiveTop" "N0015" [2, 1, 2, 24],
      failure "RecursiveWhere" "N0015" [2, 22, 2, 45],
      failure "RefutableDo" "T0203" [2, 17, 2, 46]
    ]
  where
    integer = R.LiteralObservation . A.Integer
