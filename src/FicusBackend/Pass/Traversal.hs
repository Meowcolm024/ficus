-- | Structural helpers shared by target-independent Runtime passes.
module FicusBackend.Pass.Traversal (mapChildren, mapBodies, children) where

import Data.List.NonEmpty qualified as NE
import FicusBackend.Runtime.AST

mapBodies :: (Expr -> Expr) -> Program -> Program
mapBodies transform program =
  program
    { programFunctions = fmap (fmap (\function -> function {functionBody = transform (functionBody function)})) (programFunctions program),
      programInitialization = map (fmap (\group -> group {groupBindings = fmap (\(ident, binding) -> (ident, fmap (\value -> value {bindingBody = transform (bindingBody value)}) binding)) (groupBindings group)})) (programInitialization program)
    }

mapChildren :: (Expr -> Expr) -> Expr -> Expr
mapChildren transform = fmap $ \case
  Call function arguments -> Call (transform function) (fmap transform arguments)
  TailCall function argument -> TailCall (transform function) (transform argument)
  Let binding body -> Let (binding' binding) (transform body)
  LetRec bindings body -> LetRec (fmap binding' bindings) (transform body)
  Construct tag fields -> Construct tag (map transform fields)
  TypeToken tag fields -> TypeToken tag (map transform fields)
  Case receiver alternatives fallback -> Case (transform receiver) (map (fmap (\(test, body) -> (test, transform body))) alternatives) (transform fallback)
  If arms fallback -> If (map (fmap (\(condition, body) -> (transform condition, transform body))) arms) (transform fallback)
  Select receiver owner field -> Select (transform receiver) owner field
  Primitive ident arguments context -> Primitive ident (map transform arguments) context
  leaf -> leaf
  where
    binding' = fmap (\binding -> binding {bindingBody = transform (bindingBody binding)})

children :: Expr -> [Expr]
children node = case nodeValue node of
  Load _ -> []
  Global _ -> []
  Literal _ -> []
  Closure _ _ -> []
  Call function arguments -> function : NE.toList arguments
  TailCall function argument -> [function, argument]
  Let binding body -> [bindingBody (nodeValue binding), body]
  LetRec bindings body -> map (bindingBody . nodeValue) (NE.toList bindings) ++ [body]
  Construct _ fields -> fields
  TypeToken _ fields -> fields
  Case receiver alternatives fallback -> receiver : fallback : map (snd . nodeValue) alternatives
  If arms fallback -> concatMap (\arm -> let (condition, body) = nodeValue arm in [condition, body]) arms ++ [fallback]
  Select receiver _ _ -> [receiver]
  Primitive _ arguments _ -> arguments
