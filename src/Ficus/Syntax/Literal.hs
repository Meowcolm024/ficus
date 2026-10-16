module Ficus.Syntax.Literal where

import Data.Text (Text)

-- Numeric tokens retain their exact decimal spelling; range/conversion policy
-- belongs to elaboration. Character/string escapes are decoded by resolution.
data Literal = IntegerLiteral Text | FloatLiteral Text | CharacterLiteral Char | StringLiteral Text
  deriving (Eq, Show)
