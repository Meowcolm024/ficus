-- | Block ANF: operands are atomic and calls are unary. Binding initializers
-- may contain blocks, so branch joins need neither duplication nor new closures.
module FicusBackend.Pass.Normalize (NormalizedProgram, normalizedProgram, normalizeProgram, validateNormalized) where

import Data.Foldable (toList)
import Data.List.NonEmpty qualified as NE
import FicusBackend.Error qualified as E
import FicusBackend.Pass.Traversal
import FicusBackend.Runtime.AST
import FicusBackend.Runtime.Validate

newtype NormalizedProgram = NormalizedProgram ValidatedProgram deriving (Eq, Show)

normalizedProgram :: NormalizedProgram -> ValidatedProgram
normalizedProgram (NormalizedProgram program) = program

normalizeProgram :: ValidatedProgram -> Either [E.BackendError] NormalizedProgram
normalizeProgram = validateNormalized . mapBodies normalize . validatedProgram

validateNormalized :: Program -> Either [E.BackendError] NormalizedProgram
validateNormalized program = do
  checked <- validateProgram program
  let roots = map (functionBody . nodeValue) (toList (programFunctions program)) ++ [bindingBody (nodeValue binding) | group <- programInitialization program, (_, binding) <- NE.toList (groupBindings (nodeValue group))]
      errors = concatMap check roots
  if null errors then Right (NormalizedProgram checked) else Left errors
  where
    check expression = [E.BackendError E.InvalidProgram E.runtimeSpan "non-atomic operand or non-unary call in normalized Runtime" | not (normal expression)] ++ concatMap check (children expression)
    normal expression = case nodeValue expression of
      Call function (argument NE.:| []) -> all atomic [function, argument]
      Call _ _ -> False
      TailCall function argument -> all atomic [function, argument]
      Construct _ fields -> all atomic fields
      TypeToken _ fields -> all atomic fields
      Select receiver _ _ -> atomic receiver
      Primitive _ arguments _ -> all atomic arguments
      Case receiver _ _ -> atomic receiver
      If arms _ -> length arms <= 1 && all (atomic . fst . nodeValue) arms
      _ -> True

atomic :: Expr -> Bool
atomic expression = case nodeValue expression of
  Load _ -> True
  Global _ -> True
  Literal _ -> True
  Closure _ _ -> True
  _ -> False

normalize :: Expr -> Expr
normalize expression = case nodeValue expression of
  Call function arguments -> calls function (NE.toList arguments)
    where
      calls callee [] = normalize callee
      calls callee [argument] = twoOperands callee argument (\f a -> Node (Call f (a NE.:| [])))
      calls callee (argument : rest) = calls (Node (Call callee (argument NE.:| []))) rest
  TailCall function argument -> twoOperands function argument (\f a -> Node (TailCall f a))
  Construct tag fields -> operands fields (\_ values -> Node (Construct tag values))
  TypeToken tag fields -> operands fields (\_ values -> Node (TypeToken tag values))
  Primitive ident arguments context -> operands arguments (\_ values -> Node (Primitive ident values context))
  Select receiver owner field -> oneOperand receiver (\_ value -> Node (Select value owner field))
  Case receiver alternatives fallback -> oneOperand receiver $ \count value ->
    -- The receiver refers to the new temporary; shift only the original arms.
    Node (Case value (map (fmap (\(test, body) -> (test, shift count 1 (normalize body)))) alternatives) (shift count 0 (normalize fallback)))
  If [] fallback -> normalize fallback
  If (arm : rest) fallback ->
    let (condition, result) = nodeValue arm
     in oneOperand condition (\count value -> Node (If [Node (value, shift count 0 (normalize result))] (shift count 0 (normalize (Node (If rest fallback))))))
  _ -> mapChildren normalize expression

oneOperand :: Expr -> (Int -> Expr -> Expr) -> Expr
oneOperand value continuation
  | atomic value = continuation 0 value
  | otherwise = Node (Let (Node (Binding (normalize value) True)) (continuation 1 (temporary 0)))

twoOperands :: Expr -> Expr -> (Expr -> Expr -> Expr) -> Expr
twoOperands first second continuation
  | atomic first && atomic second = continuation first second
  | otherwise = Node (Let (Node (Binding (normalize first) True)) (Node (Let (Node (Binding (normalize (shift 1 0 second)) True)) (continuation (temporary 1) (temporary 0)))))

temporary :: Int -> Expr
temporary depth = Node (Load (Local (FrameDepth depth) (SlotIndex 0)))

-- Snapshot operands in order. In particular, do not move a later operand past
-- an earlier application, reference read, exception, or recursive-cell read.
operands :: [Expr] -> (Int -> [Expr] -> Expr) -> Expr
operands values continuation
  | all atomic values = continuation 0 values
  | otherwise = bind 0 values
  where
    count = length values
    bind _ [] = continuation count (map temporary (reverse [0 .. count - 1]))
    bind depth (value : rest) = Node (Let (Node (Binding (normalize (shift depth 0 value)) True)) (bind (depth + 1) rest))

-- Shift only references to frames outside the expression, including cell
-- captures. Pattern alternatives introduce a frame even for literal tests.
shift :: Int -> Int -> Expr -> Expr
shift 0 _ expression = expression
shift amount cutoff expression = case nodeValue expression of
  Load address -> Node (Load (address' address))
  Closure function captures -> Node (Closure function (map (fmap address') captures))
  Let binding body -> Node (Let (fmap binding' binding) (shift amount (cutoff + 1) body))
  LetRec bindings body -> Node (LetRec (fmap (fmap (\binding -> binding {bindingBody = shift amount (cutoff + 1) (bindingBody binding)})) bindings) (shift amount (cutoff + 1) body))
  Case receiver alternatives fallback -> Node (Case (recurse receiver) (map (fmap (\(test, body) -> (test, shift amount (cutoff + 1) body))) alternatives) (recurse fallback))
  _ -> mapChildren recurse expression
  where
    recurse = shift amount cutoff
    binding' binding = binding {bindingBody = recurse (bindingBody binding)}
    address' (Local (FrameDepth depth) slot) | depth >= cutoff = Local (FrameDepth (depth + amount)) slot
    address' address = address
