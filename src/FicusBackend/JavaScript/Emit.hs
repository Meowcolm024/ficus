-- | Emit executable JavaScript statements from checked block ANF. The output
-- contains code and numeric layouts, not a serialized AST interpreter.
module FicusBackend.JavaScript.Emit (emitProgram, stringLiteral) where

import Control.Monad.State.Strict (State, evalState, get, put)
import Data.Char (ord)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Ficus.Primitive.Registry qualified as P
import FicusBackend.Pass.Normalize
import FicusBackend.Runtime.AST
import FicusBackend.Runtime.Validate
import Numeric (showHex)

number :: (Show a) => a -> Text
number = T.pack . show

stringLiteral :: Text -> Text
stringLiteral value = "\"" <> T.concatMap escape value <> "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape character
      | ord character < 32 || character == '\x2028' || character == '\x2029' = let hex = T.pack (showHex (ord character) "") in "\\u" <> T.replicate (4 - T.length hex) "0" <> hex
      | otherwise = T.singleton character

array :: [Text] -> Text
array values = "[" <> T.intercalate "," values <> "]"

literal :: RuntimeLiteral -> Text
literal value = case value of
  Integer integer -> number integer <> "n"
  Floating float
    | isNaN float -> "NaN"
    | isInfinite float -> if float < 0 then "-Infinity" else "Infinity"
    | otherwise -> number float
  Character character -> stringLiteral (T.singleton character)
  String text -> stringLiteral text
  Boolean boolean -> if boolean then "true" else "false"
  Unit -> "null"

fresh :: State Int Text
fresh = do
  ident <- get
  put (ident + 1)
  pure ("v" <> number ident)

type Code = ([Text], Text)

assign :: Text -> State Int Code
assign value = do
  name <- fresh
  pure (["const " <> name <> "=" <> value <> ";"], name)

address :: Text -> Address -> Text
address env value = case value of
  Local (FrameDepth depth) (SlotIndex slot) -> env <> ".frames[" <> number depth <> "][" <> number slot <> "]"
  Capture (CaptureIndex slot) -> env <> ".captures[" <> number slot <> "]"

emit :: Program -> Text -> Expr -> State Int Code
emit program env expression = case nodeValue expression of
  Load location -> assign ("readCell(" <> address env location <> ")")
  Global (GlobalIndex slot) -> assign ("readCell(g[" <> number slot <> "])")
  Literal value -> assign (literal value)
  Closure (FunctionIndex ident) captures -> assign ("closure(functions[" <> number ident <> "],arities[" <> number ident <> "]," <> array (map (address env . nodeValue) captures) <> ")")
  Call function arguments -> do
    initial <- recurse function
    foldl
      ( \accumulated argument -> do
          (before, callee) <- accumulated
          (operand, actual) <- recurse argument
          (call, result) <- assign ("apply(" <> callee <> "," <> actual <> ")")
          pure (before ++ operand ++ call, result)
      )
      (pure initial)
      arguments
  TailCall function argument -> operation "transfer" [function, argument]
  Let binding body -> do
    (initializer, value) <- recurse (bindingBody (nodeValue binding))
    (frame, inner) <- assign ("push(" <> env <> ",[cell(" <> value <> ")])")
    (rest, result) <- emit program inner body
    pure (initializer ++ frame ++ rest, result)
  LetRec bindings body -> do
    (frame, inner) <- assign ("push(" <> env <> ",Array.from({length:" <> number (NE.length bindings) <> "},()=>cell(undefined)))")
    initializers <-
      mapM
        ( \(slot, binding) -> do
            (code, value) <- emit program inner (bindingBody (nodeValue binding))
            pure (code ++ [inner <> ".frames[0][" <> number slot <> "].value=" <> value <> ";"])
        )
        (zip [0 :: Int ..] (NE.toList bindings))
    (rest, result) <- emit program inner body
    pure (frame ++ concat initializers ++ rest, result)
  Construct (ConstructorIndex tag) fields -> fieldsOperation "aggregate" tag fields
  TypeToken (ConstructorIndex tag) fields -> fieldsOperation "token" tag fields
  Select receiver (ConstructorIndex tag) (FieldIndex field) -> do
    (code, value) <- recurse receiver
    (selection, result) <- assign ("select(" <> value <> "," <> number tag <> "," <> number field <> ")")
    pure (code ++ selection, result)
  Primitive (PrimitiveIndex ident) arguments context -> do
    (code, values) <- operands arguments
    -- Validation guarantees the table lookup. Keep an invalid opcode explicit
    -- for defensive handling rather than inventing a different operation.
    let opcode = maybe (-1) (maybe (-1) id . P.primitiveIndex) (programPrimitives program V.!? ident)
    (call, result) <- assign ("primitive(" <> number opcode <> "," <> array values <> "," <> stringLiteral context <> ",errors,modes,packaged,g)")
    pure (code ++ call, result)
  Case receiver alternatives fallback -> do
    (code, value) <- recurse receiver
    result <- fresh
    branches <- choose value result alternatives
    pure (code ++ ["let " <> result <> ";"] ++ branches, result)
    where
      choose _ result [] = do
        (code, value) <- recurse fallback
        pure (code ++ [result <> "=" <> value <> ";"])
      choose value result (alternative : rest) = do
        let (test, body) = nodeValue alternative
            (condition, fields) = case test of
              LiteralTest expected -> (value <> "===" <> literal expected, "[]")
              ConstructorTest (ConstructorIndex tag) _ -> (value <> "!==null&&" <> value <> ".tag===" <> number tag, value <> ".fields")
        (frame, inner) <- assign ("push(" <> env <> "," <> fields <> ".map(cell))")
        (code, selected) <- emit program inner body
        other <- choose value result rest
        pure (["if(" <> condition <> "){"] ++ frame ++ code ++ [result <> "=" <> selected <> ";", "}else{"] ++ other ++ ["}"])
  If arms fallback -> do
    result <- fresh
    branches <- choose result arms
    pure (["let " <> result <> ";"] ++ branches, result)
    where
      choose result [] = do
        (code, value) <- recurse fallback
        pure (code ++ [result <> "=" <> value <> ";"])
      choose result (arm : rest) = do
        let (condition, body) = nodeValue arm
        (test, boolean) <- recurse condition
        (code, selected) <- recurse body
        other <- choose result rest
        pure (test ++ ["if(" <> boolean <> "){"] ++ code ++ [result <> "=" <> selected <> ";", "}else{"] ++ other ++ ["}"])
  where
    recurse = emit program env
    operands values = do
      results <- mapM recurse values
      pure (concatMap fst results, map snd results)
    operation name arguments = do
      (code, values) <- operands arguments
      (call, result) <- assign (name <> "(" <> T.intercalate "," values <> ")")
      pure (code ++ call, result)
    fieldsOperation name tag fields = do
      (code, values) <- operands fields
      (call, result) <- assign (name <> "(" <> number tag <> "," <> array values <> ")")
      pure (code ++ call, result)

