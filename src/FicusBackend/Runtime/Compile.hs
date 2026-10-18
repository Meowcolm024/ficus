-- | Each child evaluator is compiled once. Execution dispatches through these
-- closures, never through the Runtime expression constructors.
module FicusBackend.Runtime.Compile
  ( Executable,
    Instance,
    Entry,
    compileProgram,
    compileExpr,
    selectEntry,
    initialize,
    initializeWith,
    evaluateEntry,
    runProgram,
  )
where

import Control.Monad (foldM, forM_)
import Control.Monad.Except (runExceptT, throwError)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Vector qualified as V
import Ficus.Util.Source
import FicusBackend.Runtime.AST
import FicusBackend.Runtime.Error qualified as E
import FicusBackend.Runtime.Primitive
import FicusBackend.Runtime.Validate
import FicusBackend.Runtime.Value

data Executable = Executable Program (V.Vector FunctionCode) [(GlobalIndex, Eval)]

newtype Instance = Instance Env

data Entry = Entry Span GlobalIndex

selectEntry :: ValidatedProgram -> GlobalIndex -> Either E.RuntimeError Entry
selectEntry checked ident@(GlobalIndex slot) = case programGlobals program V.!? slot of
  Nothing -> Left (E.RuntimeError E.InvalidEntry (programSpan program) "entry global is out of bounds")
  Just node -> Right (Entry (nodeSpan node) ident)
  where
    program = validatedProgram checked

compileProgram :: ValidatedProgram -> Executable
compileProgram checked = Executable program functions initializers
  where
    program = validatedProgram checked
    functions = V.fromList (strictMap (\node -> let function = nodeValue node in FunctionCode (functionArity function) (compileExpr program (functionBody function))) (V.toList (programFunctions program)))
    initializers = strictMap compileBinding [(ident, binding) | group <- programInitialization program, (ident, binding) <- NE.toList (groupBindings (nodeValue group))]
    compileBinding (ident, binding) = let !evaluator = compileExpr program (bindingBody (nodeValue binding)) in (ident, evaluator)

initialize :: Effects -> Executable -> IO (Either E.RuntimeError Instance)
initialize effects executable = initializeWith effects executable Map.empty

-- | Reuse already evaluated globals when linking an interactive submission.
-- Values and closures keep their original lexical environments.
initializeWith :: Effects -> Executable -> Map GlobalIndex Value -> IO (Either E.RuntimeError Instance)
initializeWith effects (Executable program functions initializers) cached = runExceptT $ do
  globals <- emptyFrame (V.length (programGlobals program))
  let env = Env [] V.empty globals functions effects
  forM_ initializers $ \(GlobalIndex slot, evaluator) -> do
    value <- maybe (evaluator env) pure (Map.lookup (GlobalIndex slot) cached)
    cell <- index (programSpan program) globals slot
    writeCell cell value
  pure (Instance env)

evaluateEntry :: Instance -> Entry -> [Value] -> IO (Either E.RuntimeError Value)
evaluateEntry (Instance env) (Entry origin (GlobalIndex slot)) arguments = runExceptT $ do
  cell <- index origin (envGlobals env) slot
  value <- readCell origin cell
  foldM (applyValueWithEffects (envEffects env) origin) value arguments

runProgram :: Effects -> Executable -> Entry -> [Value] -> IO (Either E.RuntimeError Value)
runProgram effects executable@(Executable program _ _) entry@(Entry origin (GlobalIndex slot)) arguments
  | slot < 0 || slot >= V.length (programGlobals program) = pure (Left (E.RuntimeError E.InvalidEntry origin "entry global is out of bounds"))
  | otherwise = initialize effects executable >>= either (pure . Left) (\instance' -> evaluateEntry instance' entry arguments)

-- The program must have passed validateProgram. Public execution accepts only
-- Executable, constructed from the opaque validation witness above.
compileExpr :: Program -> Expr -> Eval
compileExpr program source = case nodeValue source of
  Load address -> \env -> addressCell origin env address >>= readCell origin
  Global (GlobalIndex slot) -> \env -> index origin (envGlobals env) slot >>= readCell origin
  Literal value -> \_ -> pure (LiteralValue value)
  Closure function captures -> let !sources = strictMap nodeValue captures in \env -> makeClosure origin env function sources
  Call function arguments ->
    let !callee = compile function
        !operands = strictMap compile (NE.toList arguments)
     in \env -> do
          initial <- callee env
          foldM (\value operand -> operand env >>= applyValueWithEffects (envEffects env) origin value) initial operands
  Let binding body ->
    let !initializer = compile (bindingBody (nodeValue binding)); !rest = compile body
     in \env -> do value <- initializer env; frame <- valueFrame [value]; rest (pushFrame frame env)
  LetRec bindings body ->
    let !initializers = strictMap (compile . bindingBody . nodeValue) (NE.toList bindings); !rest = compile body
     in \env -> do
          frame <- emptyFrame (length initializers)
          let recursive = pushFrame frame env
          forM_ (zip [0 ..] initializers) $ \(slot, initializer) -> do
            value <- initializer recursive
            cell <- index origin frame slot
            writeCell cell value
          rest recursive
  Construct constructor fields -> let !operands = strictMap compile fields in \env -> Aggregate constructor . V.fromList <$> mapM ($ env) operands
  Case receiver alternatives fallback ->
    let !scrutinee = compile receiver
        !arms = strictMap (\arm -> let (test, body) = nodeValue arm; !evaluator = compile body in (test, evaluator)) alternatives
        !failure = compile fallback
        choose env _ [] = failure env
        choose env value ((test, body) : rest) = case testValue test value of
          Nothing -> choose env value rest
          Just fields -> do frame <- valueFrame fields; body (pushFrame frame env)
     in \env -> scrutinee env >>= \value -> choose env value arms
  If arms fallback ->
    let !conditions = strictMap (\arm -> let (test, body) = nodeValue arm; !condition = compile test; !result = compile body in (nodeSpan arm, condition, result)) arms
        !failure = maybe (\_ -> throwError (E.RuntimeError E.MatchFailure origin "no conditional branch matched")) compile fallback
        choose env [] = failure env
        choose env ((location, test, body) : rest) =
          test env >>= \case
            LiteralValue (Boolean True) -> body env
            LiteralValue (Boolean False) -> choose env rest
            _ -> invalidValue location "conditional requires Bool"
     in \env -> choose env conditions
  Select receiver owner field -> let !evaluate = compile receiver in \env -> evaluate env >>= selectField origin owner field
  Primitive (PrimitiveIndex ident) arguments ->
    let !operands = strictMap compile arguments
        !operation = programPrimitives program V.!? ident
     in \env -> do
          values <- mapM ($ env) operands
          maybe (invalidValue origin "unknown runtime primitive") (\primitive -> evaluatePrimitive origin (envEffects env) primitive values) operation
  MatchFailure -> \_ -> throwError (E.RuntimeError E.MatchFailure origin "pattern match failed")
  where
    origin = nodeSpan source
    compile = compileExpr program

-- Force the complete code spine and each evaluator before returning its parent
-- closure. Ordinary lazy map would defer some compilation until execution.
strictMap :: (a -> b) -> [a] -> [b]
strictMap _ [] = []
strictMap transform (first : rest) =
  let !value = transform first
      !values = strictMap transform rest
   in value : values
