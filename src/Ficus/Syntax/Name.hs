-- | Stage-neutral identities. Spelling is retained for diagnostics only.
module Ficus.Syntax.Name (module Ficus.Syntax.Name, Intrinsic (..), Primitive (..)) where

import Data.Char (isAlphaNum, isUpper)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as T
import Ficus.Primitive.Registry (Intrinsic (..), Primitive (..))
import Ficus.Primitive.Registry qualified as P
import Ficus.Util.Source (Span)

newtype ModuleId = ModuleId (NonEmpty Text) deriving (Eq, Ord, Show)

newtype LocalId = LocalId Int deriving (Eq, Ord, Show)

newtype TypeVarId = TypeVarId Int deriving (Eq, Ord, Show)

newtype NodeId = NodeId Int deriving (Eq, Ord, Show)

newtype HoleId = HoleId Int deriving (Eq, Ord, Show)

newtype ImplementationId = ImplementationId (ModuleId, Int) deriving (Eq, Ord, Show)

data Namespace = ValueNS | TypeNS | ConstructorNS | KindNS deriving (Eq, Ord, Show)

data Role = ValueRole | AliasRole | DataRole | RecordRole | RecordConstructorRole | ConstructorRole | TraitRole | MethodRole | KindRole deriving (Eq, Ord, Show)

type PrimitiveId = Primitive GlobalId

data GlobalId = GlobalId ModuleId Namespace Text | IntrinsicId Intrinsic deriving (Eq, Ord, Show)

data Reference = LocalRef LocalId | GlobalRef GlobalId deriving (Eq, Ord, Show)

primitiveNames :: [(Namespace, Text, GlobalId, Role)]
primitiveNames =
  [(TypeNS, spelling, IntrinsicId intrinsic, DataRole) | (spelling, intrinsic) <- P.intrinsicTypes]
    ++ [(ConstructorNS, spelling, IntrinsicId intrinsic, ConstructorRole) | (spelling, intrinsic) <- P.intrinsicConstructors]
    ++ [(KindNS, spelling, IntrinsicId intrinsic, KindRole) | (spelling, intrinsic) <- P.intrinsicKinds]

data Entity = Entity {entityId :: GlobalId, entityRole :: Role, entitySpan :: Span, entityOwner :: Maybe GlobalId} deriving (Eq, Show)

data FieldDescriptor = FieldDescriptor {fieldOwner :: GlobalId, fieldLabel :: Text, fieldSpan :: Span} deriving (Eq, Show)

type NameSummary = Map (Namespace, Text) Entity

validModuleComponent :: Text -> Bool
validModuleComponent component = case T.uncons component of
  Just (c, rest) -> isUpper c && T.all (\x -> isAlphaNum x || x == '_' || x == '\'') rest
  Nothing -> False

moduleText :: ModuleId -> Text
moduleText (ModuleId parts) = T.intercalate "." (NE.toList parts)
