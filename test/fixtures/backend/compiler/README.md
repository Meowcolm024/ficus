# Compiler backend fixtures

`TailCalls` exercises self, mutual, local, indirect, dictionary, and lazy tail
transfers, swapped arguments, retained non-tail work, and active catches.
`Order` checks application/initialization order, closure captures, record updates,
and reference updates interrupted by exceptions. `Primitives` checks numeric and
Unicode representations and typed failures. `FileMain` checks standalone JS file
IO and entry arguments. `InputMain` checks bounded Unicode input and line endings. The compiler tests compare the unoptimized direct
interpreter, optimized evaluator, and generated JavaScript. Deep tail chains run
under a deliberately small Node stack.
