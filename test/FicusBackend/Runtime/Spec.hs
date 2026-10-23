module FicusBackend.Runtime.Spec (tests) where

import Control.Monad (foldM, forM_)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Ficus.CompilationConfig
import Ficus.Elaborate qualified as Elab
import Ficus.Error.Diagnostic qualified as D
import Ficus.Library.Contracts
import Ficus.Primitive.Registry qualified as P
import Ficus.Resolve
import Ficus.Resolve.Discovery
import Ficus.Resolve.Header (edgeTarget, headerEdges)
import Ficus.Resolve.Provider
import Ficus.Resolve.Support
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Core.Validate (validatedModule)
import Ficus.Syntax.Name qualified as N
import Ficus.Type qualified as Type
import Ficus.Util.Source
import FicusBackend.Error qualified as B
import FicusBackend.Lower.Runtime
import FicusBackend.Runtime qualified as Runtime
import FicusBackend.Runtime.AST qualified as R
import FicusBackend.Runtime.Direct
import FicusBackend.Runtime.Error qualified as E
import FicusBackend.Runtime.Primitive qualified as Primitive
import FicusBackend.Runtime.Value
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck qualified as QC

origin :: Span
origin = Span "Runtime.ficus" (Position 1 1 0) (Position 1 5 4)

node :: a -> R.Node a
node = R.Node

literal :: R.RuntimeLiteral -> R.Expr
literal = node . R.Literal

primitive :: R.Primitive () -> [R.Expr] -> R.Expr
-- A missing catalogue entry produces an invalid address, rejected by validation.
primitive operation arguments = node (R.Primitive (R.PrimitiveIndex (maybe (-1) id (P.primitiveIndex operation))) arguments "")

program :: R.Expr -> R.Program
program body =
  R.Program
    V.empty
    1
    (V.fromList [node (R.ConstructorLayout (R.FrameSize count)) | count <- [0, 2, 2, 0, 0, 0, 1, 2, 0]])
    Map.empty
    testErrors
    Nothing
    (V.fromList P.allPrimitives)
    [node (R.GlobalGroup False ((R.GlobalIndex 0, node (R.Binding body False)) :| []))]

testErrors :: Map.Map P.PrimitiveError R.ErrorConstructor
testErrors = Map.fromList [(P.DivisionByZeroError, R.ErrorConstructor (R.ConstructorIndex 3) (Just (R.ConstructorIndex 5)) Nothing), (P.InvalidConversionError, R.ErrorConstructor (R.ConstructorIndex 3) (Just (R.ConstructorIndex 6)) Nothing), (P.IOError, R.ErrorConstructor (R.ConstructorIndex 4) (Just (R.ConstructorIndex 7)) Nothing), (P.MatchError, R.ErrorConstructor (R.ConstructorIndex 8) Nothing Nothing)]

evaluatePrimitive :: Text -> Effects -> R.Primitive () -> [Value] -> EvalM Value
evaluatePrimitive = Primitive.evaluatePrimitive testErrors Map.empty Nothing (\_ -> invalidValue "no fixture evidence globals")

errorDeclarations :: Text
errorDeclarations = "\n{-# BUILTIN ARITHMETIC_ERROR ArithmeticError #-}\ntype ArithmeticError = { DivisionByZero; InvalidConversion String }\n{-# BUILTIN DIVISION_BY_ZERO DivisionByZero #-}\n{-# BUILTIN INVALID_CONVERSION InvalidConversion #-}\n{-# BUILTIN IO_ERROR IOError #-}\ntype IOError = IOError String String\n{-# BUILTIN IO_FAILURE IOError #-}\n"

matchDeclarations :: Text
matchDeclarations = "\n{-# BUILTIN MATCH_ERROR MatchError #-}\ntype MatchError = MatchError String\n{-# BUILTIN MATCH_FAILURE MatchError #-}\n"

quiet :: Effects
quiet = Effects (\_ _ -> pure ()) (\_ _ -> pure "")

capture :: (Effects -> IO (Either E.RuntimeError Value)) -> IO (Either E.RuntimeError Observation, [Text])
capture = captureInput "input"

