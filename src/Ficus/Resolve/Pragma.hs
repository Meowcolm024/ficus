-- | Uniform semantic directive classification. Future module directives extend
-- this table and module-option interpretation, without changing the parser.
module Ficus.Resolve.Pragma (module Ficus.Resolve.Pragma, module Ficus.Syntax.Pragma) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Ficus.Error.Resolve
import Ficus.Syntax.Concrete qualified as C
import Ficus.Syntax.Pragma

data Placement = ModuleDirective | DeclarationDirective deriving (Eq, Show)

data ArgumentShape = NoArguments | BuiltinArguments deriving (Eq, Show)

data PragmaRule = PragmaRule {pragmaPlacement :: Placement, pragmaArguments :: ArgumentShape, pragmaAvailable :: Bool} deriving (Eq, Show)

pragmaRules :: Map Text PragmaRule
pragmaRules =
  Map.fromList
    [ ("NO_IMPLICIT_PRELUDE", PragmaRule ModuleDirective NoArguments True),
      ("BUILTIN", PragmaRule DeclarationDirective BuiltinArguments True)
    ]
    `Map.union` Map.fromList [(name, PragmaRule placement NoArguments False) | (name, placement) <- [("STANDALONE", ModuleDirective), ("OPTIONS", ModuleDirective), ("PRIVATE", DeclarationDirective), ("DEPRECATED", DeclarationDirective), ("DERIVE", DeclarationDirective), ("ETA", DeclarationDirective), ("FOREIGN", DeclarationDirective)]]

validatePragma :: Placement -> C.Pragma -> Either Diagnostic Directive
validatePragma placement p = case C.concrete p of
  C.Pragma n args -> do
    let name = C.nameText n
        failWith code s msg = Left (diagnostic code s msg)
    rule <- maybe (failWith UnknownPragma (C.nameLocation n) "unknown pragma") Right (Map.lookup name pragmaRules)
    if pragmaAvailable rule then Right () else failWith UnsupportedFeature (C.nameLocation n) "pragma unavailable in v0"
    -- Declaration metadata may occur in the initial pragma run too.
    if pragmaPlacement rule == ModuleDirective && placement /= ModuleDirective
      then failWith InvalidPragmaPlacement (C.nameLocation n) "module directive must precede imports and declarations"
      else Right ()
    case (pragmaArguments rule, args) of
      (NoArguments, []) -> Right ()
      (NoArguments, _) -> failWith InvalidPragmaArguments (C.nameLocation n) "pragma takes no arguments"
      (BuiltinArguments, [a, b]) -> mapM_ (\arg -> case C.concrete arg of C.IdentifierArgument _ -> Right (); _ -> failWith InvalidPragmaArguments (C.location arg) "expected identifier") [a, b]
      (BuiltinArguments, _) -> failWith InvalidPragmaArguments (C.nameLocation n) "BUILTIN requires key and target identifiers"
    pure (Directive name (C.location p) (map argument args))
  where
    argument a = case C.concrete a of
      C.IdentifierArgument n -> Identifier (C.nameText n) (C.nameLocation n)
      C.StringArgument t -> String t (C.location a)

preludeEnabled :: ModuleOptions -> Bool
preludeEnabled = not . Map.member "NO_IMPLICIT_PRELUDE"
