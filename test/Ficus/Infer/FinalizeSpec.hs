module Ficus.Infer.FinalizeSpec (tests) where

import Control.Monad (void)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Ficus.CompilationConfig
import Ficus.Elaborate.Finalize
import Ficus.Error.Type qualified as E
import Ficus.Infer.Monad
import Ficus.Infer.Type
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Core.Validate
import Ficus.Syntax.Literal qualified as L
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Type
import Ficus.Util.Source
import Test.Tasty
import Test.Tasty.HUnit

origin :: Span
origin = Span "Finalize.ficus" (Position 2 3 10) (Position 2 7 14)

node :: Int -> a -> C.Node a
node ident = C.Node (NodeId ident) origin (SourceOrigin origin)

tree :: InferType -> C.ExprF InferType -> C.CoreModule InferType
tree ty form =
  C.CoreModule
    owner
    defaultCompilationConfig
    origin
    (SourceOrigin origin)
    Map.empty
    Map.empty
    Map.empty
    Map.empty
    Map.empty
    Map.empty
    Map.empty
    [C.NonRecursive (node 0 (C.Binding (GlobalRef (GlobalId owner ValueNS "value")) (monomorphic ty) (node 1 (C.TypedExpr ty form)) (C.BindingFacts 0 Nothing)))]
    Map.empty
  where
    owner = ModuleId ("Finalize" :| [])

tests :: TestTree
tests =
  testGroup
    "Core finalization"
    [ testCase "finalization does not repeat already reported weak-variable errors" $ do
        let (result, _) = runInfer $ do
              ty <- fresh origin TypeKind
              markWeak origin ValueRestriction ty
              finishWeakVariables
              finalizeModule (tree ty C.Fail)
        case result of
          Complete _ _ -> assertFailure "unresolved weak variable was accepted"
          Incomplete _ errors -> do
            map E.diagnosticCode errors @?= [E.UnresolvedWeakType]
            map E.diagnosticSpan errors @?= [origin],
      testCase "solved inference types become closed accepted Core" $ do
        let (result, _) = runInfer $ do
              ty <- fresh origin TypeKind
              void (equate origin ty (primitive IntType))
              finalizeModule (tree ty (C.Literal (L.IntegerLiteral "1")))
        case result of
          Incomplete _ errors -> assertFailure (show errors)
          Complete core errors -> do
            errors @?= []
            validateCore (validatedModule core) @?= [],
      testCase "a fully solved hole reports its zonked type and lexical context" $ do
        let (result, _) = runInfer $ do
              ty <- fresh origin TypeKind
              let input = (tree ty (C.Hole (HoleId 0))) {C.coreGoals = Map.singleton (HoleId 0) (node 2 (C.HoleGoal (HoleId 0) ty [node 3 ("x", monomorphic ty)] []))}
              void (equate origin ty (primitive IntType))
              finalizeModule input
        case result of
          Complete _ _ -> assertFailure "hole cannot be accepted"
          Incomplete output errors -> do
            map E.diagnosticCode errors @?= [E.ExpressionHole]
            map E.diagnosticSpan errors @?= [origin]
            assertBool "goal type" (any (T.isInfixOf "type Int" . E.diagnosticMessage) errors)
            assertBool "context type" (any (T.isInfixOf "x : Int" . E.diagnosticMessage) errors)
            validateCore output @?= [],
      testCase "hole diagnostics retain independent type errors" $ do
        let (result, _) = runInfer $ do
              let int = primitive IntType
                  input = (tree int (C.Hole (HoleId 0))) {C.coreGoals = Map.singleton (HoleId 0) (node 2 (C.HoleGoal (HoleId 0) int [] []))}
              void (equate origin int (primitive BoolType))
              finalizeModule input
        case result of
          Complete _ _ -> assertFailure "errors cannot be accepted"
          Incomplete _ errors -> map E.diagnosticCode errors @?= [E.TypeMismatch, E.ExpressionHole],
      testCase "unresolved diagnostic placeholders never become accepted types" $ do
        let (result, _) = runInfer $ do
              ty <- fresh origin TypeKind
              finalizeModule (tree ty C.Fail)
        case result of
          Complete _ _ -> assertFailure "unsolved metavariable escaped"
          Incomplete _ errors -> map E.diagnosticCode errors @?= [E.InvalidCoreTree],
      testCase "escaping signature skolems prevent acceptance" $ do
        let (result, _) = runInfer $ do
              ty <- freshSkolem TypeKind
              finalizeModule (tree ty C.Fail)
        case result of
          Complete _ _ -> assertFailure "skolem escaped"
          Incomplete _ errors -> map E.diagnosticCode errors @?= [E.InvalidAnnotation]
    ]