captureInput :: Text -> (Effects -> IO (Either E.RuntimeError Value)) -> IO (Either E.RuntimeError Observation, [Text])
captureInput input action = do
  output <- newIORef []
  remaining <- newIORef input
  let readChunk _ count = atomicModifyIORef' remaining $ \text ->
        let size = fromIntegral (min count (fromIntegral (T.length text)))
            (chunk, rest) = T.splitAt size text
         in (rest, chunk)
  result <- action (Effects (\_ text -> modifyIORef' output (<> [text])) readChunk)
  trace <- readIORef output
  pure (fmap observe result, trace)

execute :: Runtime.ValidatedProgram -> R.GlobalIndex -> [Value] -> Effects -> IO (Either E.RuntimeError Value)
execute checked ident arguments effects = case Runtime.selectEntry checked ident of
  Left problem -> pure (Left (E.RuntimeError (B.errorMessage problem)))
  Right entry -> Runtime.runProgram effects (Runtime.compileProgram checked) entry arguments

compareEvaluators :: Runtime.ValidatedProgram -> R.GlobalIndex -> [Value] -> IO (Either E.RuntimeError Observation, [Text])
compareEvaluators = compareEvaluatorsWithInput "input"

compareEvaluatorsWithInput :: Text -> Runtime.ValidatedProgram -> R.GlobalIndex -> [Value] -> IO (Either E.RuntimeError Observation, [Text])
compareEvaluatorsWithInput input checked ident arguments = do
  compiled <- captureInput input (execute checked ident arguments)
  direct <- captureInput input (\effects -> runDirect effects checked ident arguments)
  compiled @?= direct
  pure compiled

checkedSource :: Text -> IO LoweredProgram
checkedSource source = do
  let owner = N.ModuleId ("Runtime" :| [])
  resolved <- resolveSources fixtureConfig fixtureSugar (\_ -> pure (Right (Source "Runtime.ficus" ("{-# NO_IMPLICIT_PRELUDE #-}\n" <> source <> if any (`T.isInfixOf` source) ["BUILTIN INT_DIV", "BUILTIN INT_REM", "BUILTIN FLOAT_TO_INT", "BUILTIN HANDLE_READ", "BUILTIN HANDLE_WRITE"] then errorDeclarations <> matchDeclarations else matchDeclarations)))) [owner]
  assertBool (show (frontendDiagnostics resolved)) (all ((/= D.Error) . D.diagnosticSeverity . D.toDiagnostic) (frontendDiagnostics resolved))
  case Map.lookup owner (frontendModules resolved) of
    Nothing -> assertFailure "source did not resolve" >> fail "source did not resolve"
    Just tree -> case Elab.elaborateModule [] tree of
      Elab.Incomplete _ errors -> assertFailure (show errors) >> fail "source did not elaborate"
      Elab.Complete checked _ -> case lowerProgram [validatedModule (Elab.checkedCore checked)] of
        Left errors -> assertFailure (show errors) >> fail "Core did not lower"
        Right lowered -> pure lowered

sourceResult :: Text -> IO (Either E.RuntimeError Observation, [Text])
sourceResult source = do
  lowered <- checkedSource source
  let ident = N.GlobalId (N.ModuleId ("Runtime" :| [])) N.ValueNS "check"
  case Map.lookup ident (loweredGlobals lowered) of
    Nothing -> assertFailure "check was not linked" >> fail "check was not linked"
    Just global -> compareEvaluators (loweredProgram lowered) global [LiteralValue R.Unit]

expectSource :: Text -> Observation -> [Text] -> Assertion
expectSource source expected trace = sourceResult source >>= (@?= (Right expected, trace))

int :: Int64 -> Observation
int = LiteralObservation . R.Integer

printing :: Text
printing = "{-# BUILTIN HANDLE Handle #-}\nHandle : Type\n{-# BUILTIN HANDLE_STDOUT stdout #-}\nstdout : Handle\n{-# BUILTIN HANDLE_WRITE write #-}\nwrite : Handle -> String -> Unit\nprint text = write stdout text\n"

arithmetic :: Text
arithmetic = "{-# BUILTIN INT_ADD add #-}\nadd : Int -> Int -> Int\n{-# BUILTIN INT_SUB sub #-}\nsub : Int -> Int -> Int\n{-# BUILTIN INT_EQ equal #-}\nequal : Int -> Int -> Bool\n"

tests :: TestTree
tests =
  testGroup
    "runtime"
    [ testGroup
        "source lowering"
        [ testCase "empty matches evaluate their scrutinee once before failing" $ do
            (result, trace) <- sourceResult (printing <> "check () = with (print \"scrutinee\") {}\n")
            trace @?= ["scrutinee"]
            assertBool "empty match must fail" (case result of Left _ -> True; Right _ -> False),
          testCase "empty types and polymorphic eliminators lower without constructors" $
            expectSource "type Empty = {}\nabsurd : Empty -> a\nabsurd x = with x {}\ncheck () = 42\n" (int 42) [],
          testCase "standalone initialization preserves dependency and source order" $
            expectSource ("{-# STANDALONE #-}\n" <> printing <> "second = { print \"second\"; first }\nfirst = { print \"first\"; 1 }\ncheck () = second\n") (int 1) ["first", "second"],
          testCase "captures survive nested frames and shadowing" $
            expectSource (arithmetic <> "make x = y -> { x = add x 1; z -> add (add x y) z }\ncheck () = { saved = make 10 2; saved 3 }\n") (int 16) [],
          testCase "partial and extra application preserve function results" $
            expectSource (arithmetic <> "combine x y = z -> add (add x y) z\ncheck () = { partial = combine 1; partial 2 3 }\n") (int 6) [],
          testCase "straight parameter aliases permit arity raising" $ do
            lowered <- checkedSource "choose x y = x\ncheck () = choose 1 True\n"
            let functions = R.programFunctions (Runtime.validatedProgram (loweredProgram lowered))
            assertBool "a pure two-argument chain was raised" (any ((== R.Arity 2) . R.functionArity . R.nodeValue) functions),
          testCase "function before arguments, with application between operands" $
            expectSource (printing <> "make () = { print \"function\"; x -> { print \"apply\"; y -> x } }\nargument label value = { print label; value }\ncheck () = make () (argument \"first\" 7) (argument \"second\" True)\n") (int 7) ["function", "first", "apply", "second"],
          testCase "where after the first written parameter precedes returned lambda" $
            expectSource (printing <> "f x = y -> x where { _ = print \"where\" }\ncheck () = { partial = f 7; print \"between\"; partial True }\n") (int 7) ["where", "between"],
          testCase "where after both written parameters waits for saturation" $
            expectSource (printing <> "f x y = x where { _ = print \"where\" }\ncheck () = { partial = f 7; print \"between\"; partial True }\n") (int 7) ["between", "where"],
          testCase "failed first parameter prevents evaluating the next argument" $ do
            let source = printing <> "f True y = y\nlater () = { print \"later\"; 1 }\ncheck () = f False (later ())\n"
            (result, trace) <- sourceResult source
            trace @?= []
            result @?= Left (matchError (fixtureSpan source "f True y = y")),
          testCase "recursive local closures capture shared cells" $
            expectSource (arithmetic <> "check () = ping 8 where { ping n = if { equal n 0 -> 1; _ -> pong (sub n 1) }; pong n = if { equal n 0 -> 2; _ -> ping (sub n 1) } }\n") (int 1) [],
          testCase "recursive aggregates containing closures initialize strictly" $
            expectSource (arithmetic <> "type Loop = Loop (Int -> Int) Int\nloop = Loop (n -> if { equal n 0 -> 9; _ -> with loop { Loop again marker -> again (sub n 1) } }) 0\ncheck () = with loop { Loop run marker -> run 5 }\n") (int 9) [],
          testCase "polymorphic pattern binding evaluates and matches once" $
            expectSource "check () = { (identity, other) = (x -> x, y -> y); if { identity True -> other 4; _ -> identity 8 } }\n" (int 4) [],
          testCase "single-field constructor and record wrappers erase" $ do
            lowered <- checkedSource "type Box a = Box a\ntype Record a = { value : a }\ncheck () = with Box (Record with { value = 8 }) { Box record -> record.value }\n"
            V.length (R.programConstructors (Runtime.validatedProgram (loweredProgram lowered))) @?= 4
            expectSource "type Box a = Box a\ntype Record a = { value : a }\ncheck () = with Box (Record with { value = 8 }) { Box record -> record.value }\n" (int 8) [],
          testCase "wrapper matching preserves strict field evaluation" $
            expectSource (printing <> "type Box a = Box a\nfield () = { print \"field\"; 3 }\ncheck () = with Box (field ()) { Box x -> x }\n") (int 3) ["field"],
          testCase "record updates evaluate receiver once and replacements in source order" $
            expectSource (printing <> arithmetic <> "type Pair = { first : Int; second : Int }\nvalue label number = { print label; number }\nreceiver () = { print \"receiver\"; Pair 1 2 }\ncheck () = { changed = (receiver ()) with { second = value \"second\" 4; first = value \"first\" 3 }; add changed.first changed.second }\n") (int 7) ["receiver", "second", "first"],
          testCase "dictionary methods retain method-local polymorphism" $
            expectSource "trait Pick a = { pick : a -> b -> b }\nimpl Pick Int = { pick ignored value = value }\ncheck () = if { pick 1 True -> pick 2 7; _ -> 0 }\n" (int 7) [],
          testCase "superclass selection uses the superclass field offset" $
            expectSource "trait Same a = { same : a -> a -> Bool }\ntrait Same a => Pick a = { pick : a -> a }\nimpl Same Int = { same x y = True }\nimpl Pick Int = { pick x = x }\nchoose : Pick a => a -> a -> Bool\nchoose x y = same (pick x) y\ncheck () = if { choose 1 2 -> 7; _ -> 0 }\n" (int 7) [],
          testCase "only selected conditional branches execute" $
            expectSource (printing <> "check () = if { False -> { print \"wrong\"; 0 }; True -> { print \"right\"; 1 }; _ -> { print \"wrong\"; 2 } }\n") (int 1) ["right"],
          testCase "dictionary-dependent initialization precedes the value argument" $ do
            let source = printing <> "type Maybe a = { Nothing; Just a }\ntrait Get a = { get : Maybe a }\nimpl Get Int = { get = Nothing }\nchoose : Get a => a -> a\nchoose = x -> y where { Just y = get }\nargument () = { print \"argument\"; 1 }\ncheck () = choose (argument ())\n"
            (result, trace) <- sourceResult source
            trace @?= []
            result @?= Left (matchError (fixtureSpan source "Just y")),
          testCase "where dependency order breaks independent ties by source order" $
            expectSource (printing <> "value label result = { print label; result }\ncheck () = last where { first = value \"first\" base; independent = value \"independent\" 2; base = value \"base\" 1; last = value \"last\" first }\n") (int 1) ["independent", "base", "first", "last"],
          testCase "recursive local aggregates retain shared closure cells" $
            expectSource (arithmetic <> "type Loop = Loop (Int -> Int) Int\ncheck () = with loop { Loop run marker -> run 3 } where { loop = Loop (n -> if { equal n 0 -> 9; _ -> with loop { Loop again marker -> again (sub n 1) } }) 0 }\n") (int 9) [],
          testCase "library imports, recursive lists and trait dictionaries execute" $ do
            lowered <- checkedLibrary "check () = foldl (+) 0 (map (x -> x * 2) [1, 2, 3])\n"
            case Map.lookup (N.GlobalId (N.ModuleId ("Runtime" :| [])) N.ValueNS "check") (loweredGlobals lowered) of
              Nothing -> assertFailure "missing library entry"
              Just ident -> compareEvaluators (loweredProgram lowered) ident [LiteralValue R.Unit] >>= (@?= (Right (int 12), [])),
          testCase "derived print, println and readLine use handle primitives" $
            libraryResult "input" "check () = { print \"first\"; println \"second\"; readLine () }\n" >>= (@?= (Right (LiteralObservation (R.String "input")), ["first", "second\n"])),
          testCase "derived line reading preserves Unicode, EOF, and CRLF boundaries" $
            forM_ [("a😀\r\nb\nlast", "a😀|b|last|"), ("", "|||"), ("x\r", "x\r|||")] $ \(input, expected) ->
              libraryResult input "check () = { a = readLine (); b = readLine (); c = readLine (); d = readLine (); a ++ \"|\" ++ b ++ \"|\" ++ c ++ \"|\" ++ d }\n" >>= (@?= (Right (LiteralObservation (R.String expected)), [])),
          testCase "composition and sequencing operators preserve order and skipped thunks" $
            libraryResult "" "step label value = { print label; value }\ncheck () = { f = (x -> step \"f\" (x + 1)); g = (x -> step \"g\" (x * 2)); a = (f << g) 3; b = (g >> f) 3; left = Just a <* (_ -> step \"left\" (Just True)); right = Just b *> (_ -> step \"right\" (Just 9)); skipped : Maybe Int; skipped = Nothing *> (_ -> step \"wrong\" (Just 0)); show (left, right, skipped) }\n" >>= (@?= (Right (LiteralObservation (R.String "(Just (7), (Just (9), Nothing))")), ["g", "f", "g", "f", "left", "right"])),
          testCase "library vectors, bytes, do and interpolation execute" $ do
            lowered <- checkedLibrary "use Data.Vec (vecLength, listToVec)\nuse Data.Byte (byteToInt, intToByte)\ncheck () = { byte = byteToInt (intToByte (-1)); count = vecLength (listToVec [1, 2, 3]); result = do { x <- Just byte; Just (x + count) }; with result { Just total -> \"total={total}\"; Nothing -> \"missing\" } }\n"
            case Map.lookup (N.GlobalId (N.ModuleId ("Runtime" :| [])) N.ValueNS "check") (loweredGlobals lowered) of
              Nothing -> assertFailure "missing library entry"
              Just ident -> compareEvaluators (loweredProgram lowered) ident [LiteralValue R.Unit] >>= (@?= (Right (LiteralObservation (R.String "total=258")), []))
        ],
      testGroup
        "execution API"
        [ testCase "internal runtime failures remain separate" $ do
            result <- runEvaluation (raiseRuntime "internal failure" :: EvalM Value)
            fmap observe result @?= Left (E.RuntimeError "internal failure"),
          testCase "typed match-failure operations preserve their context" $ do
            let tree = program (primitive R.MatchFailure [literal (R.String "custom runtime failure")])
            case Runtime.validateProgram tree of
              Left errors -> assertFailure (show errors)
              Right checked -> compareEvaluators checked (R.GlobalIndex 0) [] >>= (@?= (Left (E.RuntimeError "custom runtime failure: uncaught exception"), []))
            D.diagnosticCode (D.toDiagnostic (E.RuntimeError "custom runtime failure")) @?= "R0001",
          testCase "primitive argument errors keep their own messages" $ do
            let tree = program (node (R.Primitive (R.PrimitiveIndex (maybe (-1) id (P.primitiveIndex R.IntDivide))) [primitive R.MatchFailure [literal (R.String "argument failure")], literal (R.Integer 0)] "primitive site: "))
            case Runtime.validateProgram tree of
              Left errors -> assertFailure (show errors)
              Right checked -> compareEvaluators checked (R.GlobalIndex 0) [] >>= (@?= (Left (E.RuntimeError "argument failure: uncaught exception"), [])),
          testCase "an instance initializes globals once across repeated entry calls" $ do
            case Runtime.validateProgram (program (termExpr (Trace "init" (Number 7)))) of
              Left errors -> assertFailure (show errors)
              Right checked -> case Runtime.selectEntry checked (R.GlobalIndex 0) of
                Left problem -> assertFailure (show problem)
                Right entry -> do
                  result <- capture $ \effects ->
                    Runtime.initialize effects (Runtime.compileProgram checked) >>= \case
                      Left problem -> pure (Left problem)
                      Right instance' -> do
                        first <- Runtime.evaluateEntry instance' entry []
                        fmap observe first @?= Right (int 7)
                        Runtime.evaluateEntry instance' entry []
                  result @?= (Right (int 7), ["init"]),
          testCase "generic multi-operand calls apply between argument evaluations" $ do
            let traced label body = node (R.Let (node (R.Binding (primitive (R.HandleWrite ()) [primitive (R.HandleStdout ()) [], literal (R.String label)]) False)) body)
                function body = node (R.Function (R.Arity 1) (R.FrameSize 1) (R.CaptureLayout 0) (V.singleton R.ValueParameter) body)
                call = node (R.Call (traced "function" (node (R.Closure (R.FunctionIndex 0) []))) (traced "first" (literal R.Unit) :| [traced "second" (literal (R.Integer 9))]))
                tree = (program call) {R.programFunctions = V.fromList [function (traced "apply" (node (R.Closure (R.FunctionIndex 1) []))), function (node (R.Load (R.Local (R.FrameDepth 0) (R.SlotIndex 0))))]}
            case Runtime.validateProgram tree of
              Left errors -> assertFailure (show errors)
              Right checked -> compareEvaluators checked (R.GlobalIndex 0) [] >>= (@?= (Right (int 9), ["function", "first", "apply", "second"]))
        ],
      testGroup
        "validation"
        [ invalid "negative global count" ((program (literal R.Unit)) {R.programGlobalCount = -1}),
          invalid "exception token identity" (program (node (R.TypeToken (R.ConstructorIndex 999) []))),
          invalid "exception token arity" (program (node (R.TypeToken R.nilConstructor [literal R.Unit]))),
          invalid "global ID" (program (node (R.Global (R.GlobalIndex 9)))),
          invalid "local frame" (program (node (R.Load (R.Local (R.FrameDepth 0) (R.SlotIndex 0))))),
          invalid "capture index" (program (node (R.Load (R.Capture (R.CaptureIndex 0))))),
          invalid "constructor arity" (program (node (R.Construct R.consConstructor []))),
          invalid "primitive arity" (program (primitive R.IntAdd [literal (R.Integer 1)])),
          invalid "unprotected recursive global" ((program (node (R.Global (R.GlobalIndex 0)))) {R.programInitialization = [node (R.GlobalGroup True ((R.GlobalIndex 0, node (R.Binding (node (R.Global (R.GlobalIndex 0))) False)) :| []))]}),
          invalid "unprotected recursive local" (program (node (R.LetRec (node (R.Binding (node (R.Load (R.Local (R.FrameDepth 0) (R.SlotIndex 0)))) False) :| []) (literal R.Unit)))),
          invalid "capture layout" ((program (node (R.Closure (R.FunctionIndex 0) []))) {R.programFunctions = V.singleton (node (R.Function (R.Arity 1) (R.FrameSize 1) (R.CaptureLayout 1) (V.singleton R.ValueParameter) (literal R.Unit)))}),
          invalid "function frame size" ((program (literal R.Unit)) {R.programFunctions = V.singleton (node (R.Function (R.Arity 1) (R.FrameSize 0) (R.CaptureLayout 0) (V.singleton R.ValueParameter) (literal R.Unit)))}),
          invalid
            "evidence is not recursive protection"
            ( (program (literal R.Unit))
                { R.programFunctions = V.singleton (node (R.Function (R.Arity 1) (R.FrameSize 1) (R.CaptureLayout 0) (V.singleton R.EvidenceParameter) (node (R.Global (R.GlobalIndex 0))))),
                  R.programInitialization = [node (R.GlobalGroup True ((R.GlobalIndex 0, node (R.Binding (node (R.Closure (R.FunctionIndex 0) [])) False)) :| []))]
                }
            ),
          invalid "expansive recursive initializer" ((program (literal R.Unit)) {R.programInitialization = [node (R.GlobalGroup True ((R.GlobalIndex 0, node (R.Binding (literal R.Unit) True)) :| []))]}),
          invalid "constructor case frame" (program (node (R.Case (node (R.Construct R.nilConstructor [])) [node (R.ConstructorTest R.nilConstructor (R.FrameSize 1), literal R.Unit)] (literal R.Unit)))),
          invalid "global dependency order" ((program (literal R.Unit)) {R.programGlobalCount = 2, R.programInitialization = [node (R.GlobalGroup False ((R.GlobalIndex 0, node (R.Binding (node (R.Global (R.GlobalIndex 1))) False)) :| [])), node (R.GlobalGroup False ((R.GlobalIndex 1, node (R.Binding (literal R.Unit) False)) :| []))]}),
          testCase "entry is validated before execution" $ case Runtime.validateProgram (program (literal (R.Integer 1))) of
            Left errors -> assertFailure (show errors)
            Right checked -> case Runtime.selectEntry checked (R.GlobalIndex 1) of Left problem -> (B.errorKind problem, B.errorSpan problem) @?= (B.InvalidEntry, B.runtimeSpan); Right _ -> assertFailure "invalid entry accepted"
        ],
      testGroup
        "defensive Core hole rejection"
        [ holeCase "unused binding" (coreExpression (C.Let (coreNode (C.Binding (N.LocalRef (N.LocalId 0)) (Type.monomorphic coreInt) coreHole (C.BindingFacts 0 Nothing))) (coreExpression C.Fail))),
          holeCase "delayed lambda" (coreExpression (C.Lambda (coreNode (N.LocalId 1, "x", C.ValueBinder, coreInt)) coreHole)),
          holeCase "unselected arm" (coreExpression (C.If [coreNode (coreExpression (C.Construct (C.DataConstructor (N.IntrinsicId N.FalseConstructor)) [] []), coreHole)] (Just (coreExpression C.Fail)))),
          holeCase "dictionary method" (coreExpression (C.Dictionary (N.GlobalId (N.ModuleId ("Hole" :| [])) N.TypeNS "Trait") coreInt [] [coreNode (Type.monomorphic coreInt, coreHole)]))
        ],
      testGroup
        "primitives"
        [ primitiveCase "integer overflow wraps" R.IntAdd [R.Integer maxBound, R.Integer 1] (R.Integer minBound),
          primitiveCase "minimum divided by minus one wraps" R.IntDivide [R.Integer minBound, R.Integer (-1)] (R.Integer minBound),
          primitiveCase "remainder follows dividend sign" R.IntRemainder [R.Integer (-7), R.Integer 3] (R.Integer (-1)),
          primitiveCase "division truncates toward zero" R.IntDivide [R.Integer (-7), R.Integer 3] (R.Integer (-2)),
          primitiveCase "Unicode length counts code points" R.StringLength [R.String "a😀é"] (R.Integer 3),
          primitiveCase "character show is unquoted" R.CharShow [R.Character '😀'] (R.String "😀"),
          primitiveCase "float conversion truncates" R.FloatToInt [R.Floating (-1.9)] (R.Integer (-1)),
          primitiveCase "integer to float uses ties-to-even" R.IntToFloat [R.Integer 9007199254740993] (R.Floating 9007199254740992),
          primitiveCase "negative zero divides to negative infinity" R.FloatDivide [R.Floating 1, R.Floating (-0)] (R.Floating (-1 / 0)),
          primitiveCase "NaN compares unequal" R.FloatEqual [R.Floating (0 / 0), R.Floating (0 / 0)] (R.Boolean False),
          primitiveCase "infinity has specified spelling" R.FloatShow [R.Floating (-1 / 0)] (R.String "-Infinity"),
          primitiveCase "integer subtraction wraps" R.IntSubtract [R.Integer minBound, R.Integer 1] (R.Integer maxBound),
          primitiveCase "integer multiplication wraps" R.IntMultiply [R.Integer maxBound, R.Integer 2] (R.Integer (-2)),
          primitiveCase "integer negation wraps" R.IntNegate [R.Integer minBound] (R.Integer minBound),
          primitiveCase "integer equality" R.IntEqual [R.Integer 7, R.Integer 7] (R.Boolean True),
          primitiveCase "integer comparison" R.IntLess [R.Integer (-1), R.Integer 0] (R.Boolean True),
          primitiveCase "integer show is signed decimal" R.IntShow [R.Integer minBound] (R.String "-9223372036854775808"),
          primitiveCase "floating addition" R.FloatAdd [R.Floating 1.25, R.Floating 0.5] (R.Floating 1.75),
          primitiveCase "floating subtraction" R.FloatSubtract [R.Floating 1.25, R.Floating 0.5] (R.Floating 0.75),
          primitiveCase "floating multiplication" R.FloatMultiply [R.Floating 1.25, R.Floating 2] (R.Floating 2.5),
          primitiveCase "floating negation" R.FloatNegate [R.Floating 1.25] (R.Floating (-1.25)),
          primitiveCase "NaN compares unordered" R.FloatLess [R.Floating (0 / 0), R.Floating 1] (R.Boolean False),
          primitiveCase "signed zeros compare equal" R.FloatEqual [R.Floating 0, R.Floating (-0)] (R.Boolean True),
          primitiveCase "finite floating show" R.FloatShow [R.Floating 1.25] (R.String "1.25"),
          primitiveCase "NaN has specified spelling" R.FloatShow [R.Floating (0 / 0)] (R.String "NaN"),
          primitiveCase "character equality" R.CharEqual [R.Character '😀', R.Character '😀'] (R.Boolean True),
          primitiveCase "character comparison uses code points" R.CharLess [R.Character '\xE000', R.Character '\x10000'] (R.Boolean True),
          primitiveCase "string concatenation" R.StringAppend [R.String "a", R.String "😀"] (R.String "a😀"),
          primitiveCase "string equality" R.StringEqual [R.String "a", R.String "b"] (R.Boolean False),
          primitiveCase "string comparison uses code points" R.StringLess [R.String "\xE000", R.String "\x10000"] (R.Boolean True),
          testCase "byte conversion reduces modulo 256" $ do
            result <- runEvaluation (evaluatePrimitive "fixture: " quiet (R.ByteFromInt ()) [LiteralValue (R.Integer (-1))] >>= \byte -> evaluatePrimitive "fixture: " quiet (R.ByteToInt ()) [byte])
            fmap observe result @?= Right (int 255),
          testCase "string and immutable vector conversions preserve Unicode order" $ do
            result <- runEvaluation $ do
              chars <- evaluatePrimitive "fixture: " quiet R.StringToChars [LiteralValue (R.String "a😀é")]
              vector <- evaluatePrimitive "fixture: " quiet (R.VecFromList ()) [chars]
              count <- evaluatePrimitive "fixture: " quiet (R.VecLength ()) [vector]
              restored <- evaluatePrimitive "fixture: " quiet (R.VecToList ()) [vector] >>= \values -> evaluatePrimitive "fixture: " quiet R.CharsToString [values]
              pure (observe count, observe restored)
            result @?= Right (int 3, LiteralObservation (R.String "a😀é")),
          testCase "primitive failures retain their embedded context" $ forM_ [(R.IntDivide, [R.Integer 1, R.Integer 0]), (R.IntRemainder, [R.Integer 1, R.Integer 0]), (R.FloatToInt, [R.Floating (0 / 0)]), (R.FloatToInt, [R.Floating (1 / 0)]), (R.FloatToInt, [R.Floating 9223372036854775808])] $ \(operation, operands) -> do
            result <- runEvaluation (evaluatePrimitive "fixture: " quiet operation (map LiteralValue operands))
            case result of Left problem -> assertBool "failure message retains its context" ("fixture: " `T.isPrefixOf` E.errorMessage problem); Right value -> assertFailure (show (observe value)),
          testCase "IO exceptions become typed failures" $ do
            result <- runEvaluation (evaluatePrimitive "fixture: " (Effects (\_ _ -> ioError (userError "fixture")) (\_ _ -> pure "")) (R.HandleWrite ()) [HandleValue StandardOutput, LiteralValue (R.String "x")])
            case result of Left problem -> assertBool "failure message retains its context" ("fixture: " `T.isPrefixOf` E.errorMessage problem); Right _ -> assertFailure "IO exception disappeared",
          testCase "standard handles retain distinct identities" $
            forM_ [(R.HandleStdin (), StandardInput), (R.HandleStdout (), StandardOutput), (R.HandleStderr (), StandardError)] $ \(operation, handle) -> do
              result <- runEvaluation (evaluatePrimitive "fixture: " quiet operation [])
              fmap observe result @?= Right (HandleObservation handle),
          testCase "handle writes route stdout and stderr separately" $ do
            output <- newIORef []
            let effects = Effects (\handle text -> modifyIORef' output (<> [(handle, text)])) (\_ _ -> pure "")
            result <- runEvaluation $ do
              _ <- evaluatePrimitive "fixture: " effects (R.HandleWrite ()) [HandleValue StandardOutput, LiteralValue (R.String "out")]
              evaluatePrimitive "fixture: " effects (R.HandleWrite ()) [HandleValue StandardError, LiteralValue (R.String "err")]
            fmap observe result @?= Right (LiteralObservation R.Unit)
            readIORef output >>= (@?= [(StandardOutput, "out"), (StandardError, "err")]),
          testCase "handle reads consume bounded Unicode chunks" $ do
            result <- captureInput "a😀é" $ \effects -> runEvaluation $ do
              first <- evaluatePrimitive "fixture: " effects (R.HandleRead ()) [HandleValue StandardInput, LiteralValue (R.Integer 2)]
              second <- evaluatePrimitive "fixture: " effects (R.HandleRead ()) [HandleValue StandardInput, LiteralValue (R.Integer 2)]
              lastChunk <- evaluatePrimitive "fixture: " effects (R.HandleRead ()) [HandleValue StandardInput, LiteralValue (R.Integer 2)]
              pure (Aggregate R.pairConstructor (V.fromList [first, Aggregate R.pairConstructor (V.fromList [second, lastChunk])]))
            result @?= (Right (AggregateObservation R.pairConstructor [LiteralObservation (R.String "a😀"), AggregateObservation R.pairConstructor [LiteralObservation (R.String "é"), LiteralObservation (R.String "")]]), []),
          testCase "nonpositive handle reads skip effects" $ forM_ [0, -1] $ \count -> do
            let effects = Effects (\_ _ -> pure ()) (\_ _ -> assertFailure "read effect ran" >> pure "")
            result <- runEvaluation (evaluatePrimitive "fixture: " effects (R.HandleRead ()) [HandleValue StandardInput, LiteralValue (R.Integer count)])
            fmap observe result @?= Right (LiteralObservation (R.String "")),
          testCase "unsupported handle directions fail at the primitive span" $
            forM_ [(R.HandleRead (), [HandleValue StandardOutput, LiteralValue (R.Integer 1)]), (R.HandleRead (), [HandleValue StandardError, LiteralValue (R.Integer 1)]), (R.HandleWrite (), [HandleValue StandardInput, LiteralValue (R.String "x")])] $ \(operation, values) -> do
              result <- runEvaluation (evaluatePrimitive "fixture: " quiet operation values)
              case result of
                Left problem -> assertBool "failure message retains its context" ("fixture: " `T.isPrefixOf` E.errorMessage problem)
                Right _ -> assertFailure "invalid handle direction succeeded"
        ],
      QC.testProperty "compiled == direct == arithmetic oracle, including failures and traces" $ QC.forAll (QC.sized (term . min 7)) $ \value -> QC.ioProperty $ do
        case Runtime.validateProgram (program (termExpr value)) of
          Left errors -> pure (QC.counterexample (show errors) False)
          Right checked -> do
            compiled <- capture (execute checked (R.GlobalIndex 0) [])
            direct <- capture (\effects -> runDirect effects checked (R.GlobalIndex 0) [])
            pure (QC.counterexample (show (compiled, direct, termValue value)) (compiled == direct && compiled == termValue value)),
      QC.testProperty "source lowering preserves the independent arithmetic oracle" $ QC.forAll (QC.sized (term . min 7)) $ \value -> QC.ioProperty $ do
        actual <- sourceResult (printing <> arithmetic <> "check () = " <> termSource value <> "\n")
        let withoutLocation (result, trace) = (either (const (Left ())) Right result, trace)
        pure (QC.counterexample (show actual) (withoutLocation actual == withoutLocation (termValue value)))
    ]
  where
    invalid name tree = testCase name $ case Runtime.validateProgram tree of
      Right _ -> assertFailure "malformed Runtime accepted"
      Left errors -> do assertBool "error returned" (not (null errors)); mapM_ (\problem -> (B.errorKind problem, B.errorSpan problem) @?= (B.InvalidProgram, B.runtimeSpan)) errors
    primitiveCase name operation operands expected = testCase name $ do
      result <- runEvaluation (evaluatePrimitive "fixture: " quiet operation (map LiteralValue operands))
      fmap observe result @?= Right (LiteralObservation expected)

matchError :: Span -> E.RuntimeError
matchError site = E.RuntimeError (T.pack (sourceFile site) <> ":" <> T.pack (show (line (start site))) <> ":" <> T.pack (show (column (start site))) <> ": pattern match failed: uncaught exception")

fixtureSpan :: Text -> Text -> Span
fixtureSpan source fragment = Span "Runtime.ficus" (end (sourceEndSpan "" before)) (end (sourceEndSpan "" (before <> T.dropEnd 1 fragment)))
  where
    (before, _) = T.breakOn fragment ("{-# NO_IMPLICIT_PRELUDE #-}\n" <> source <> if any (`T.isInfixOf` source) ["BUILTIN INT_DIV", "BUILTIN INT_REM", "BUILTIN FLOAT_TO_INT", "BUILTIN HANDLE_READ", "BUILTIN HANDLE_WRITE"] then errorDeclarations <> matchDeclarations else matchDeclarations)

termSource :: Term -> Text
termSource value = case value of
  Number number -> "(" <> T.pack (show number) <> ")"
  Add a b -> "(add " <> termSource a <> " " <> termSource b <> ")"
  Trace message body -> "({ print \"" <> message <> "\"; " <> termSource body <> " })"
  Choice condition yes no -> "(if { " <> (if condition then "True" else "False") <> " -> " <> termSource yes <> "; _ -> " <> termSource no <> " })"
  Failure -> "(if { False -> 0 })"

checkedLibrary :: Text -> IO LoweredProgram
checkedLibrary source = do
  let owner = N.ModuleId ("Runtime" :| [])
      provider ident
        | ident == owner = pure (Right (Source "Runtime.ficus" source))
        | otherwise = fileProvider (ProviderConfig ["library"] PreludeFromRoots) ident
  graph <- discoverModules provider [owner]
  let resolved = resolveGraph libraryResolveConfig librarySugarRegistry graph
  assertBool (show (frontendDiagnostics resolved)) (all ((/= D.Error) . D.diagnosticSeverity . D.toDiagnostic) (frontendDiagnostics resolved))
  checked <- foldM (checkModule graph resolved) Map.empty (dependencyOrder graph)
  case lowerProgram [validatedModule (Elab.checkedCore value) | ident <- dependencyOrder graph, Just value <- [Map.lookup ident checked]] of
    Left errors -> assertFailure (show errors) >> fail "library lowering failed"
    Right result -> pure result
  where
    checkModule graph resolved previous ident = case (Map.lookup ident (frontendModules resolved), Map.lookup ident (graphModules graph)) of
      (Just tree, Just discovered) -> do
        let imports = [Elab.checkedInterface value | edge <- headerEdges (discoveredHeader discovered), Just value <- [Map.lookup (edgeTarget edge) previous]]
        case Elab.elaborateModule imports tree of
          Elab.Complete result _ -> pure (Map.insert ident result previous)
          Elab.Incomplete _ errors -> assertFailure (show errors) >> fail "library elaboration failed"
      _ -> assertFailure "library module missing" >> fail "library module missing"

coreInt :: C.CoreType
coreInt = Type.primitive N.IntType

coreNode :: a -> C.Node a
coreNode = C.Node (N.NodeId 0) origin (SourceOrigin origin)

coreExpression :: C.ExprF C.CoreType -> C.Expr C.CoreType
coreExpression = coreNode . C.TypedExpr coreInt

coreHole :: C.Expr C.CoreType
coreHole = coreExpression (C.Hole (N.HoleId 0))

holeCase :: String -> C.Expr C.CoreType -> TestTree
holeCase name body = testCase name $ do
  let owner = N.ModuleId ("Hole" :| [])
      binding = coreNode (C.Binding (N.GlobalRef (N.GlobalId owner N.ValueNS "entry")) (Type.monomorphic coreInt) body (C.BindingFacts 0 Nothing))
      tree = C.CoreModule owner defaultCompilationConfig origin (SourceOrigin origin) Map.empty Map.empty Map.empty Map.empty Map.empty Map.empty Map.empty [C.NonRecursive binding] Map.empty
  case lowerProgram [tree] of
    Right _ -> assertFailure "hole reached Runtime"
    Left errors -> map (\problem -> (B.errorKind problem, B.errorSpan problem)) errors @?= [(B.ExpressionHole, origin)]

data Term = Number Int64 | Add Term Term | Trace Text Term | Choice Bool Term Term | Failure deriving (Show)

term :: Int -> QC.Gen Term
term size | size <= 0 = Number <$> QC.choose (-100, 100)
term size = QC.oneof [term 0, Add <$> child <*> child, Trace <$> QC.elements ["a", "b", "c"] <*> child, Choice <$> QC.arbitrary <*> child <*> child, pure Failure]
  where
    child = term (size `div` 2)

termExpr :: Term -> R.Expr
termExpr value = case value of
  Number number -> literal (R.Integer number)
  Add a b -> primitive R.IntAdd [termExpr a, termExpr b]
  Trace message body -> node (R.Let (node (R.Binding (primitive (R.HandleWrite ()) [primitive (R.HandleStdout ()) [], literal (R.String message)]) False)) (termExpr body))
  Choice choice yes no -> node (R.If [node (literal (R.Boolean choice), termExpr yes)] (termExpr no))
  Failure -> primitive R.MatchFailure [literal (R.String "pattern match failed")]

termValue :: Term -> (Either E.RuntimeError Observation, [Text])
termValue value = case value of
  Number number -> (Right (int number), [])
  Failure -> (Left (E.RuntimeError "pattern match failed: uncaught exception"), [])
  Trace message body -> let (result, trace) = termValue body in (result, message : trace)
  Choice choice yes no -> termValue (if choice then yes else no)
  Add a b -> case termValue a of
    failure@(Left _, _) -> failure
    (Right (LiteralObservation (R.Integer first)), earlier) -> case termValue b of
      (Right (LiteralObservation (R.Integer second)), later) -> (Right (int (first + second)), earlier ++ later)
      (failed, later) -> (failed, earlier ++ later)
    other -> other

libraryResult :: Text -> Text -> IO (Either E.RuntimeError Observation, [Text])
libraryResult input source = do
  lowered <- checkedLibrary source
  case Map.lookup (N.GlobalId (N.ModuleId ("Runtime" :| [])) N.ValueNS "check") (loweredGlobals lowered) of
    Nothing -> assertFailure "missing library entry" >> fail "missing library entry"
    Just ident -> compareEvaluatorsWithInput input (loweredProgram lowered) ident [LiteralValue R.Unit]
