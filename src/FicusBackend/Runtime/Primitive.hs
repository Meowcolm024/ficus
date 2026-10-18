module FicusBackend.Runtime.Primitive (evaluatePrimitive, ioEffects) where

import Control.Exception (IOException, try)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Int (Int64)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import Ficus.Util.Source
import FicusBackend.Runtime.AST
import FicusBackend.Runtime.Error qualified as E
import FicusBackend.Runtime.Value
import System.IO qualified as IO

ioEffects :: Effects
ioEffects = Effects write readChunk
  where
    nativeHandle StandardInput = IO.stdin
    nativeHandle StandardOutput = IO.stdout
    nativeHandle StandardError = IO.stderr
    write handle = TIO.hPutStr (nativeHandle handle)
    readChunk handle count = T.pack . reverse <$> loop (nativeHandle handle) count []
    loop handle remaining buffer
      | remaining <= 0 = pure buffer
      | otherwise = do
          ended <- IO.hIsEOF handle
          if ended
            then pure buffer
            else do
              character <- IO.hGetChar handle
              loop handle (remaining - 1) (character : buffer)

evaluatePrimitive :: Span -> Effects -> Primitive () -> [Value] -> EvalM Value
evaluatePrimitive origin effects operation arguments = case (operation, arguments) of
  (IntAdd, [LiteralValue (Integer a), LiteralValue (Integer b)]) -> integer (a + b)
  (IntSubtract, [LiteralValue (Integer a), LiteralValue (Integer b)]) -> integer (a - b)
  (IntMultiply, [LiteralValue (Integer a), LiteralValue (Integer b)]) -> integer (a * b)
  (IntDivide, [LiteralValue (Integer a), LiteralValue (Integer b)]) -> divide quot a b
  (IntRemainder, [LiteralValue (Integer a), LiteralValue (Integer b)]) -> divide rem a b
  (IntEqual, [LiteralValue (Integer a), LiteralValue (Integer b)]) -> boolean (a == b)
  (IntLess, [LiteralValue (Integer a), LiteralValue (Integer b)]) -> boolean (a < b)
  (IntShow, [LiteralValue (Integer a)]) -> string (T.pack (show a))
  (IntNegate, [LiteralValue (Integer a)]) -> integer (negate a)
  (IntToFloat, [LiteralValue (Integer a)]) -> floating (fromIntegral a)
  (FloatAdd, [LiteralValue (Floating a), LiteralValue (Floating b)]) -> floating (a + b)
  (FloatSubtract, [LiteralValue (Floating a), LiteralValue (Floating b)]) -> floating (a - b)
  (FloatMultiply, [LiteralValue (Floating a), LiteralValue (Floating b)]) -> floating (a * b)
  (FloatDivide, [LiteralValue (Floating a), LiteralValue (Floating b)]) -> floating (a / b)
  (FloatEqual, [LiteralValue (Floating a), LiteralValue (Floating b)]) -> boolean (a == b)
  (FloatLess, [LiteralValue (Floating a), LiteralValue (Floating b)]) -> boolean (a < b)
  (FloatNegate, [LiteralValue (Floating a)]) -> floating (negate a)
  (FloatShow, [LiteralValue (Floating a)]) -> string (T.pack (show a))
  (FloatToInt, [LiteralValue (Floating a)])
    | isNaN a || isInfinite a -> failure "cannot convert a non-finite float to Int"
    | otherwise ->
        let value = truncate a :: Integer
         in if value < toInteger (minBound :: Int64) || value > toInteger (maxBound :: Int64)
              then failure "float is outside the Int range"
              else integer (fromInteger value)
  (CharEqual, [LiteralValue (Character a), LiteralValue (Character b)]) -> boolean (a == b)
  (CharLess, [LiteralValue (Character a), LiteralValue (Character b)]) -> boolean (a < b)
  (CharShow, [LiteralValue (Character a)]) -> string (T.singleton a)
  (StringAppend, [LiteralValue (String a), LiteralValue (String b)]) -> string (a <> b)
  (StringEqual, [LiteralValue (String a), LiteralValue (String b)]) -> boolean (a == b)
  (StringLess, [LiteralValue (String a), LiteralValue (String b)]) -> boolean (T.unpack a < T.unpack b)
  (StringLength, [LiteralValue (String a)]) -> integer (T.foldl' (\count _ -> count + 1) 0 a)
  (StringToChars, [LiteralValue (String a)]) -> pure (listValue (map (LiteralValue . Character) (T.unpack a)))
  (CharsToString, [value]) -> do
    values <- listElements value
    characters <- mapM (\case LiteralValue (Character c) -> pure c; _ -> invalidValue origin "character list expected") values
    string (T.pack characters)
  (VecFromList (), [value]) -> VectorValue . V.fromList <$> listElements value
  (VecToList (), [VectorValue values]) -> pure (listValue (V.toList values))
  (VecLength (), [VectorValue values]) -> integer (fromIntegral (V.length values))
  (ByteFromInt (), [LiteralValue (Integer value)]) -> pure (ByteValue (fromIntegral value))
  (ByteToInt (), [ByteValue value]) -> integer (fromIntegral value)
  (Absurd (), [_]) -> failure "ABSURD received a value of the uninhabited type"
  (HandleStdin (), []) -> pure (HandleValue StandardInput)
  (HandleStdout (), []) -> pure (HandleValue StandardOutput)
  (HandleStderr (), []) -> pure (HandleValue StandardError)
  (HandleRead (), [HandleValue StandardInput, LiteralValue (Integer count)])
    | count <= 0 -> string ""
    | otherwise -> io (readHandle effects StandardInput count) >>= string
  (HandleRead (), [HandleValue _, LiteralValue (Integer _)]) -> failure "handle is not readable"
  (HandleWrite (), [HandleValue handle, LiteralValue (String value)]) -> case handle of
    StandardInput -> failure "handle is not writable"
    _ -> io (writeHandle effects handle value) >> pure (LiteralValue Unit)
  _ -> invalidValue origin "primitive operands do not match its contract"
  where
    integer = pure . LiteralValue . Integer
    floating = pure . LiteralValue . Floating
    boolean = pure . LiteralValue . Boolean
    string = pure . LiteralValue . String
    failure :: T.Text -> EvalM a
    failure = throwError . E.RuntimeError E.PrimitiveFailure origin
    divide operation' a b
      | b == 0 = failure "integer division by zero"
      | otherwise = integer (fromInteger (operation' (toInteger a) (toInteger b)))
    io :: IO a -> EvalM a
    io action = do
      result <- liftIO (try action)
      either (\(exception :: IOException) -> failure (T.pack (show exception))) pure result
    listElements = go []
      where
        go accumulated (Aggregate tag values)
          | tag == nilConstructor && V.null values = pure (reverse accumulated)
          | tag == consConstructor, [first, rest] <- V.toList values = go (first : accumulated) rest
        go _ _ = invalidValue origin "list representation expected"
    listValue = foldr (\first rest -> Aggregate consConstructor (V.fromList [first, rest])) (Aggregate nilConstructor V.empty)
