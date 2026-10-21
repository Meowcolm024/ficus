-- | Untyped, addressed runtime syntax. Only explicit error operations carry
-- source context, embedded in their message payloads.
module FicusBackend.Runtime.AST (module FicusBackend.Runtime.AST, Primitive (..)) where

import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Vector (Vector)
import Ficus.Primitive.Registry (Primitive (..))
import Ficus.Primitive.Registry qualified as P

newtype FrameDepth = FrameDepth Int deriving (Eq, Ord, Show)

newtype SlotIndex = SlotIndex Int deriving (Eq, Ord, Show)

newtype CaptureIndex = CaptureIndex Int deriving (Eq, Ord, Show)

newtype GlobalIndex = GlobalIndex Int deriving (Eq, Ord, Show)

newtype FunctionIndex = FunctionIndex Int deriving (Eq, Ord, Show)

newtype ConstructorIndex = ConstructorIndex Int deriving (Eq, Ord, Show)

newtype PrimitiveIndex = PrimitiveIndex Int deriving (Eq, Ord, Show)

newtype FieldIndex = FieldIndex Int deriving (Eq, Ord, Show)

newtype Arity = Arity Int deriving (Eq, Ord, Show)

newtype FrameSize = FrameSize Int deriving (Eq, Ord, Show)

newtype CaptureLayout = CaptureLayout Int deriving (Eq, Show)

newtype Node a = Node {nodeValue :: a}
  deriving (Eq, Show, Functor, Foldable, Traversable)

data Address = Local FrameDepth SlotIndex | Capture CaptureIndex deriving (Eq, Ord, Show)

data RuntimeLiteral = Integer Int64 | Floating Double | Character Char | String Text | Boolean Bool | Unit deriving (Eq, Show)

data ParameterRole = ValueParameter | EvidenceParameter deriving (Eq, Show)

type Expr = Node ExprF

type Binding = Node BindingF

type Alternative = Node (CaseTest, Expr)

type Function = Node FunctionF

data ExprF
  = Load Address
  | Global GlobalIndex
  | Literal RuntimeLiteral
  | Closure FunctionIndex [Node Address]
  | Call Expr (NonEmpty Expr)
  | Let Binding Expr
  | LetRec (NonEmpty Binding) Expr
  | Construct ConstructorIndex [Expr]
  | TypeToken ConstructorIndex [Expr]
  | Case Expr [Alternative] Expr
  | If [Node (Expr, Expr)] Expr
  | Select Expr ConstructorIndex FieldIndex
  | Primitive PrimitiveIndex [Expr] Text
  | Raise Text
  deriving (Eq, Show)

data CaseTest = ConstructorTest ConstructorIndex FrameSize | LiteralTest RuntimeLiteral deriving (Eq, Show)

-- Source classification survives erasure, including erased projections and
-- generated evidence calls which cannot be reclassified from untyped syntax.
data BindingF = Binding {bindingBody :: Expr, bindingExpansive :: Bool} deriving (Eq, Show)

data FunctionF = Function
  { functionArity :: Arity,
    functionFrameSize :: FrameSize,
    functionCaptures :: CaptureLayout,
    functionParameters :: Vector ParameterRole,
    functionBody :: Expr
  }
  deriving (Eq, Show)

data GlobalGroup = GlobalGroup {groupRecursive :: Bool, groupBindings :: NonEmpty (GlobalIndex, Binding)} deriving (Eq, Show)

newtype ConstructorLayout = ConstructorLayout {constructorFields :: FrameSize} deriving (Eq, Show)

-- These tags are reserved in every program so primitive list conversion and
-- ordinary construction share one representation.
nilConstructor, consConstructor, pairConstructor :: ConstructorIndex
nilConstructor = ConstructorIndex 0
consConstructor = ConstructorIndex 1
pairConstructor = ConstructorIndex 2

primitiveArity :: Primitive nominal -> Arity
primitiveArity = Arity . P.primitiveArity

data Program = Program
  { programFunctions :: Vector Function,
    programGlobalCount :: Int,
    programConstructors :: Vector (Node ConstructorLayout),
    programPrimitives :: Vector (Primitive ()),
    programInitialization :: [Node GlobalGroup]
  }
  deriving (Eq, Show)
