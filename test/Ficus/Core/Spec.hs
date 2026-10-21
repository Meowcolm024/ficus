module Ficus.Core.Spec (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Ficus.Error.Type qualified as E
import Ficus.Initialization
import Ficus.Syntax.Core
import Ficus.Syntax.Core.Validate
import Ficus.Syntax.Literal qualified as L
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Type
import Ficus.Util.Source
import Test.Tasty
import Test.Tasty.HUnit

origin :: Span
origin = Span "Core.ficus" (Position 2 3 10) (Position 2 7 14)

node :: Int -> a -> Node a
node ident = Node (NodeId ident) origin (SourceOrigin origin)

expr :: Int -> CoreType -> ExprF CoreType -> Expr CoreType
expr ident ty form = node ident (TypedExpr ty form)

int, bool :: CoreType
int = primitive IntType
bool = primitive BoolType

owner :: ModuleId
owner = ModuleId ("Core" :| [])

global :: Reference
global = GlobalRef (GlobalId owner ValueNS "value")

moduleWith :: Scheme CoreType -> Expr CoreType -> CoreModule CoreType
moduleWith scheme body =
  CoreModule
    owner
    OrdinaryInitialization
    origin
    (SourceOrigin origin)
    Map.empty
    Map.empty
    Map.empty
    Map.empty
    Map.empty
    [NonRecursive (node 0 (Binding global scheme body (BindingFacts 0 Nothing)))]
    Map.empty

assertInvalid :: CoreModule CoreType -> Assertion
assertInvalid tree = do
  let errors = validateCore tree
  assertBool "malformed Core must be rejected" (not (null errors))
  mapM_ (\d -> E.diagnosticCode d @?= E.InvalidCoreTree) errors
  mapM_ (\d -> E.diagnosticSpan d @?= origin) errors

dictionaryFixture :: (CoreModule CoreType, GlobalId, Expr CoreType, Scheme CoreType)
dictionaryFixture =
  let trait = GlobalId owner TypeNS "Choose"
      parameter = Quantifier (BoundId 10) "a" TypeKind
      methodVariable = Quantifier (BoundId 11) "b" TypeKind
      a = Variable (BoundVariable (quantifierId parameter)) TypeKind
      b = Variable (BoundVariable (quantifierId methodVariable)) TypeKind
      methodScheme t = Scheme [] [methodVariable] [] (function b (function t b))
      descriptor = node 10 (DictionaryDescriptor parameter [] [node 11 (GlobalId owner ValueNS "choose", methodScheme a)] False)
      method = expr 12 (function b (function int b)) (Lambda (node 13 (LocalId 0, "x", ValueBinder, b)) (expr 14 (function int b) (Lambda (node 15 (LocalId 1, "ignored", ValueBinder, int)) (expr 16 b (Var (LocalRef (LocalId 0)) [])))))
      dictionaryType = Application (Constructor trait (KindArrow TypeKind TypeKind)) int
      dictionary = expr 17 dictionaryType (Dictionary trait int [] [node 18 (methodScheme int, method)])
      tree = (moduleWith (monomorphic dictionaryType) dictionary) {coreKinds = Map.singleton trait (KindArrow TypeKind TypeKind), coreDictionaries = Map.singleton trait descriptor}
   in (tree, trait, dictionary, methodScheme int)

tests :: TestTree
tests =
  testGroup
    "Core validation"
    [ testCase "accept a closed polymorphic identity" $ do
        let q = Quantifier (BoundId 0) "a" TypeKind
            a = Variable (BoundVariable (BoundId 0)) TypeKind
            binder = node 2 (LocalId 0, "x", ValueBinder, a)
            body = expr 1 (function a a) (Lambda binder (expr 3 a (Var (LocalRef (LocalId 0)) [])))
            tree = moduleWith (Scheme [] [q] [] (function a a)) body
        validateCore tree @?= []
        fmap validatedModule (acceptCore tree) @?= Right tree,
      testCase "dictionary methods retain and instantiate their own quantifiers" $ do
        let (tree, trait, dictionary, _) = dictionaryFixture
            result = function bool (function int bool)
            selection = expr 20 result (SelectMethod dictionary trait 0 [bool])
            selected = tree {coreBindings = coreBindings (moduleWith (monomorphic result) selection)}
        validateCore tree @?= []
        validateCore selected @?= []
        fmap validatedModule (acceptCore selected) @?= Right selected,
      testCase "dictionary selection validates its slot and type arguments" $ do
        let (tree, trait, dictionary, _) = dictionaryFixture
            selected = tree {coreBindings = coreBindings (moduleWith (monomorphic int) (expr 20 int (SelectMethod dictionary trait 1 [])))}
        assertInvalid selected,
      testCase "a hole in a dictionary method prevents acceptance" $ do
        let (tree, trait, dictionary, scheme) = dictionaryFixture
            goal = HoleId 9
            method = expr 19 (schemeType scheme) (Hole goal)
            body = dictionary {nodeValue = TypedExpr (typeOf dictionary) (Dictionary trait int [] [node 18 (scheme, method)])}
            incomplete = tree {coreBindings = coreBindings (moduleWith (monomorphic (typeOf body)) body), coreGoals = Map.singleton goal (node 21 (HoleGoal goal (schemeType scheme) [] []))}
        validateCore incomplete @?= []
        case acceptCore incomplete of
          Right _ -> assertFailure "dictionary hole was accepted"
          Left failures -> map E.diagnosticCode failures @?= [E.ExpressionHole],
      testCase "internal erased type binders cannot escape their scope" $ do
        let q = Quantifier (BoundId 0) "internal" TypeKind
            a = Variable (BoundVariable (quantifierId q)) TypeKind
            local = node 4 (Binding (LocalRef (LocalId 0)) (monomorphic (function a a)) (expr 5 (function a a) (Lambda (node 6 (LocalId 1, "x", ValueBinder, a)) (expr 7 a (Var (LocalRef (LocalId 1)) [])))) (BindingFacts 0 Nothing))
            scoped = expr 1 int (ScopeTypes [node 2 q] (expr 3 int (Let local (expr 8 int (Literal (L.IntegerLiteral "1"))))))
        validateCore (moduleWith (monomorphic int) scoped) @?= []
        assertInvalid (moduleWith (monomorphic a) (expr 1 a (ScopeTypes [node 2 q] (expr 3 a Fail)))),
      testCase "conditionals stay distinct and require Bool" $ do
        let value = expr 2 int (Literal (L.IntegerLiteral "1"))
            bad = expr 1 int (If [node 3 (expr 4 int (Literal (L.IntegerLiteral "0")), value)] Nothing)
        assertInvalid (moduleWith (monomorphic int) bad),
      testCase "standalone and interactive initialization permit expansive values but not cycles" $ do
        let body = expr 1 int (Primitive IntNegate [expr 2 int (Literal (L.IntegerLiteral "1"))])
            binding = node 0 (Binding global (monomorphic int) body (BindingFacts 0 (Just origin)))
            ordinary = (moduleWith (monomorphic int) body) {coreBindings = [NonRecursive binding]}
        assertInvalid ordinary
        mapM_
          ( \mode -> do
              let relaxed = ordinary {coreInitialization = mode}
              validateCore relaxed @?= []
              assertInvalid (relaxed {coreBindings = [Recursive (binding :| [])]})
          )
          [StandaloneInitialization, InteractiveInitialization],
      testCase "unbound values fail" $
        assertInvalid (moduleWith (monomorphic int) (expr 1 int (Var (LocalRef (LocalId 4)) []))),
      testCase "application types are checked independently" $ do
        let bad = expr 1 int (Apply (expr 2 int (Literal (L.IntegerLiteral "1"))) (expr 3 int (Literal (L.IntegerLiteral "2"))))
        assertInvalid (moduleWith (monomorphic int) bad),
      testCase "unbound type variables fail" $ do
        let a = Variable (BoundVariable (BoundId 8)) TypeKind
        assertInvalid (moduleWith (monomorphic a) (expr 1 a Fail)),
      testCase "quantifier kinds agree with their occurrences" $ do
        let q = Quantifier (BoundId 0) "f" (KindArrow TypeKind TypeKind)
            wrongKind = Variable (BoundVariable (BoundId 0)) TypeKind
        assertInvalid (moduleWith (Scheme [] [q] [] wrongKind) (expr 1 wrongKind Fail)),
      testCase "constructor applications must be saturated" $ do
        let bad = expr 1 (list int) (Construct (DataConstructor (IntrinsicId ConsConstructor)) [int] [expr 2 int (Literal (L.IntegerLiteral "1"))])
        assertInvalid (moduleWith (monomorphic (list int)) bad),
      testCase "primitive operands have fixed types" $ do
        let bad = expr 1 int (Primitive IntNegate [expr 2 bool (Construct (DataConstructor (IntrinsicId TrueConstructor)) [] [])])
        assertInvalid (moduleWith (monomorphic int) bad),
      testCase "generated nodes must retain their origin span" $ do
        let wrong = origin {start = Position 1 1 0}
            body = (expr 1 int (Literal (L.IntegerLiteral "1"))) {nodeOrigin = GeneratedOrigin "test" wrong}
        assertInvalid (moduleWith (monomorphic int) body),
      testCase "unprotected recursive reads fail" $ do
        let binding = node 0 (Binding global (monomorphic int) (expr 1 int (Var global [])) (BindingFacts 0 Nothing))
            tree = (moduleWith (monomorphic int) (expr 2 int Fail)) {coreBindings = [Recursive (binding :| [])]}
        assertInvalid tree,
      testCase "evidence lambdas cannot protect source recursive reads" $ do
        let ty = function int int
            body = expr 1 ty (Lambda (node 2 (LocalId 0, "dict", EvidenceBinder, int)) (expr 3 int (Apply (expr 4 ty (Var global [])) (expr 5 int (Literal (L.IntegerLiteral "1"))))))
            binding = node 0 (Binding global (monomorphic ty) body (BindingFacts 0 Nothing))
            tree = (moduleWith (monomorphic ty) body) {coreBindings = [Recursive (binding :| [])]}
        assertInvalid tree,
      testCase "typed holes are structurally valid and prevent acceptance" $ do
        let hole = HoleId 0
            tree = (moduleWith (monomorphic int) (expr 1 int (Hole hole))) {coreGoals = Map.singleton hole (node 2 (HoleGoal hole int [] []))}
        validateCore tree @?= []
        case acceptCore tree of
          Right _ -> assertFailure "a fully typed hole was accepted"
          Left errors -> do
            map E.diagnosticCode errors @?= [E.ExpressionHole]
            map E.diagnosticSpan errors @?= [origin],
      testCase "hole scan includes unused bindings, lambdas and unselected arms" $ do
        let hole = expr 9 int (Hole (HoleId 0))
            bound = node 3 (Binding (LocalRef (LocalId 0)) (monomorphic (function int int)) (expr 4 (function int int) (Lambda (node 5 (LocalId 1, "x", ValueBinder, int)) hole)) (BindingFacts 0 Nothing))
            body = expr 1 int (If [node 2 (expr 6 bool (Construct (DataConstructor (IntrinsicId FalseConstructor)) [] []), expr 7 int (Let bound (expr 8 int (Literal (L.IntegerLiteral "0")))))] (Just (expr 10 int (Literal (L.IntegerLiteral "1")))))
        map nodeValue (expressionHoles body) @?= [(HoleId 0, int)],
      testCase "traversal converts every embedded type and preserves hole identities" $ do
        let binder = node 2 (LocalId 0, "x", ValueBinder, int)
            body = expr 1 (function int int) (Lambda binder (expr 3 int (Hole (HoleId 4))))
            converted = fmap (fmap replaceInt) body
            replaceInt ty
              | ty == int = bool
            replaceInt (Application f x) = Application (replaceInt f) (replaceInt x)
            replaceInt ty = ty
        map nodeValue (expressionHoles converted) @?= [(HoleId 4, bool)]
        typeOf converted @?= function bool bool
        nodeId converted @?= NodeId 1
    ]
