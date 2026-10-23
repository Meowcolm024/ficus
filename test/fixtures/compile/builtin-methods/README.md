# Builtin trait-member registrations

`Ficus.Builtin.MethodSpec` checks SHOW/DEBUG member contracts, duplicate local
registrations, conflicts through imports and independent compilation roots,
and rejection at linking after separate successful compilations. Negative cases
assert diagnostic kinds and primary spans.

Render supplies renamed methods and a minimal MatchError contract for execution.
Left and Right re-export the same registrations; Diamond exercises canonical
identity deduplication. The custom Prelude and Interpolation verify registered
SHOW dispatch; REPL tests verify DEBUG dispatch, including a symbolic member.
EmptyPrelude and Missing exercise absent registrations. Core validation also
independently rejects metadata that points at an ordinary function.
