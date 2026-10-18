module Ficus.Infer.TypeSpec (tests) where

import Control.Monad (void)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Ficus.Error.Diagnostic qualified as D
import Ficus.Error.Type qualified as E
import Ficus.Infer.Monad
import Ficus.Infer.Type
import Ficus.Infer.Unify
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Type
import Ficus.Type.Substitution qualified as S
import Ficus.Util.Source
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck hiding (function, monomorphic)

origin :: Span
origin = Span "Types.ficus" (Position 2 3 10) (Position 2 7 14)

meta :: Int -> InferType
meta n = Variable (Meta (MetaId n)) TypeKind

int, bool :: InferType
int = primitive IntType
bool = primitive BoolType

tests :: TestTree
tests =
  testGroup
    "semantic types and inference solver"
    [ testCase "occurs check prevents infinite types" $
        unify (meta 0) (function (meta 0) int) @?= Left (InfiniteType (MetaId 0) (function (meta 0) int)),
      testCase "signature skolems are rigid" $
        unify (Variable (Skolem (SkolemId 0)) TypeKind) int @?= Left (TypesDiffer (Variable (Skolem (SkolemId 0)) TypeKind) int),
      testCase "nominal identities do not unify by spelling" $ do
        let a = Constructor (GlobalId (ModuleId ("A" :| [])) TypeNS "Box") TypeKind
            b = Constructor (GlobalId (ModuleId ("B" :| [])) TypeNS "Box") TypeKind
        unify a b @?= Left (TypesDiffer a b),
      testCase "kind mismatch rejects a higher-kinded type argument" $
        unify (meta 0) (primitive ListType) @?= Left (KindsDiffer (KindMismatch TypeKind (KindArrow TypeKind TypeKind))),
      testCase "ill-kinded applications fail even if syntactically equal" $ do
        let invalid = Application int bool
        unify invalid invalid @?= Left (KindsDiffer (NotATypeFunction TypeKind)),
      testCase "higher-kinded unification" $ do
        let f = Variable (Meta (MetaId 0)) (KindArrow TypeKind TypeKind)
        case unify (Application f int) (list int) of
          Right s -> S.apply s f @?= primitive ListType
          Left e -> assertFailure (show e),
      testCase "one-way matching does not specialize a wanted meta" $
        match int (meta 0) @?= Left (TypesDiffer int (meta 0)),
      testCase "repeated pattern variables require equal targets" $
        match (function (meta 0) (meta 0)) (function int bool) @?= Left (TypesDiffer int bool),
      testCase "matching retains identity assignments for repeated variables" $
        match (function (meta 0) (meta 0)) (function (meta 0) int) @?= Left (TypesDiffer (meta 0) int),
      testCase "matching never rewrites target variables" $ do
        let patternType = function (meta 0) (meta 1)
            targetType = function (meta 1) int
        case match patternType targetType of
          Left e -> assertFailure (show e)
          Right s -> S.apply s patternType @?= targetType,
      testCase "instantiations are fresh and preserve sharing within a use" $ do
        let bound = Variable (Bound (BoundId 0)) TypeKind
            scheme = Scheme [Quantifier (BoundId 0) "a" TypeKind] [] [] (function bound bound)
            ((a, b), _) = runInfer $ do
              (first, _, _) <- instantiate origin scheme
              (second, _, _) <- instantiate origin scheme
              pure (first, second)
        assertBool "different instantiations" (a /= b)
        case functionParts a of
          Just (input, output) -> input @?= output
          Nothing -> assertFailure "expected function type",
      testCase "generalization excludes environment variables" $ do
        let (scheme, _) = runInfer $ do
              outer <- fresh origin TypeKind
              local <- fresh origin TypeKind
              generalize origin True [monomorphic outer] [] (function outer local)
        length (quantifiers scheme) @?= 1
        freeSchemeVariables scheme @?= Set.singleton (Meta (MetaId 0)),
      testCase "weakness follows substitutions and non-expansive aliases" $ do
        let (scheme, state) = runInfer $ do
              weak <- fresh origin TypeKind
              markWeak origin ValueRestriction weak
              element <- fresh origin TypeKind
              void (equate origin weak (list element))
              alias <- generalize origin True [] [] element
              finishWeakVariables
              pure alias
        quantifiers scheme @?= []
        map E.diagnosticCode (diagnostics state) @?= [E.UnresolvedWeakType],
      testCase "later use can solve a weak type" $ do
        let (_, state) = runInfer $ do
              weak <- fresh origin TypeKind
              markWeak origin ValueRestriction weak
              void (equate origin weak int)
              finishWeakVariables
        diagnostics state @?= [],
      testCase "failed equality retains its kind and exact primary span" $ do
        let (_, state) = runInfer (equate origin int bool)
        map E.diagnosticCode (diagnostics state) @?= [E.TypeMismatch]
        map E.diagnosticSpan (diagnostics state) @?= [origin]
        map (D.diagnosticCode . D.toDiagnostic) (diagnostics state) @?= ["T0001"],
      testCase "rendering distinguishes application, products and arrows" $
        renderInferType (function (productType int bool) (list (function int int))) @?= "Int * Bool -> [Int -> Int]",
      testProperty "substitution composition agrees with successive application" $
        forAll smallType $ \ty ->
          let older = S.singleton (Meta (MetaId 0)) (list (meta 1))
              newer = S.singleton (Meta (MetaId 1)) int
           in S.apply (S.compose newer older) ty === S.apply newer (S.apply older ty),
      testProperty "successful unifiers equate inputs and are idempotent" $
        forAll ((,) <$> smallType <*> smallType) $ \(a, b) ->
          case unify a b of
            Left _ -> property True
            Right s -> conjoin [S.apply s a === S.apply s b, S.apply s (S.apply s a) === S.apply s a],
      testProperty "unification with a concrete instance succeeds" $
        forAll smallType $ \ty ->
          let ground = S.compose (S.singleton (Meta (MetaId 0)) int) (S.singleton (Meta (MetaId 1)) bool)
              concrete = S.apply ground ty
           in case unify ty concrete of
                Left e -> counterexample (show e) False
                Right s -> S.apply s ty === concrete
    ]

smallType :: Gen InferType
smallType = sized (go . min 5)
  where
    go 0 = elements [int, bool, meta 0, meta 1]
    go n = frequency [(3, go 0), (1, list <$> go (n - 1)), (1, function <$> go (n `div` 2) <*> go (n `div` 2)), (1, productType <$> go (n `div` 2) <*> go (n `div` 2))]
