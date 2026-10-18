-- | Source restrictions must be decided before dictionary lambdas or pattern
-- compilation can change the apparent shape of an initializer.
module Ficus.Infer.Restriction (nonExpansive, initializerExpansiveOrigin, hasValueParameters, unprotectedReferences) where

import Data.Set (Set)
import Data.Set qualified as Set
import Ficus.Syntax.Abstract qualified as A
import Ficus.Syntax.Name
import Ficus.Util.Source

nonExpansive :: A.Expr -> Bool
nonExpansive expression = case A.nodeValue expression of
  A.Ref _ -> True
  A.Constructor _ -> True
  A.Method _ -> True
  A.Literal _ -> True
  A.Hole _ -> True
  A.Lambda _ _ -> True
  A.TypeLambda _ body -> nonExpansive body
  A.TypeApply body _ -> nonExpansive body
  A.Annotated body _ _ -> nonExpansive body
  A.Apply f x -> constructorApplication f && nonExpansive x
  A.Product fields -> all nonExpansive fields
  A.List fields -> all nonExpansive fields
  A.Unit -> True
  A.ConstructRecord _ fields -> all (nonExpansive . snd . A.nodeValue) fields
  A.Where _ bindings body -> all ((== Nothing) . initializerExpansiveOrigin) (A.declarations bindings) && nonExpansive body
  A.Negate body -> numericLiteral body
  A.Match {} -> False
  A.Conditional _ -> False
  A.Sequence {} -> False
  A.Project {} -> False
  A.UpdateRecord {} -> False
  where
    constructorApplication e = case A.nodeValue e of
      A.Constructor _ -> True
      A.Apply f x -> constructorApplication f && nonExpansive x
      A.TypeApply f _ -> constructorApplication f
      A.Annotated f _ _ -> constructorApplication f
      _ -> False
    numericLiteral e = case A.nodeValue e of
      A.Literal _ -> True
      A.Negate x -> numericLiteral x
      _ -> False

initializerExpansiveOrigin :: A.Declaration -> Maybe Span
initializerExpansiveOrigin declaration = case A.nodeValue declaration of
  A.ValueDefinition _ _ (A.ClausesBody arity clauses)
    | arity > 0 -> Nothing
    | otherwise -> firstJust (map checkClause (foldr (:) [] clauses))
  A.PatternDefinition _ body -> if nonExpansive body then Nothing else Just (A.nodeSpan body)
  _ -> Nothing
  where
    checkClause clause =
      let body = A.clauseBody (A.nodeValue clause)
          group = A.clauseWhere (A.nodeValue clause)
       in if nonExpansive body && all ((== Nothing) . initializerExpansiveOrigin) (A.declarations group)
            then Nothing
            else Just ((A.nodeSpan body) {end = end (A.nodeSpan clause)})
    firstJust [] = Nothing
    firstJust (Just x : _) = Just x
    firstJust (Nothing : xs) = firstJust xs

hasValueParameters :: A.Declaration -> Bool
hasValueParameters declaration = case A.nodeValue declaration of
  A.ValueDefinition _ _ (A.ClausesBody arity clauses) -> arity > 0 || any (outerLambda . A.clauseBody . A.nodeValue) clauses
  A.PatternDefinition _ body -> outerLambda body
  _ -> False
  where
    outerLambda expression = case A.nodeValue expression of
      A.Lambda _ _ -> True
      A.TypeLambda _ body -> outerLambda body
      A.TypeApply body _ -> outerLambda body
      A.Annotated body _ _ -> outerLambda body
      A.Where _ _ body -> outerLambda body
      _ -> False

-- | Report the actual read site, not the enclosing definition. Static type
-- abstractions/applications never protect a recursive initialization read.
unprotectedReferences :: Set Reference -> A.Declaration -> [A.Node Reference]
unprotectedReferences cyclic = declaration False
  where
    declaration delayed decl = case A.nodeValue decl of
      A.ValueDefinition _ _ (A.ClausesBody arity clauses) -> concatMap (clause (delayed || arity > 0) . A.nodeValue) clauses
      A.PatternDefinition _ body -> expression delayed body
      A.ImplementationDefinition _ _ _ _ members -> concatMap (declaration delayed) members
      _ -> []
    clause delayed cl = group delayed (A.clauseWhere cl) ++ expression delayed (A.clauseBody cl)
    group delayed = concatMap (declaration delayed) . A.declarations
    expression delayed e = case A.nodeValue e of
      A.Ref ref | not delayed && Set.member ref cyclic -> [A.Node (A.nodeId e) (A.nodeSpan e) (A.nodeOrigin e) ref]
      A.Ref _ -> []
      A.Constructor _ -> []
      A.Method ref | not delayed && Set.member (GlobalRef ref) cyclic -> [A.Node (A.nodeId e) (A.nodeSpan e) (A.nodeOrigin e) (GlobalRef ref)]
      A.Method _ -> []
      A.Literal _ -> []
      A.Hole _ -> []
      A.Apply f x -> expression delayed f ++ expression delayed x
      A.TypeApply f _ -> expression delayed f
      A.Annotated body _ _ -> expression delayed body
      A.Lambda _ body -> expression True body
      A.TypeLambda _ body -> expression delayed body
      A.Match _ receiver alternatives -> expression delayed receiver ++ concatMap (\alt -> let (_, guard, body) = A.nodeValue alt in foldMap (expression delayed) guard ++ expression delayed body) alternatives
      A.Conditional arms -> concatMap (\arm -> let (condition, body) = A.nodeValue arm in foldMap (expression delayed) condition ++ expression delayed body) arms
      A.Sequence statements body -> concatMap (statement delayed . A.nodeValue) statements ++ expression delayed body
      A.Where _ bindings body -> group delayed bindings ++ expression delayed body
      A.Project receiver _ -> expression delayed receiver
      A.ConstructRecord _ fields -> concatMap (expression delayed . snd . A.nodeValue) fields
      A.UpdateRecord receiver fields -> expression delayed receiver ++ concatMap (expression delayed . snd . A.nodeValue) fields
      A.Product fields -> concatMap (expression delayed) fields
      A.List fields -> concatMap (expression delayed) fields
      A.Unit -> []
      A.Negate body -> expression delayed body
    statement delayed = \case
      A.Effect e -> expression delayed e
      A.BindStatement bindings -> group delayed bindings
