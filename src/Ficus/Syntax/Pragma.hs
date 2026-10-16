-- | Stage-neutral, source-located semantic directive metadata.
module Ficus.Syntax.Pragma where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Ficus.Util.Source (Span)

data Directive = Directive {directiveName :: Text, directiveSpan :: Span, directiveArguments :: [DirectiveArgument]} deriving (Eq, Show)

data DirectiveArgument = Identifier Text Span | String Text Span deriving (Eq, Show)

type ModuleOptions = Map Text [Directive]
