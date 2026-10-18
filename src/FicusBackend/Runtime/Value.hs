module FicusBackend.Runtime.Value where

import Control.Monad.Except (ExceptT, throwError)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Data.Word (Word8)
import Ficus.Util.Source
import FicusBackend.Runtime.AST
import FicusBackend.Runtime.Error qualified as E

type EvalM = ExceptT E.RuntimeError IO

type Eval = Env -> EvalM Value

type Cell = IORef (Maybe Value)

type Frame = Vector Cell

-- Embedders supply effects; IOException conversion belongs to primitives.
data Effects = Effects {writeOutput :: Text -> IO (), readInput :: IO Text}

data Env = Env
  { envFrames :: [Frame],
    envCaptures :: Vector Cell,
    envGlobals :: Vector Cell,
    envFunctions :: Vector FunctionCode,
    envEffects :: Effects
  }

data FunctionCode = FunctionCode {codeArity :: Arity, codeBody :: Eval}

data ClosureValue = ClosureValue
  { closureCode :: FunctionCode,
    closureEnvironment :: Env,
    closureArguments :: Vector Value
  }

data Value = LiteralValue RuntimeLiteral | Aggregate ConstructorIndex (Vector Value) | VectorValue (Vector Value) | ByteValue Word8 | FunctionValue ClosureValue

-- Inspection deliberately does not pretend host closures have equality.
data Observation = LiteralObservation RuntimeLiteral | AggregateObservation ConstructorIndex [Observation] | VectorObservation [Observation] | ByteObservation Word8 | FunctionObservation Arity Int
  deriving (Eq, Show)

observe :: Value -> Observation
observe value = case value of
  LiteralValue literal -> LiteralObservation literal
  Aggregate tag fields -> AggregateObservation tag (map observe (V.toList fields))
  VectorValue fields -> VectorObservation (map observe (V.toList fields))
  ByteValue byte -> ByteObservation byte
  FunctionValue closure -> FunctionObservation (codeArity (closureCode closure)) (V.length (closureArguments closure))

invalidValue :: Span -> Text -> EvalM a
invalidValue origin = throwError . E.RuntimeError E.InvalidValue origin

index :: Span -> Vector a -> Int -> EvalM a
index origin entries slot = maybe (invalidValue origin "runtime index is out of bounds") pure (entries V.!? slot)

addressCell :: Span -> Env -> Address -> EvalM Cell
addressCell origin env address = case address of
  Capture (CaptureIndex slot) -> index origin (envCaptures env) slot
  Local (FrameDepth depth) (SlotIndex slot) -> case drop depth (envFrames env) of
    frame : _ | depth >= 0 -> index origin frame slot
    _ -> invalidValue origin "lexical frame is out of bounds"

readCell :: Span -> Cell -> EvalM Value
readCell origin cell = liftIO (readIORef cell) >>= maybe (throwError (E.RuntimeError E.UninitializedRead origin "recursive value read before initialization")) pure

valueFrame :: [Value] -> EvalM Frame
valueFrame = liftIO . V.mapM (newIORef . Just) . V.fromList

emptyFrame :: Int -> EvalM Frame
emptyFrame count = liftIO (V.replicateM count (newIORef Nothing))

writeCell :: Cell -> Value -> EvalM ()
writeCell cell value = liftIO (writeIORef cell (Just value))

pushFrame :: Frame -> Env -> Env
pushFrame frame env = env {envFrames = frame : envFrames env}

makeClosure :: Span -> Env -> FunctionIndex -> [Address] -> EvalM Value
makeClosure origin env (FunctionIndex ident) sources = do
  code <- index origin (envFunctions env) ident
  captures <- V.fromList <$> mapM (addressCell origin env) sources
  pure (FunctionValue (ClosureValue code (env {envFrames = [], envCaptures = captures}) V.empty))

applyValue :: Span -> Value -> Value -> EvalM Value
applyValue origin function argument = case function of
  FunctionValue closure -> do
    let arguments = V.snoc (closureArguments closure) argument
        code = closureCode closure
        Arity arity = codeArity code
    if V.length arguments < arity
      then pure (FunctionValue closure {closureArguments = arguments})
      else
        if V.length arguments == arity
          then do
            frame <- valueFrame (V.toList arguments)
            codeBody code (pushFrame frame (closureEnvironment closure))
          else invalidValue origin "closure received too many stored arguments"
  _ -> invalidValue origin "application requires a function"

selectField :: Span -> ConstructorIndex -> FieldIndex -> Value -> EvalM Value
selectField origin owner (FieldIndex field) value = case value of
  Aggregate actual fields | owner == actual -> index origin fields field
  _ -> invalidValue origin "selection requires the expected aggregate"

testValue :: CaseTest -> Value -> Maybe [Value]
testValue test value = case (test, value) of
  (LiteralTest expected, LiteralValue actual) | expected == actual -> Just []
  (ConstructorTest expected (FrameSize size), Aggregate actual fields) | expected == actual && size == V.length fields -> Just (V.toList fields)
  _ -> Nothing
