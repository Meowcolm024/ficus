-- | Translate qualified source schemes into ordinary dictionary arrows.
module Ficus.Elaborate.Types (dictionaryType, evidenceScheme, dictionaryDescriptors, implementationReference, implementationScheme) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Ficus.Infer.Declaration
import Ficus.Infer.Monad (Infer, freshId)
import Ficus.Infer.Syntax
import Ficus.Infer.Type
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Name hiding (TypeKind)
import Ficus.Type
import Ficus.Util.Source

dictionaryType :: Declarations -> Predicate InferType -> InferType
dictionaryType environment predicate =
  let ident = predicateTrait predicate
      kind = Map.findWithDefault (KindArrow TypeKind TypeKind) ident (typeKinds (declarationTypes environment))
   in Application (Constructor ident kind) (predicateArgument predicate)

evidenceScheme :: Declarations -> Scheme InferType -> Scheme InferType
evidenceScheme environment scheme =
  scheme
    { schemeType = foldr function (schemeType scheme) (map (dictionaryType environment) (schemePredicates scheme)),
      schemePredicates = []
    }

dictionaryDescriptors :: Declarations -> Infer (Map GlobalId (C.Node (C.DictionaryDescriptor InferType)))
dictionaryDescriptors environment = Map.traverseWithKey descriptor (traitDeclarations environment)
  where
    descriptor ident node = do
      let trait = C.nodeValue node
          parameter = traitParameter trait
          own = Predicate ident (Variable (Bound (quantifierId parameter)) (quantifierKind parameter))
          method scheme =
            evidenceScheme
              environment
              scheme
                { implicitQuantifiers = filter ((/= quantifierId parameter) . quantifierId) (implicitQuantifiers scheme),
                  schemePredicates = filter (/= own) (schemePredicates scheme)
                }
          -- Layout nodes derive from the trait declaration. Method initializer
          -- nodes retain their implementation member's more precise origin.
          field :: a -> Infer (C.Node a)
          field value = do
            fresh <- freshId
            pure (C.Node (NodeId (-fresh - 1)) (C.nodeSpan node) (GeneratedOrigin "dictionary layout" (C.nodeSpan node)) value)
      supers <- mapM (field . dictionaryType environment) (traitSuperclasses trait)
      methods <- mapM (\(name, scheme) -> field (name, method scheme)) (Map.toAscList (traitMethods trait))
      pure (fmap (const (C.DictionaryDescriptor parameter supers methods)) node)

implementationReference :: ImplementationId -> Reference
implementationReference (ImplementationId (owner, ident)) = GlobalRef (GlobalId owner ValueNS ("$implementation:" <> T.pack (show ident)))

implementationScheme :: Declarations -> ImplementationDeclaration -> Scheme InferType
implementationScheme environment implementation = evidenceScheme environment (Scheme [] (implementationParameters implementation) (implementationContext implementation) (dictionaryType environment (implementationHead implementation)))
