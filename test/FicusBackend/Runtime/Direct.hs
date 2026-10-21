-- Deliberately walks Runtime syntax on every evaluation; the production
-- evaluator compiles each node once. Shared primitives have separate tests.
module FicusBackend.Runtime.Direct (runDirect) where

import Control.Monad (foldM, forM_)
import Data.List.NonEmpty qualified as NE
import Data.Vector qualified as V
import FicusBackend.Runtime.AST
import FicusBackend.Runtime.Error qualified as E
import FicusBackend.Runtime.Primitive
import FicusBackend.Runtime.Validate
import FicusBackend.Runtime.Value

runDirect :: Effects -> ValidatedProgram -> GlobalIndex -> [Value] -> IO (Either E.RuntimeError Value)
runDirect effects checked (GlobalIndex entry) arguments = runEvaluation $ do
  globals <- emptyFrame (programGlobalCount program)
  let functions = V.map (\node -> let function = nodeValue node in FunctionCode (functionArity function) (interpret program (functionBody function))) (programFunctions program)
      env = Env [] V.empty globals functions effects
  forM_ (programInitialization program) $ \group -> forM_ (groupBindings (nodeValue group)) $ \(GlobalIndex ident, binding) -> do
    value <- interpret program (bindingBody (nodeValue binding)) env
    cell <- index globals ident
    writeCell cell value
  value <- index globals entry >>= readCell
  foldM (applyValueWithEffects (envEffects env)) value arguments
  where
    program = validatedProgram checked

interpret :: Program -> Expr -> Eval
interpret program source env = case nodeValue source of
  Load address -> addressCell env address >>= readCell
  Global (GlobalIndex slot) -> index (envGlobals env) slot >>= readCell
  Literal literal -> pure (LiteralValue literal)
  Closure function captures -> makeClosure env function (map nodeValue captures)
  Call function arguments -> do
    value <- interpret program function env
    foldM (\current argument -> interpret program argument env >>= applyValueWithEffects (envEffects env) current) value arguments
  Let binding body -> do
    value <- interpret program (bindingBody (nodeValue binding)) env
    frame <- valueFrame [value]
    interpret program body (pushFrame frame env)
  LetRec bindings body -> do
    frame <- emptyFrame (NE.length bindings)
    let recursive = pushFrame frame env
    forM_ (zip [0 ..] (NE.toList bindings)) $ \(slot, binding) -> do
      value <- interpret program (bindingBody (nodeValue binding)) recursive
      cell <- index frame slot
      writeCell cell value
    interpret program body recursive
  TypeToken constructor fields -> mapM (\field -> interpret program field env) fields >>= makeTypeToken constructor
  Construct constructor fields -> Aggregate constructor . V.fromList <$> mapM (\field -> interpret program field env) fields
  Case receiver alternatives fallback -> do
    value <- interpret program receiver env
    let choose [] = interpret program fallback env
        choose (alternative : rest) = case nodeValue alternative of
          (test, body) -> case testValue test value of
            Nothing -> choose rest
            Just fields -> do frame <- valueFrame fields; interpret program body (pushFrame frame env)
    choose alternatives
  If arms fallback ->
    let choose [] = interpret program fallback env
        choose (arm : rest) =
          let (condition, body) = nodeValue arm
           in interpret program condition env >>= \case
                LiteralValue (Boolean True) -> interpret program body env
                LiteralValue (Boolean False) -> choose rest
                _ -> invalidValue "conditional requires Bool"
     in choose arms
  Select receiver owner field -> interpret program receiver env >>= selectField owner field
  Primitive (PrimitiveIndex ident) arguments context -> do
    values <- mapM (\argument -> interpret program argument env) arguments
    operation <- index (programPrimitives program) ident
    evaluatePrimitive context (envEffects env) operation values
  Raise message -> raiseRuntime message
