-- | Mark transfers only where no caller work remains. Unknown callees and
-- partial applications use the same transfer protocol as direct recursion.
module FicusBackend.Pass.TailCalls (optimizeTailCalls) where

import Data.List.NonEmpty qualified as NE
import FicusBackend.Error qualified as E
import FicusBackend.Pass.Normalize
import FicusBackend.Runtime.AST
import FicusBackend.Runtime.Validate (validatedProgram)

optimizeTailCalls :: NormalizedProgram -> Either [E.BackendError] NormalizedProgram
optimizeTailCalls checked = validateNormalized program
  where
    original = validatedProgram (normalizedProgram checked)
    program = original {programFunctions = fmap (fmap (\function -> function {functionBody = tailPosition (functionBody function)})) (programFunctions original)}

-- Operand and initializer subtrees intentionally remain untouched.
tailPosition :: Expr -> Expr
tailPosition expression = case nodeValue expression of
  Call function (argument NE.:| []) -> Node (TailCall function argument)
  Let binding body -> Node (Let binding (tailPosition body))
  LetRec bindings body -> Node (LetRec bindings (tailPosition body))
  Case receiver alternatives fallback -> Node (Case receiver (map (fmap (\(test, body) -> (test, tailPosition body))) alternatives) (tailPosition fallback))
  If arms fallback -> Node (If (map (fmap (\(condition, body) -> (condition, tailPosition body))) arms) (tailPosition fallback))
  _ -> expression
