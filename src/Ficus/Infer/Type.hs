-- | Solver-owned variables are deliberately separate from resolved source IDs.
module Ficus.Infer.Type where

import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Syntax.Name (GlobalId, ImplementationId, NodeId)
import Ficus.Type

newtype MetaId = MetaId Int deriving (Eq, Ord, Show)

newtype SkolemId = SkolemId Int deriving (Eq, Ord, Show)

data InferVariable = Meta MetaId | Skolem SkolemId | Bound BoundId deriving (Eq, Ord, Show)

type InferType = Type InferVariable

-- | A solver proof, retained until dictionary elaboration. Selecting an
-- implementation never changes the wanted type to make a head fit.
data Evidence
  = GivenEvidence NodeId Int
  | SuperclassEvidence GlobalId Int Evidence
  | ImplementationEvidence ImplementationId [InferType] [Evidence]
  deriving (Eq, Show)

renderInferType :: InferType -> Text
renderInferType = renderType renderVariable
  where
    renderVariable (Meta (MetaId n)) = "?" <> T.pack (show n)
    renderVariable (Skolem (SkolemId n)) = "s" <> T.pack (show n)
    renderVariable (Bound b) = renderBound b
