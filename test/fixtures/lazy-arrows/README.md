# Call-by-name arrows

`Ficus.Parser.Spec` checks parsing, Concrete validation, pretty-print round trips,
and formatter idempotence for ParsingV2, CallByNameV2, and ArrowMismatchV2.
Those original inventory files remain useful syntax examples.

`FicusBackend.LazyArrowSpec` compiles Execution and Contextual, validates Abstract,
Core, and Runtime boundaries, and compares compiled and direct execution. Cases
cover skipped and repeated effects, errors and divergence, explicit sharing,
lexical capture, partial application, mixed strict/lazy argument order, repeated
pattern attempts, exhaustive constructor demands, polymorphism, trait methods,
and contextual lambda checking inside aggregate values.

WrongStrict and WrongLazy split the original ArrowMismatchV2 cases and assert
TypeMismatch with the primary span of the offending reference. InferredStrict
checks that ordinary inference still produces a strict arrow. Core validation
also rejects lazy lambdas and applications that omit their explicit thunks.
