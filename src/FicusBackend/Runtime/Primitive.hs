module FicusBackend.Runtime.Primitive (evaluatePrimitive, ioEffects) where

import Control.Exception (IOException, bracketOnError, try)
import Control.Monad.Except (catchError, throwError)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import Ficus.Primitive.Registry qualified as P
import FicusBackend.Runtime.AST
import FicusBackend.Runtime.Value
import System.IO qualified as IO

ioEffects :: Effects
ioEffects = Effects write readChunk
  where
    nativeHandle StandardInput = IO.stdin
    nativeHandle StandardOutput = IO.stdout
    nativeHandle StandardError = IO.stderr
    write handle = TIO.hPutStr (nativeHandle handle)
    readChunk handle count = readFileChunk (nativeHandle handle) count

readFileChunk :: IO.Handle -> Int64 -> IO T.Text
readFileChunk handle count = T.pack . reverse <$> loop handle count []
  where
    loop handle' remaining buffer
      | remaining <= 0 = pure buffer
      | otherwise = do
          ended <- IO.hIsEOF handle'
          if ended
            then pure buffer
            else do
              character <- IO.hGetChar handle'
              loop handle' (remaining - 1) (character : buffer)

evaluatePrimitive :: Map P.PrimitiveError ErrorConstructor -> Map ConstructorIndex P.FileMode -> Maybe SomeExceptionLayout -> (GlobalIndex -> EvalM Value) -> T.Text -> Effects -> Primitive () -> [Value] -> EvalM Value
evaluatePrimitive errors modes packageLayout loadGlobal origin effects operation arguments = case (operation, arguments) of
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
    | isNaN a || isInfinite a -> conversion "cannot convert a non-finite float to Int"
    | otherwise ->
        let value = truncate a :: Integer
         in if value < toInteger (minBound :: Int64) || value > toInteger (maxBound :: Int64)
              then conversion "float is outside the Int range"
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
    characters <- mapM (\case LiteralValue (Character c) -> pure c; _ -> invalidValue "character list expected") values
    string (T.pack characters)
  (VecFromList (), [value]) -> VectorValue . V.fromList <$> listElements value
  (VecToList (), [VectorValue values]) -> pure (listValue (V.toList values))
  (VecLength (), [VectorValue values]) -> integer (fromIntegral (V.length values))
  (ByteFromInt (), [LiteralValue (Integer value)]) -> pure (ByteValue (fromIntegral value))
  (ByteToInt (), [ByteValue value]) -> integer (fromIntegral value)
  (MatchFailure, [LiteralValue (String message)]) -> typedFailure P.MatchError message [LiteralValue (String message)]
  (Throw (), [dictionary, value]) -> throwException dictionary value
  (Catch (), [dictionary, action, handler]) -> do
    (expected, _) <- exceptionParts dictionary
    catchError (applyValueWithEffects effects action (LiteralValue Unit)) $ \case
      Thrown actual value evidence _
        | Just layout <- packageLayout,
          expected == ExceptionToken (someExceptionIdentity layout) [] -> do
            packaged <- packageException layout value evidence
            applyValueWithEffects effects handler packaged
        | expected == actual -> applyValueWithEffects effects handler value
      failure' -> throwError failure'
  (RefNew (), [value]) -> RefValue <$> liftIO (newIORef value)
  (RefRead (), [RefValue cell]) -> liftIO (readIORef cell)
  (RefModify (), [RefValue cell, update]) -> do
    previous <- liftIO (readIORef cell)
    updated <- applyValueWithEffects effects update previous
    liftIO (writeIORef cell updated)
    pure (LiteralValue Unit)
  (HandleOpenFile () (), [LiteralValue (String path), Aggregate tag fields]) | V.null fields -> do
    mode <- maybe (invalidValue "unknown IO mode constructor") pure (Map.lookup tag modes)
    let nativeMode = case mode of P.ReadMode -> IO.ReadMode; P.WriteMode -> IO.WriteMode; P.AppendMode -> IO.AppendMode; P.ReadWriteMode -> IO.ReadWriteMode
    handle <- io "openFile" $ bracketOnError (IO.openFile (T.unpack path) nativeMode) IO.hClose $ \handle -> do
      IO.hSetEncoding handle IO.utf8
      IO.hSetNewlineMode handle IO.noNewlineTranslation
      pure handle
    pure (FileHandleValue handle)
  (HandleClose (), [FileHandleValue handle]) -> io "close" (IO.hClose handle) >> pure (LiteralValue Unit)
  (HandleClose (), [HandleValue _]) -> ioFailure "close" "cannot close a standard handle"
  (HandleRead (), [FileHandleValue handle, LiteralValue (Integer count)])
    | count <= 0 -> string ""
    | otherwise -> io "read" (readFileChunk handle count) >>= string
  (HandleWrite (), [FileHandleValue handle, LiteralValue (String value)]) -> io "write" (TIO.hPutStr handle value) >> pure (LiteralValue Unit)
  (HandleStdin (), []) -> pure (HandleValue StandardInput)
  (HandleStdout (), []) -> pure (HandleValue StandardOutput)
  (HandleStderr (), []) -> pure (HandleValue StandardError)
  (HandleRead (), [HandleValue StandardInput, LiteralValue (Integer count)])
    | count <= 0 -> string ""
    | otherwise -> io "read" (readHandle effects StandardInput count) >>= string
  (HandleRead (), [HandleValue _, LiteralValue (Integer _)]) -> ioFailure "read" "handle is not readable"
  (HandleWrite (), [HandleValue handle, LiteralValue (String value)]) -> case handle of
    StandardInput -> ioFailure "write" "handle is not writable"
    _ -> io "write" (writeHandle effects handle value) >> pure (LiteralValue Unit)
  _ -> invalidValue "primitive operands do not match its contract"
  where
    integer = pure . LiteralValue . Integer
    floating = pure . LiteralValue . Floating
    boolean = pure . LiteralValue . Boolean
    string = pure . LiteralValue . String
    typedFailure :: P.PrimitiveError -> T.Text -> [Value] -> EvalM a
    typedFailure kind message fields = case Map.lookup kind errors of
      Nothing -> invalidValue "missing primitive error association"
      Just (ErrorConstructor identity representation evidenceGlobal) -> do
        payload <- case representation of
          Just tag -> pure (Aggregate tag (V.fromList fields))
          Nothing -> case fields of [value] -> pure value; _ -> invalidValue "invalid erased error constructor"
        evidence <- traverse loadGlobal evidenceGlobal
        throwError (Thrown (ExceptionToken identity []) payload evidence (origin <> message <> ": "))
    exceptionParts dictionary = case dictionary of
      Aggregate _ fields | V.length fields == 2 -> do
        display <- index fields 0
        identity <- index fields 1
        case (display, identity) of
          (Aggregate _ methods, TokenValue token) | V.length methods == 1 -> (token,) <$> index methods 0
          _ -> invalidValue "invalid exception rendering evidence"
      _ -> invalidValue "exception dictionary expected"
    packageException layout value evidence = do
      dictionary <- maybe (invalidValue "missing primitive exception rendering evidence") pure evidence
      (_, renderer) <- exceptionParts dictionary
      let FieldIndex valueSlot = someExceptionValue layout
          FieldIndex renderSlot = someExceptionRenderer layout
          payload = V.generate 3 (\slot -> if slot == 0 then dictionary else if slot == valueSlot then value else renderer)
      if valueSlot == renderSlot || valueSlot < 1 || renderSlot < 1 || valueSlot > 2 || renderSlot > 2
        then invalidValue "invalid SomeException layout"
        else pure (Aggregate (someExceptionConstructor layout) payload)
    throwException dictionary value = do
      (token, _) <- exceptionParts dictionary
      case (packageLayout, value) of
        (Just layout, Aggregate tag fields)
          | token == ExceptionToken (someExceptionIdentity layout) [] && tag == someExceptionConstructor layout -> do
              underlying <- index fields 0
              let FieldIndex valueSlot = someExceptionValue layout
                  FieldIndex renderSlot = someExceptionRenderer layout
              payload <- index fields valueSlot
              renderer <- index fields renderSlot
              case underlying of
                Aggregate evidenceTag evidenceFields -> do
                  display <- index evidenceFields 0
                  identity <- index evidenceFields 1
                  case display of
                    Aggregate displayTag _ -> throwException (Aggregate evidenceTag (V.fromList [Aggregate displayTag (V.singleton renderer), identity])) payload
                    _ -> invalidValue "invalid packaged exception renderer"
                _ -> invalidValue "invalid packaged exception evidence"
        _ -> throwError (Thrown token value (Just dictionary) origin)
    conversion message = typedFailure P.InvalidConversionError message [LiteralValue (String message)]
    ioFailure :: T.Text -> T.Text -> EvalM a
    ioFailure operation' message = typedFailure P.IOError (operation' <> ": " <> message) [LiteralValue (String operation'), LiteralValue (String message)]
    divide operation' a b
      | b == 0 = typedFailure P.DivisionByZeroError "integer division by zero" []
      | otherwise = integer (fromInteger (operation' (toInteger a) (toInteger b)))
    io :: T.Text -> IO a -> EvalM a
    io operation' action = do
      result <- liftIO (try action)
      either (\(exception :: IOException) -> ioFailure operation' (T.pack (show exception))) pure result
    listElements = go []
      where
        go accumulated (Aggregate tag values)
          | tag == nilConstructor && V.null values = pure (reverse accumulated)
          | tag == consConstructor, [first, rest] <- V.toList values = go (first : accumulated) rest
        go _ _ = invalidValue "list representation expected"
    listValue = foldr (\first rest -> Aggregate consConstructor (V.fromList [first, rest])) (Aggregate nilConstructor V.empty)
