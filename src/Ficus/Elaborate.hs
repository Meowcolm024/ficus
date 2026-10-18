-- | The checked module boundary. Only complete, independently validated Core
-- publishes an interface for dependent modules.
module Ficus.Elaborate
  ( Elaboration (..),
    CheckedModule,
    CheckedInterface,
    checkedCore,
    checkedInterface,
    checkedTypes,
    elaborateModule,
    elaborateInteractiveModule,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Ficus.Elaborate.Finalize qualified as F
import Ficus.Elaborate.Lower
import Ficus.Error.Diagnostic qualified as D
import Ficus.Error.Type qualified as E
import Ficus.Infer.Check
import Ficus.Infer.Declaration
import Ficus.Infer.Monad qualified as I
import Ficus.Infer.Syntax
import Ficus.Infer.Type
import Ficus.Initialization
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Abstract.Validate
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Core.Validate
import Ficus.Syntax.Name
import Ficus.Type

data Elaboration = Complete CheckedModule [E.Diagnostic] | Incomplete (Maybe (C.CoreModule C.CoreType)) [E.Diagnostic] deriving (Eq, Show)

data CheckedModule = CheckedModule
  { checkedCore :: ValidatedCore,
    checkedInterface :: CheckedInterface,
    checkedTypes :: Map Reference (Scheme C.CoreType)
  }
  deriving (Eq, Show)

-- The constructor is private. Inference types in this internal cache are
-- closed bound variables; no solver metavariable or source implementation body
-- can be exported through the public elaboration API.
newtype CheckedInterface = CheckedInterface Declarations deriving (Eq, Show)

elaborateModule :: [CheckedInterface] -> A.AbstractModule -> Elaboration
elaborateModule = elaborateWithMode OrdinaryInitialization

elaborateInteractiveModule :: [CheckedInterface] -> A.AbstractModule -> Elaboration
elaborateInteractiveModule = elaborateWithMode InteractiveInitialization

elaborateWithMode :: InitializationMode -> [CheckedInterface] -> A.AbstractModule -> Elaboration
elaborateWithMode mode imports source = case validateAbstract source of
  Left message -> Incomplete Nothing [E.diagnostic E.InvalidCoreTree (A.abstractSpan source) message]
  Right () ->
    let visible = Set.fromList (A.visibleImplementations source)
        merged = mergeInterfaces imports
        imported = merged {implementationDeclarations = Map.restrictKeys (implementationDeclarations merged) visible}
        inferred = inferModuleWithMode mode imported source
        diagnostics = I.diagnostics (inferenceState inferred)
     in case lowerModule inferred source of
          (Left problem, _) -> Incomplete Nothing (diagnostics ++ [problem | not (any isError diagnostics)])
          (Right core, state) -> case fst (I.runInferFrom state (F.finalizeModule core)) of
            F.Incomplete partial errors -> Incomplete (Just partial) errors
            F.Complete accepted warnings -> case traverse (traverse closeType) (inferredValues inferred) of
              Left () -> Incomplete (Just (validatedModule accepted)) (warnings ++ [E.diagnostic E.InvalidCoreTree (A.abstractSpan source) "an exported source scheme contains an unsolved variable"])
              Right types ->
                let exports = Set.fromList [GlobalRef (A.entityId entity) | entity <- Map.elems (A.abstractExports source)]
                    publicValues = Map.restrictKeys (inferredValues inferred) exports
                    declarations = inferredDeclarations inferred
                    interface =
                      declarations
                        { valueSignatures = Map.map (\scheme -> Signature scheme False (A.abstractSpan source)) publicValues,
                          implementationDeclarations = fmap (fmap (\implementation -> implementation {implementationMembers = Map.empty})) (implementationDeclarations declarations)
                        }
                 in Complete (CheckedModule accepted (CheckedInterface interface) (Map.restrictKeys types exports)) warnings
  where
    isError = (== D.Error) . D.diagnosticSeverity . D.toDiagnostic
    closeType = traverse (\case Bound ident -> Right (C.BoundVariable ident); _ -> Left ())

mergeInterfaces :: [CheckedInterface] -> Declarations
mergeInterfaces interfaces =
  Declarations
    { builtinTypeAssociations = Map.unions (map builtinTypeAssociations entries),
      declarationTypes =
        TypeEnvironment
          { typeKinds = Map.unions (map (typeKinds . declarationTypes) entries),
            binderKinds = Map.empty,
            writtenKinds = Map.empty,
            aliases = Map.unions (map (aliases . declarationTypes) entries),
            aliasNames = Set.unions (map (aliasNames . declarationTypes) entries)
          },
      valueSignatures = Map.unions (map valueSignatures entries),
      constructorDeclarations = Map.unions (map constructorDeclarations entries),
      recordDeclarations = Map.unions (map recordDeclarations entries),
      traitDeclarations = Map.unions (map traitDeclarations entries),
      implementationDeclarations = Map.unions (map implementationDeclarations entries)
    }
  where
    entries = [entry | CheckedInterface entry <- interfaces]