-- | Prepend runtime/javascript.mjs to make this an executable ES module.
-- Each createProgram call initializes independent global cells and references.
emitProgram :: NormalizedProgram -> Text
emitProgram checked = T.unlines (evalState generate 0)
  where
    program = validatedProgram (normalizedProgram checked)
    generate = do
      functions <-
        mapM
          ( \function -> do
              (code, value) <- emit program "e" (functionBody (nodeValue function))
              pure (T.unlines (["function(e){"] ++ code ++ ["return " <> value <> ";", "}"]))
          )
          (V.toList (programFunctions program))
      initializers <-
        mapM
          ( \(GlobalIndex slot, binding) -> do
              (code, value) <- emit program "e" (bindingBody (nodeValue binding))
              pure (code ++ ["g[" <> number slot <> "].value=" <> value <> ";"])
          )
          [(ident, binding) | group <- programInitialization program, (ident, binding) <- NE.toList (groupBindings (nodeValue group))]
      pure
        ( [ "const op={" <> T.intercalate "," [T.takeWhile (/= ' ') (number primitive') <> ":" <> number index | (index, primitive') <- zip [0 :: Int ..] P.allPrimitives] <> "};",
            "export function createProgram(){",
            "const g=Array.from({length:" <> number (programGlobalCount program) <> "},()=>cell(undefined));",
            "const e={frames:[],captures:[]};",
            "const arities=" <> array [number arity | function <- V.toList (programFunctions program), let { Arity arity = functionArity (nodeValue function) }] <> ";",
            "const errors={" <> T.intercalate "," [number (errorIndex kind) <> ":" <> array [number identity, maybe "null" (\(ConstructorIndex tag) -> number tag) representation, maybe "null" (\(GlobalIndex index) -> number index) evidence] | (kind, ErrorConstructor (ConstructorIndex identity) representation evidence) <- Map.toList (programErrors program)] <> "};",
            "const modes={" <> T.intercalate "," [number tag <> ":" <> stringLiteral (modeName mode) | (ConstructorIndex tag, mode) <- Map.toList (programFileModes program)] <> "};",
            "const packaged=" <> maybe "null" package (programSomeException program) <> ";",
            "const functions=" <> array functions <> ";"
          ]
            ++ concat initializers
            ++ ["return function(entry,args){let value=readCell(g[entry]);for(const arg of args)value=apply(value,arg);return value;};", "}"]
        )
    errorIndex :: P.PrimitiveError -> Int
    errorIndex = \case P.DivisionByZeroError -> 0; P.InvalidConversionError -> 1; P.IOError -> 2; P.MatchError -> 3
    modeName = \case P.ReadMode -> "r"; P.WriteMode -> "w"; P.AppendMode -> "a"; P.ReadWriteMode -> "r+"
    package layout = let ConstructorIndex identity = someExceptionIdentity layout; ConstructorIndex tag = someExceptionConstructor layout; FieldIndex value = someExceptionValue layout; FieldIndex renderer = someExceptionRenderer layout in "{identity:" <> number identity <> ",tag:" <> number tag <> ",value:" <> number value <> ",renderer:" <> number renderer <> "}"
