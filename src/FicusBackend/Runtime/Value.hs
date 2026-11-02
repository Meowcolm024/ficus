module FicusBackend.Runtime.Value where

import Control.Monad.Except (ExceptT, runExceptT, throwError)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Data.Word (Word8)
import FicusBackend.Runtime.AST
import FicusBackend.Runtime.Error qualified as E
import System.IO qualified as IO

-- Typed throws remain distinct until the public execution boundary.
data EvaluationError = RuntimeFailure E.RuntimeError | Thrown ExceptionToken Value (Maybe Value) Text

data ExceptionToken = ExceptionToken ConstructorIndex [ExceptionToken] deriving (Eq, Show)

type EvalM = ExceptT EvaluationError IO

runEvaluation :: EvalM a -> IO (Either E.RuntimeError a)
runEvaluation action = fmap (either (Left . report) Right) (runExceptT action)
  where
    report (RuntimeFailure failure) = failure
    report (Thrown _ _ _ context) = E.RuntimeError (context <> "uncaught exception")

raiseRuntime :: Text -> EvalM a
raiseRuntime = throwError . RuntimeFailure . E.RuntimeError

makeTypeToken :: ConstructorIndex -> [Value] -> EvalM Value
makeTypeToken ident arguments = TokenValue . ExceptionToken ident <$> mapM token arguments
  where
    token (TokenValue value) = pure value
    token _ = invalidValue "exception identity requires token evidence"

type Eval = Env -> EvalM Value

type Cell = IORef (Maybe Value)

type Frame = Vector Cell

-- Embedders supply effects; IOException conversion belongs to primitives.
data StandardHandle = StandardInput | StandardOutput | StandardError deriving (Eq, Ord, Show)

data Effects = Effects
  { writeHandle :: StandardHandle -> Text -> IO (),
    readHandle :: StandardHandle -> Int64 -> IO Text
  }

data Env = Env
  { envFrames :: [Frame],
    envCaptures :: Vector Cell,
    envGlobals :: Vector Cell,
    envFunctions :: Vector FunctionCode,
    envEffects :: Effects
  }

-- Control transfers are separate from language values and never escape an
-- evaluation boundary. Legacy evaluator closures remain usable by embedders.
data Step = Done Value | Transfer Effects Value Value

data FunctionCode = FunctionCode Arity Eval | TailFunctionCode Arity (Env -> EvalM Step)

codeArity :: FunctionCode -> Arity
codeArity (FunctionCode arity _) = arity
codeArity (TailFunctionCode arity _) = arity

codeBody :: FunctionCode -> Eval
codeBody code env = enterCode code env >>= finishStep

enterCode :: FunctionCode -> Env -> EvalM Step
enterCode (FunctionCode _ body) env = Done <$> body env
enterCode (TailFunctionCode _ body) env = body env

finishStep :: Step -> EvalM Value
finishStep (Done value) = pure value
finishStep (Transfer effects function argument) = applyStep effects function argument >>= finishStep

data ClosureValue = ClosureValue
  { closureCode :: FunctionCode,
    closureEnvironment :: Env,
    closureArguments :: Vector Value
  }

data Value = TokenValue ExceptionToken | LiteralValue RuntimeLiteral | Aggregate ConstructorIndex (Vector Value) | VectorValue (Vector Value) | ByteValue Word8 | HandleValue StandardHandle | FileHandleValue IO.Handle | RefValue (IORef Value) | FunctionValue ClosureValue

-- Closures and mutable references are observed opaquely; inspecting a value
-- neither reads a cell nor recursively follows potentially cyclic references.
data Observation = TokenObservation ExceptionToken | LiteralObservation RuntimeLiteral | AggregateObservation ConstructorIndex [Observation] | VectorObservation [Observation] | ByteObservation Word8 | HandleObservation StandardHandle | FileHandleObservation | RefObservation | FunctionObservation Arity Int
  deriving (Eq, Show)

