module Ficus.CompileSpec (tests) where

import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Ficus.Compile
import Ficus.Elaborate (checkedCore)
import Ficus.Error.Diagnostic qualified as D
import Ficus.Error.Pretty (prettyDiagnosticWithOptionalSourceRelativeTo)
import Ficus.Error.Resolve qualified as R
import Ficus.Error.Type qualified as E
import Ficus.Library.Contracts
import Ficus.Resolve
import Ficus.Syntax.Core.Validate
import Ficus.Syntax.Name
import Ficus.Util.Source
import System.FilePath (takeFileName)
import Test.Tasty
import Test.Tasty.HUnit

check :: CompileOptions -> IO CompileResult
check = compileFiles libraryResolveConfig librarySugarRegistry

baseOptions :: FilePath -> CompileOptions
baseOptions file = CompileOptions (file :| []) [] ["library"] Nothing

tests :: TestTree
tests =
  testGroup
    "compile driver"
    [ testCase "placeholder Prelude resolves without a main declaration" $ do
        result <- check (baseOptions "test/fixtures/semantics/name-resolution/positive/EqualClauseArity.ficus")
        compileSucceeded result @?= True,
      testCase "implicit Prelude is found in the library root" $ do
        result <- check (baseOptions "test/fixtures/semantics/type-checking/positive/MiniPrelude.ficus")
        compileSucceeded result @?= True
        assertBool "Prelude loaded" (Map.member (ModuleId ("Prelude" :| [])) (frontendModules (compileFrontend result))),
      testCase "explicit source root preserves nested module identity" $ do
        result <- check ((baseOptions "test/fixtures/semantics/name-resolution/support/Resolve/Left.ficus") {projectRoots = ["test/fixtures/semantics/name-resolution/support"]})
        compileSucceeded result @?= True
        assertBool "Resolve.Left identity" (Map.member (ModuleId ("Resolve" :| ["Left"])) (frontendModules (compileFrontend result))),
      testCase "Prelude override works without a library search root" $ do
        result <- check ((baseOptions "test/fixtures/semantics/type-checking/positive/MiniPrelude.ficus") {libraryRoots = [], preludeFile = Just "library/Prelude.ficus"})
        compileSucceeded result @?= True,
      testCase "NO_IMPLICIT_PRELUDE does not require any library" $ do
        result <- check ((baseOptions "test/fixtures/semantics/name-resolution/positive/EqualClauseArity.ficus") {libraryRoots = []})
        compileSucceeded result @?= True,
      testCase "missing Prelude is an error" $ do
        result <- check ((baseOptions "test/fixtures/semantics/type-checking/positive/MiniPrelude.ficus") {libraryRoots = []})
        compileSucceeded result @?= False
        assertBool "module not found" (any ((== "N0201") . D.diagnosticCode . D.toDiagnostic) (frontendDiagnostics (compileFrontend result))),
      testCase "all entry files are checked after an independent error" $ do
        result <- check ((baseOptions "test/fixtures/semantics/name-resolution/negative/UnknownPragma.ficus") {inputFiles = "test/fixtures/semantics/name-resolution/negative/UnknownPragma.ficus" :| ["test/fixtures/semantics/name-resolution/positive/EqualClauseArity.ficus"]})
        compileSucceeded result @?= False
        assertBool "valid entry still resolved" (Map.member (ModuleId ("EqualClauseArity" :| [])) (frontendModules (compileFrontend result))),
      testCase "diagnostics retain exact source for excerpts" $ do
        result <- check (baseOptions "test/fixtures/semantics/name-resolution/negative/ClauseArityMismatch.ficus")
        compileSucceeded result @?= False
        case frontendDiagnostics (compileFrontend result) of
          d : _ -> do
            let path = sourceFile (D.diagnosticSpan (D.toDiagnostic d))
            assertBool "source retained" (maybe False (T.isInfixOf "foo x = y -> y") (Map.lookup path (compileSources result)))
          [] -> assertFailure "expected a diagnostic",
      testCase "invalid entry names produce a located diagnostic" $ do
        result <- check (baseOptions "test/fixtures/compile/invalid/main.ficus")
        compileSucceeded result @?= False
        case frontendDiagnostics (compileFrontend result) of
          d : _ -> do
            D.diagnosticCode (D.toDiagnostic d) @?= R.renderResolveCode R.InvalidModuleIdentity
            line (start (D.diagnosticSpan (D.toDiagnostic d))) @?= 1
            let path = sourceFile (D.diagnosticSpan (D.toDiagnostic d))
                output = prettyDiagnosticWithOptionalSourceRelativeTo "." (Map.lookup path (compileSources result)) d
            assertBool "no source excerpt for a filename error" (not (" |" `T.isInfixOf` output))
          [] -> assertFailure "expected an invalid module identity",
      testCase "overlapping project roots do not choose a module identity" $ do
        result <- check ((baseOptions "test/fixtures/semantics/name-resolution/support/Resolve/Left.ficus") {projectRoots = ["test/fixtures/semantics/name-resolution/support", "test/fixtures/semantics/name-resolution/support/Resolve"]})
        compileSucceeded result @?= False,
      testCase "missing entry files each have their own diagnostic" $ do
        result <- check ((baseOptions "DoesNotExist.ficus") {inputFiles = "DoesNotExist.ficus" :| ["AlsoAbsent.ficus"]})
        compileSucceeded result @?= False
        let ds = frontendDiagnostics (compileFrontend result)
        sort (map (takeFileName . sourceFile . D.diagnosticSpan . D.toDiagnostic) ds) @?= ["AlsoAbsent.ficus", "DoesNotExist.ficus"]
        map (D.diagnosticCode . D.toDiagnostic) ds @?= ["N0201", "N0201"],
      testCase "missing entry files are reported before invalid module names" $ do
        let files = "examples/ain.ficus" :| ["examples/absent.txt"]
        result <- check ((baseOptions "examples/ain.ficus") {inputFiles = files})
        compileSucceeded result @?= False
        let ds = map D.toDiagnostic (frontendDiagnostics (compileFrontend result))
        map D.diagnosticCode ds @?= ["N0201", "N0201"]
        map (takeFileName . sourceFile . D.diagnosticSpan) ds @?= ["ain.ficus", "absent.txt"]
        map (start . D.diagnosticSpan) ds @?= replicate 2 (Position 1 1 0)
        assertBool "missing files have no source excerpts" (Map.null (compileSources result)),
      testCase "warnings do not fail compilation" $ do
        result <- check (baseOptions "test/fixtures/semantics/name-resolution/positive/SequentialDifferentArities.ficus")
        compileSucceeded result @?= True
        assertBool "shadowing warning" (any ((== D.Warning) . D.diagnosticSeverity . D.toDiagnostic) (frontendDiagnostics (compileFrontend result))),
      testCase "successful compilation returns validated typed Core" $ do
        result <- check (baseOptions "test/fixtures/semantics/type-checking/positive/MiniPrelude.ficus")
        compileSucceeded result @?= True
        assertBool "checked modules returned" (not (Map.null (compileModules result)))
        mapM_ (\checked -> validateCore (validatedModule (checkedCore checked)) @?= []) (Map.elems (compileModules result)),
      testCase "a resolved type error fails compilation at its source span" $ do
        result <- check (baseOptions "test/fixtures/semantics/type-checking/negative/ApplicationMismatch.ficus")
        compileSucceeded result @?= False
        let matching = filter ((== E.TypeMismatch) . E.diagnosticCode) (compileTypeDiagnostics result)
        map (\d -> (line (start (E.diagnosticSpan d)), column (start (E.diagnosticSpan d)), column (end (E.diagnosticSpan d)))) matching @?= [(1, 14, 14)]
        Map.member (ModuleId ("ApplicationMismatch" :| [])) (compileModules result) @?= False,
      testCase "a fully typed hole fails compilation and publishes no interface" $ do
        result <- check (baseOptions "test/fixtures/semantics/type-checking/negative/TypedExpressionHole.ficus")
        compileSucceeded result @?= False
        let matching = filter ((== E.ExpressionHole) . E.diagnosticCode) (compileTypeDiagnostics result)
        map (\d -> (line (start (E.diagnosticSpan d)), column (start (E.diagnosticSpan d)))) matching @?= [(2, 9)]
        Map.member (ModuleId ("TypedExpressionHole" :| [])) (compileModules result) @?= False,
      testCase "checked interfaces retain reexported polymorphism and trait kinds" $ do
        result <- check ((baseOptions "test/fixtures/compile/typing/Main.ficus") {libraryRoots = []})
        assertBool (show (compileDiagnostics result)) (compileSucceeded result)
        Map.size (compileModules result) @?= 3
        mapM_ (\checked -> validateCore (validatedModule (checkedCore checked)) @?= []) (Map.elems (compileModules result)),
      testCase "failed dependencies publish no interface while independent modules continue" $ do
        result <- check ((baseOptions "test/fixtures/compile/typing/Dependent.ficus") {inputFiles = "test/fixtures/compile/typing/Dependent.ficus" :| ["test/fixtures/compile/typing/Main.ficus"], libraryRoots = []})
        compileSucceeded result @?= False
        Map.member (ModuleId ("Failure" :| [])) (compileModules result) @?= False
        Map.member (ModuleId ("Dependent" :| [])) (compileModules result) @?= False
        Map.member (ModuleId ("Main" :| [])) (compileModules result) @?= True
        let matching = filter ((== E.TypeMismatch) . E.diagnosticCode) (compileTypeDiagnostics result)
        map (\d -> (line (start (E.diagnosticSpan d)), column (start (E.diagnosticSpan d)), column (end (E.diagnosticSpan d)))) matching @?= [(3, 7, 10)]
    ]
