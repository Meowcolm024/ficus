module FicusBackend.Runtime.Validate (ValidatedProgram, validatedProgram, validateProgram) where

import Data.List (nub)
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Vector qualified as V
import Ficus.Util.Source
import FicusBackend.Error qualified as E
import FicusBackend.Runtime.AST

newtype ValidatedProgram = ValidatedProgram Program deriving (Eq, Show)

validatedProgram :: ValidatedProgram -> Program
validatedProgram (ValidatedProgram program) = program

validateProgram :: Program -> Either [E.BackendError] ValidatedProgram
validateProgram program = case errors of [] -> Right (ValidatedProgram program); _ -> Left errors
  where
    errors =
      require E.runtimeSpan (programGlobalCount program >= 0) "negative global count"
        ++ concatMap (\layout -> require (E.runtimeSpan) (let FrameSize n = constructorFields (nodeValue layout) in n >= 0) "negative constructor size") (programConstructors program)
        ++ concat [require (E.runtimeSpan) (fmap (constructorFields . nodeValue) (programConstructors program V.!? index') == Just (FrameSize size)) "missing intrinsic constructor layout" | (index', size) <- [(0, 0), (1, 2), (2, 2)]]
        ++ concatMap checkFunction (programFunctions program)
        ++ snd (foldl checkGroup (Set.empty, []) (programInitialization program))
        ++ require (E.runtimeSpan) (Set.fromList initialized == Set.fromList [GlobalIndex n | n <- [0 .. programGlobalCount program - 1]] && length initialized == length (nub initialized)) "globals must be initialized exactly once"
    initialized = [ident | group <- programInitialization program, (ident, _) <- NE.toList (groupBindings (nodeValue group))]
    checkFunction node =
      let function = nodeValue node
          Arity arity = functionArity function
          FrameSize size = functionFrameSize function
          CaptureLayout captures = functionCaptures function
       in require (E.runtimeSpan) (arity > 0 && size == arity && V.length (functionParameters function) == arity && captures >= 0) "invalid function frame, arity or capture layout"
            ++ expression [size] captures (functionBody function)
    expression frames captures node =
      case nodeValue node of
        Load address -> addressErrors frames captures (E.runtimeSpan) address
        Global (GlobalIndex ident) -> require E.runtimeSpan (ident >= 0 && ident < programGlobalCount program) "runtime global index is out of bounds"
        Literal _ -> []
        Closure (FunctionIndex ident) sources ->
          bounded (E.runtimeSpan) ident (programFunctions program)
            ++ concatMap (\source -> addressErrors frames captures (E.runtimeSpan) (nodeValue source)) sources
            ++ case programFunctions program V.!? ident of
              Nothing -> []
              Just function -> require (E.runtimeSpan) (functionCaptures (nodeValue function) == CaptureLayout (length sources)) "closure capture count differs from function layout"
        Call f arguments -> expression frames captures f ++ concatMap (expression frames captures) arguments
        Let binding body -> bindingErrors frames captures binding ++ expression (1 : frames) captures body
        LetRec bindings body ->
          let count = NE.length bindings
              extended = count : frames
              danger = V.replicate count True : map (\n -> V.replicate n False) frames
           in concatMap (bindingErrors extended captures) bindings
                ++ concatMap cyclicBinding bindings
                ++ concatMap (unsafeReads Set.empty danger (V.replicate captures False) Set.empty . bindingBody . nodeValue) bindings
                ++ expression extended captures body
        TypeToken (ConstructorIndex ident) fields -> layoutArity E.runtimeSpan ident (length fields) ++ concatMap (expression frames captures) fields
        Construct (ConstructorIndex ident) fields -> layoutArity (E.runtimeSpan) ident (length fields) ++ concatMap (expression frames captures) fields
        Case receiver alternatives fallback -> expression frames captures receiver ++ concatMap alternative alternatives ++ expression frames captures fallback
          where
            alternative arm =
              case nodeValue arm of
                (LiteralTest _, body) -> expression (0 : frames) captures body
                (ConstructorTest (ConstructorIndex ident) (FrameSize size), body) -> layoutArity (E.runtimeSpan) ident size ++ expression (size : frames) captures body
        If arms fallback -> concatMap (\arm -> let (condition, body) = nodeValue arm in expression frames captures condition ++ expression frames captures body) arms ++ expression frames captures fallback
        Select receiver (ConstructorIndex ident) (FieldIndex field) ->
          expression frames captures receiver
            ++ bounded (E.runtimeSpan) ident (programConstructors program)
            ++ case programConstructors program V.!? ident of
              Nothing -> []
              Just layout -> let FrameSize size = constructorFields (nodeValue layout) in require (E.runtimeSpan) (field >= 0 && field < size) "field slot is out of bounds"
        Primitive (PrimitiveIndex ident) arguments _ ->
          bounded (E.runtimeSpan) ident (programPrimitives program)
            ++ concatMap (expression frames captures) arguments
            ++ case programPrimitives program V.!? ident of
              Nothing -> []
              Just primitive -> require (E.runtimeSpan) (primitiveArity primitive == Arity (length arguments)) "primitive operand count differs from its arity"
        Raise _ -> []
    bindingErrors frames captures binding = expression frames captures (bindingBody (nodeValue binding))
    cyclicBinding binding = require E.runtimeSpan (not (bindingExpansive (nodeValue binding))) "expansive recursive initializer"
    layoutArity origin ident count =
      bounded origin ident (programConstructors program) ++ case programConstructors program V.!? ident of
        Nothing -> []
        Just layout -> require origin (constructorFields (nodeValue layout) == FrameSize count) "constructor field count differs from layout"
    checkGroup (done, previous) group =
      let value = nodeValue group
          bindings = NE.toList (groupBindings value)
          names = Set.fromList (map fst bindings)
          dependencies = Set.unions [globalUses Set.empty (bindingBody (nodeValue binding)) | (_, binding) <- bindings]
          available = if groupRecursive value then done `Set.union` names else done
          failures =
            require (E.runtimeSpan) (groupRecursive value || length bindings == 1) "non-recursive initialization group must have one member"
              ++ require (E.runtimeSpan) (Set.null (done `Set.intersection` names)) "global initialized more than once"
              ++ require (E.runtimeSpan) (dependencies `Set.isSubsetOf` available) "global initialization is not in dependency order"
              ++ concat [require E.runtimeSpan (ident >= 0 && ident < programGlobalCount program) "runtime global index is out of bounds" ++ bindingErrors [] 0 binding | (GlobalIndex ident, binding) <- bindings]
              ++ if groupRecursive value then concatMap (\(_, binding) -> cyclicBinding binding ++ unsafeReads names [] V.empty Set.empty (bindingBody (nodeValue binding))) bindings else []
       in (done `Set.union` names, previous ++ failures)
    globalUses visited node = case nodeValue node of
      Global ident -> Set.singleton ident
      Closure ident@(FunctionIndex index') _ | ident `Set.notMember` visited -> maybe Set.empty (globalUses (Set.insert ident visited) . functionBody . nodeValue) (programFunctions program V.!? index')
      _ -> Set.unions (map (globalUses visited) (children node))
    -- Cell capture itself does not read a value. Following evidence-only
    -- closures here preserves the source rule that evidence is not protection.
    unsafeReads globals frames captures visited node = case nodeValue node of
      Global ident | ident `Set.member` globals -> invalid (E.runtimeSpan) "unprotected recursive global read"
      Load address | dangerous frames captures address -> invalid (E.runtimeSpan) "unprotected recursive local read"
      Closure ident@(FunctionIndex index') sources | ident `Set.notMember` visited -> case programFunctions program V.!? index' of
        Just function
          | ValueParameter `V.notElem` functionParameters (nodeValue function) ->
              let Arity arity = functionArity (nodeValue function)
                  captured = V.fromList (map (dangerous frames captures . nodeValue) sources)
               in unsafeReads globals [V.replicate arity False] captured (Set.insert ident visited) (functionBody (nodeValue function))
        _ -> []
      Let binding body -> recurse (bindingBody (nodeValue binding)) ++ unsafeReads globals (V.singleton False : frames) captures visited body
      LetRec bindings body -> let extended = V.replicate (NE.length bindings) False : frames in concatMap (unsafeReads globals extended captures visited . bindingBody . nodeValue) bindings ++ unsafeReads globals extended captures visited body
      Case receiver alternatives fallback -> recurse receiver ++ recurse fallback ++ concatMap (\arm -> let (test, body) = nodeValue arm; size = case test of LiteralTest _ -> 0; ConstructorTest _ (FrameSize n) -> n in unsafeReads globals (V.replicate size False : frames) captures visited body) alternatives
      _ -> concatMap recurse (children node)
      where
        recurse = unsafeReads globals frames captures visited

children :: Expr -> [Expr]
children node = case nodeValue node of
  Load _ -> []
  Global _ -> []
  Literal _ -> []
  Closure _ _ -> []
  Raise _ -> []
  Call f arguments -> f : NE.toList arguments
  Let binding body -> [bindingBody (nodeValue binding), body]
  LetRec bindings body -> map (bindingBody . nodeValue) (NE.toList bindings) ++ [body]
  Construct _ fields -> fields
  TypeToken _ fields -> fields
  Case receiver alternatives fallback -> receiver : fallback : map (snd . nodeValue) alternatives
  If arms fallback -> concatMap (\arm -> let (a, b) = nodeValue arm in [a, b]) arms ++ [fallback]
  Select receiver _ _ -> [receiver]
  Primitive _ arguments _ -> arguments

dangerous :: [V.Vector Bool] -> V.Vector Bool -> Address -> Bool
dangerous frames captures address = case address of
  Capture (CaptureIndex slot) -> maybe False id (captures V.!? slot)
  Local (FrameDepth depth) (SlotIndex slot) -> case drop depth frames of frame : _ | depth >= 0 -> maybe False id (frame V.!? slot); _ -> False

addressErrors :: [Int] -> Int -> Span -> Address -> [E.BackendError]
addressErrors frames captures origin address = require origin valid "lexical address is out of bounds"
  where
    valid = case address of
      Capture (CaptureIndex slot) -> slot >= 0 && slot < captures
      Local (FrameDepth depth) (SlotIndex slot) -> case drop depth frames of size : _ -> depth >= 0 && slot >= 0 && slot < size; [] -> False

bounded :: Span -> Int -> V.Vector a -> [E.BackendError]
bounded origin ident entries = require origin (ident >= 0 && ident < V.length entries) "runtime table index is out of bounds"

require :: Span -> Bool -> Text -> [E.BackendError]
require _ True _ = []
require origin False message = invalid origin message

invalid :: Span -> Text -> [E.BackendError]
invalid origin message = [E.BackendError E.InvalidProgram origin message]