observe :: Value -> Observation
observe value = case value of
  TokenValue token -> TokenObservation token
  LiteralValue literal -> LiteralObservation literal
  Aggregate tag fields -> AggregateObservation tag (map observe (V.toList fields))
  VectorValue fields -> VectorObservation (map observe (V.toList fields))
  ByteValue byte -> ByteObservation byte
  HandleValue handle -> HandleObservation handle
  FileHandleValue _ -> FileHandleObservation
  RefValue _ -> RefObservation
  FunctionValue closure -> FunctionObservation (codeArity (closureCode closure)) (V.length (closureArguments closure))

invalidValue :: Text -> EvalM a
invalidValue = raiseRuntime

index :: Vector a -> Int -> EvalM a
index entries slot = maybe (invalidValue "runtime index is out of bounds") pure (entries V.!? slot)

addressCell :: Env -> Address -> EvalM Cell
addressCell env address = case address of
  Capture (CaptureIndex slot) -> index (envCaptures env) slot
  Local (FrameDepth depth) (SlotIndex slot) -> case drop depth (envFrames env) of
    frame : _ | depth >= 0 -> index frame slot
    _ -> invalidValue "lexical frame is out of bounds"

readCell :: Cell -> EvalM Value
readCell cell = liftIO (readIORef cell) >>= maybe (raiseRuntime "recursive value read before initialization") pure

valueFrame :: [Value] -> EvalM Frame
valueFrame = liftIO . V.mapM (newIORef . Just) . V.fromList

emptyFrame :: Int -> EvalM Frame
emptyFrame count = liftIO (V.replicateM count (newIORef Nothing))

writeCell :: Cell -> Value -> EvalM ()
writeCell cell value = liftIO (writeIORef cell (Just value))

pushFrame :: Frame -> Env -> Env
pushFrame frame env = env {envFrames = frame : envFrames env}

makeClosure :: Env -> FunctionIndex -> [Address] -> EvalM Value
makeClosure env (FunctionIndex ident) sources = do
  code <- index (envFunctions env) ident
  captures <- V.fromList <$> mapM (addressCell env) sources
  pure (FunctionValue (ClosureValue code (env {envFrames = [], envCaptures = captures}) V.empty))

applyValue :: Value -> Value -> EvalM Value
applyValue function argument = case function of
  FunctionValue closure -> applyValueWithEffects (envEffects (closureEnvironment closure)) function argument
  _ -> invalidValue "application requires a function"

-- Retained closures keep lexical cells and code; effects belong to this call.
applyValueWithEffects :: Effects -> Value -> Value -> EvalM Value
applyValueWithEffects effects function argument = applyStep effects function argument >>= finishStep

applyStep :: Effects -> Value -> Value -> EvalM Step
applyStep effects function argument = case function of
  FunctionValue closure -> do
    let arguments = V.snoc (closureArguments closure) argument
        code = closureCode closure
        Arity arity = codeArity code
        environment = (closureEnvironment closure) {envEffects = effects}
    if V.length arguments < arity
      then pure (Done (FunctionValue closure {closureArguments = arguments, closureEnvironment = environment}))
      else
        if V.length arguments == arity
          then do
            frame <- valueFrame (V.toList arguments)
            enterCode code (pushFrame frame environment)
          else invalidValue "closure received too many stored arguments"
  _ -> invalidValue "application requires a function"

selectField :: ConstructorIndex -> FieldIndex -> Value -> EvalM Value
selectField owner (FieldIndex field) value = case value of
  Aggregate actual fields | owner == actual -> index fields field
  _ -> invalidValue "selection requires the expected aggregate"

testValue :: CaseTest -> Value -> Maybe [Value]
testValue test value = case (test, value) of
  (LiteralTest expected, LiteralValue actual) | expected == actual -> Just []
  (ConstructorTest expected (FrameSize size), Aggregate actual fields) | expected == actual && size == V.length fields -> Just (V.toList fields)
  _ -> Nothing
