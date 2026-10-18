module Ficus.Elaborate.Schedule (scheduleBindings, referencedValues, initializationDiagnostics) where

import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Set (Set)
import Data.Set qualified as Set
import Ficus.Error.Type qualified as E
import Ficus.Syntax.Core qualified as C
import Ficus.Syntax.Name

referencedValues :: C.Expr ty -> Set Reference
referencedValues expression = own `Set.union` Set.unions (map referencedValues (C.children expression))
  where
    own = case C.formOf expression of C.Var reference _ -> Set.singleton reference; _ -> Set.empty

-- Evidence lambdas may defer initialization, but they do not make a recursive
-- initializer safe. Only a source value parameter protects a recursive read.
initializationDiagnostics :: [C.BindingGroup ty] -> [E.Diagnostic]
initializationDiagnostics = concatMap check
  where
    check (C.NonRecursive _) = []
    check (C.Recursive bindings) = concatMap (unprotected names . C.bindingBody . C.nodeValue) bindings
      where
        names = Set.fromList (map (C.bindingReference . C.nodeValue) (NE.toList bindings))
    unprotected names expression = case C.formOf expression of
      C.Var reference _
        | reference `Set.member` names ->
            [E.diagnostic E.UnsafeRecursiveInitialization (C.nodeSpan expression) "recursive initialization reads a value before it is available"]
      C.Lambda binder _ | let (_, _, role, _) = C.nodeValue binder, role == C.ValueBinder -> []
      _ -> concatMap (unprotected names) (C.children expression)

-- Dictionary builders introduce dependencies absent from source name graphs.
-- Schedule again after evidence insertion, retaining source order for ties.
scheduleBindings :: [C.Binding ty] -> Either E.Diagnostic [C.BindingGroup ty]
scheduleBindings bindings = select Set.empty groups
  where
    identities = Set.fromList [C.bindingReference (C.nodeValue binding) | binding <- bindings]
    dependencies binding = referencedValues (C.bindingBody (C.nodeValue binding)) `Set.intersection` identities
    components = stronglyConnComp [(binding, C.bindingReference (C.nodeValue binding), Set.toList (dependencies binding)) | binding <- bindings]
    groups = sortOn (C.nodeSpan . firstBinding) (concatMap makeGroup components)
    makeGroup (AcyclicSCC binding) = [C.NonRecursive binding]
    makeGroup (CyclicSCC entries) = case NE.nonEmpty (sortOn C.nodeSpan entries) of
      Just nonempty -> [C.Recursive nonempty]
      Nothing -> []
    firstBinding (C.NonRecursive binding) = binding
    firstBinding (C.Recursive (binding NE.:| _)) = binding
    names group = Set.fromList (map (C.bindingReference . C.nodeValue) (C.groupBindings group))
    needs group = Set.unions (map dependencies (C.groupBindings group)) `Set.difference` names group
    select _ [] = Right []
    select done remaining@(first : _) = case break (\group -> needs group `Set.isSubsetOf` done) remaining of
      (before, ready : after) -> (ready :) <$> select (done `Set.union` names ready) (before ++ after)
      _ -> Left (E.diagnostic E.InvalidCoreTree (C.nodeSpan (firstBinding first)) "Core dependency components are not acyclic")
