module Ficus.Infer.CheckSpec (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Error.Diagnostic qualified as D
import Ficus.Error.Type qualified as E
import Ficus.Infer.Check
import Ficus.Infer.Declaration
import Ficus.Infer.Monad
import Ficus.Infer.Type
import Ficus.Resolve
import Ficus.Resolve.Provider
import Ficus.Resolve.Support
import Ficus.Syntax.Abstract.Validate
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Name
import Ficus.Type
import Ficus.Type.Substitution qualified as S
import Ficus.Util.Source
import Test.Tasty
import Test.Tasty.HUnit

check :: Text -> (Inference -> Assertion) -> Assertion
check source assertion = do
  let owner = ModuleId ("Inference" :| [])
  result <- resolveSources fixtureConfig fixtureSugar (\_ -> pure (Right (Source "Inference.ficus" ("{-# NO_IMPLICIT_PRELUDE #-}\n" <> source)))) [owner]
  assertBool (show (frontendDiagnostics result)) (all ((/= D.Error) . D.diagnosticSeverity . D.toDiagnostic) (frontendDiagnostics result))
  case Map.lookup owner (frontendModules result) of
    Nothing -> assertFailure "fixture did not resolve"
    Just tree -> do
      validateAbstract tree @?= Right ()
      assertion (inferModule emptyDeclarations tree)

errors :: Inference -> [E.Diagnostic]
errors = filter ((== D.Error) . D.diagnosticSeverity . D.toDiagnostic) . diagnostics . inferenceState

assertType :: Inference -> Text -> Text -> Assertion
assertType result name expected = case Map.lookup (GlobalRef (GlobalId (ModuleId ("Inference" :| [])) ValueNS name)) (inferredValues result) of
  Nothing -> assertFailure ("missing inferred binding " ++ T.unpack name)
  Just scheme -> do
    let names = Map.fromList (zip (map quantifierId (quantifiers scheme)) (map T.singleton ['a' .. 'z']))
        variable (Bound ident) = Map.findWithDefault (renderBound ident) ident names
        variable other = T.pack (show other)
    renderType variable (schemeType scheme) @?= expected

positive :: Text -> [(Text, Text)] -> Assertion
positive source expectations = check source $ \result -> do
  errors result @?= []
  remainingWanteds result @?= []
  mapM_ (uncurry (assertType result)) expectations

negative :: Text -> E.TypeCode -> (Int, Int, Int) -> Assertion
negative source code coordinates = check source $ \result -> do
  let matching = [d | d <- errors result, E.diagnosticCode d == code]
  assertBool (show (errors result)) (not (null matching))
  assertBool (show matching) (any (\d -> let s = E.diagnosticSpan d in (line (start s), column (start s), column (end s)) == coordinates) matching)

tests :: TestTree
tests =
  testGroup
    "source type inference"
    [ testCase "non-expansive identity is independently instantiated" $
        positive "identity x = x\ncheck () = (identity 1, identity True)\n" [("identity", "a -> a"), ("check", "Unit -> Int * Bool")],
      testCase "hole goals retain pending nominal field constraints" $
        check "check () = _.field\n" $ \result -> do
          let goals = Map.elems (checkedGoals (inferenceState result))
          case goals of
            [goal] -> case C.goalBlockers (C.nodeValue goal) of
              [blocker] -> do
                fst (C.nodeValue blocker) @?= "field field"
                let origin = C.nodeSpan blocker
                (line (start origin), column (start origin), column (end origin)) @?= (2, 14, 18)
              _ -> assertFailure "missing pending field in hole goal"
            _ -> assertFailure "missing hole goal",
      testCase "local functions generalize outside their environment" $
        positive "check () = { identity x = x; (identity 1, identity True) }\n" [("check", "Unit -> Int * Bool")],
      testCase "a signature may specialize identity" $
        positive "identity : Int -> Int\nidentity x = x\n" [("identity", "Int -> Int")],
      testCase "a signature may not overstate generality" $
        negative "bad : a -> a\nbad x = 1\n" E.TypeMismatch (3, 9, 9),
      testCase "lambda parameters are monomorphic" $
        negative "bad f = (f 1, f True)\n" E.TypeMismatch (2, 17, 20),
      testCase "application performs an occurs check" $
        negative "bad x = x x\n" E.InfiniteType (2, 9, 11),
      testCase "conditionals require Boolean tests" $
        negative "bad () = if { 1 -> 0; _ -> 1 }\n" E.TypeMismatch (2, 15, 15),
      testCase "conditional branches share one result type" $
        negative "bad () = if { True -> 1; _ -> False }\n" E.TypeMismatch (2, 31, 35),
      testCase "list elements have one type" $
        negative "bad () = [1, True]\n" E.TypeMismatch (2, 14, 17),
      testCase "constructor patterns infer their field types" $
        positive "type Box a = Box a\nunbox (Box x) = x\nboxed = Box (x -> x)\n" [("unbox", "Box a -> a"), ("boxed", "Box (a -> a)")],
      testCase "safe mutual recursion shares its inferred monotypes" $
        positive "ping x = pong x\npong x = if { x -> ping False; _ -> 1 }\n" [("ping", "Bool -> Int"), ("pong", "Bool -> Int")],
      testCase "complete signatures permit polymorphic recursion" $
        positive "loop : [a] -> Int\nloop xs = loop [xs]\n" [("loop", "[a] -> Int")],
      testCase "unsigned recursion cannot change its argument type" $
        negative "loop xs = loop [xs]\n" E.InfiniteType (2, 16, 19),
      testCase "local application results remain monomorphic" $
        negative "check () = { id x = x; local = id id; (local 1, local True) }\n" E.TypeMismatch (2, 55, 58),
      testCase "later uses can solve a weak local type" $
        positive "check () = { id x = x; local = id id; local 1 }\n" [("check", "Unit -> Int")],
      testCase "unused weak local types are rejected" $
        negative "check () = { id x = x; unused = id id; 1 }\n" E.UnresolvedWeakType (2, 24, 29),
      testCase "signature holes complete from the body" $
        positive "keep : Int -> _\nkeep x = x\n" [("keep", "Int -> Int")],
      testCase "unsigned explicit binders preserve their written order" $
        check "choose @b @a (x : b) (y : a) = x\ncheck () = choose @Int @Bool 1 True\n" $ \result -> do
          errors result @?= []
          assertType result "choose" "a -> b -> a"
          assertType result "check" "Unit -> Int"
          let schemes = Map.elems (inferredValues result)
          map (map quantifierName . explicitQuantifiers) (filter (not . null . explicitQuantifiers) schemes) @?= [["b", "a"]],
      testCase "unsigned explicit type binders are rigid" $
        negative "bad @a (x : a) = (1 : a)\n" E.InvalidAnnotation (2, 18, 24),
      testCase "type lambda binders supply the binding's explicit quantifiers" $
        positive "duplicate = @a (x : a) -> (x, x)\ncheck () = duplicate @Int 1\n" [("duplicate", "a -> a * a"), ("check", "Unit -> Int * Int")],
      testCase "checking a local signature cannot capture an outer monotype" $
        negative "bad x = { value : a; value = x; value }\n" E.InvalidAnnotation (2, 19, 19),
      testCase "nominal record projection and updates preserve types" $
        positive "type Point = { x : Int; y : Int }\npoint = Point with { y = 2; x = 1 }\nchange () = point with { x = 3 }\nget () = point.x\n" [("point", "Point"), ("change", "Unit -> Point"), ("get", "Unit -> Int")],
      testCase "receiver uses can resolve a pending inner projection" $
        positive "type Box a = { value : a }\nget p = field where { field = p.value }\ncheck () = get (Box 1)\n" [("get", "Box Int -> Int"), ("check", "Unit -> Int")],
      testCase "qualified functions instantiate visible implementation evidence" $
        positive "trait Show a = { show : a -> String }\nimpl Show Int = { show x = \"integer\" }\nimpl Show Bool = { show x = \"boolean\" }\ndisplay x = show x\ncheck () = (display 1, display True)\n" [("display", "a -> String"), ("check", "Unit -> String * String")],
      testCase "supertrait givens discharge method requirements" $
        positive "trait Equal a = { equal : a -> a -> Bool }\ntrait Equal a => Ordered a = {}\nsame : Ordered a => a -> a -> Bool\nsame x y = equal x y\n" [("same", "a -> a -> Bool")],
      testCase "mutually recursive functions share their constraints" $
        check "trait Show a = { show : a -> String }\nfirst x = second x\nsecond x = if { True -> show x; _ -> first x }\n" $ \result -> do
          errors result @?= []
          let constraints name = fmap (length . schemePredicates) (Map.lookup (GlobalRef (GlobalId (ModuleId ("Inference" :| [])) ValueNS name)) (inferredValues result))
          constraints "first" @?= Just 1
          constraints "second" @?= Just 1,
      testCase "unsigned members of a signed recursive group close their types" $
        positive "first : a -> Int\nfirst x = second x\nsecond x = first x\n" [("first", "a -> Int"), ("second", "a -> Int")],
      testCase "multiple uses retain one generalized predicate" $
        check "trait Show a = { show : a -> String }\ndisplay x = (show x, show x)\n" $ \result -> do
          errors result @?= []
          fmap (length . schemePredicates) (Map.lookup (GlobalRef (GlobalId (ModuleId ("Inference" :| [])) ValueNS "display")) (inferredValues result)) @?= Just 1,
      testCase "implementation members satisfy their method signatures" $
        negative "trait Show a = { show : a -> String }\nimpl Show Int = { show x = 1 }\n" E.TypeMismatch (3, 28, 28),
      testCase "missing ground implementation is an error" $
        negative "trait Show a = { show : a -> String }\ncheck () = show 1\n" E.UnsatisfiedConstraint (3, 12, 17),
      testCase "unsigned constrained aliases remain monomorphic" $
        negative "trait Show a = { show : a -> String }\ndisplay = show\ncheck () = (display 1, display True)\n" E.TypeMismatch (4, 32, 35),
      testCase "holes retain types and lexical binder context after solving" $
        check "missing : Int -> Int\nmissing x = _\n" $ \result -> do
          map E.diagnosticCode (errors result) @?= [E.ExpressionHole]
          let state = inferenceState result
              goals = Map.elems (checkedGoals state)
              zonked = S.apply (substitution state)
          map (renderInferType . zonked . C.goalType . C.nodeValue) goals @?= ["Int"]
          map (map (\entry -> let (name, scheme) = C.nodeValue entry in (name, renderInferType (zonked (schemeType scheme)))) . C.goalContext . C.nodeValue) goals @?= [[("x", "Int")]],
      testCase "nested Boolean product patterns establish exhaustiveness" $
        check "choose (True, _) = 1\nchoose (False, True) = 2\nchoose (False, False) = 3\n" $
          \result -> diagnostics (inferenceState result) @?= [],
      testCase "a missing constructor produces a coverage warning" $
        check "choose True = 1\n" $ \result -> do
          errors result @?= []
          map E.diagnosticCode (diagnostics (inferenceState result)) @?= [E.NonExhaustiveMatch]
          map (line . start . E.diagnosticSpan) (diagnostics (inferenceState result)) @?= [2],
      testCase "an earlier wildcard makes a later clause redundant" $
        check "choose _ = 1\nchoose True = 2\n" $ \result -> do
          errors result @?= []
          map E.diagnosticCode (diagnostics (inferenceState result)) @?= [E.RedundantClause]
          map (line . start . E.diagnosticSpan) (diagnostics (inferenceState result)) @?= [3],
      testCase "guarded clauses do not establish coverage" $
        check "choose x = with x { _ if False -> 1 }\n" $ \result -> do
          errors result @?= []
          map E.diagnosticCode (diagnostics (inferenceState result)) @?= [E.NonExhaustiveMatch],
      testCase "hole contexts retain an unused earlier local's source name" $
        check "missing () = { earlier = 1; _ }\n" $ \result -> do
          map E.diagnosticCode (errors result) @?= [E.ExpressionHole]
          map (map (fst . C.nodeValue) . C.goalContext . C.nodeValue) (Map.elems (checkedGoals (inferenceState result))) @?= [["earlier"]],
      testCase "negation can be specialized by a later use" $
        positive "negative x = -x\ncheck () = negative 1\n" [("negative", "Int -> Int"), ("check", "Unit -> Int")]
    ]
