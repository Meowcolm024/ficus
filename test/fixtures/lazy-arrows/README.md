# Lazy arrows (v2+): call-by-name, not call-by-need

Source inventory only; no runner integration or execution. ParsingV2 checks
mixed arrows/right associativity and a nested lazy type argument; these types
remain rejected in v0/v1. CallByNameV2 describes future runtime expectations:
trace runs twice for repeatEffects, zero times for skipEffects, once for
explicitSharing; traceBox runs once for patternDemand. leftToRight records
left,right,left,right. Variable parameters demand on each use; constructor
parameter matching demands once per attempt and binds components of that value.
Coverage proofs must not remove that demand. Add repeated failures, divergence,
captured lexical environment, forwarding through another lazy call, strict
argument order, and source-provenance checks when a runtime harness exists.

ArrowMismatchV2 must reject both assignments, with TypeMismatch on 6:15–18
(lazy) and 8:13–18 (strict), using separate cases if the runner stops at the first
error. Neither arrow is a subtype of the other; no coercion or memoizing wrapper
may silently make either assignment pass. These are semantic cases, not parse
rejections. The concrete thunk/Core representation remains open.
