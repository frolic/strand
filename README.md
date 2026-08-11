# Strand

simpler solidity strings

## About

Lazy, gas-conscious string building for on-chain metadata (`tokenURI` and friends). A `Strand` is a list of parts — inline bytes (`s("…")`) or references to contract bytecode (`bytecode(…)`, `ethfs(…)`) — that only materializes into one string when you call `toString()`. Bytecode parts are read with `EXTCODECOPY` at render time, so composing a strand costs almost nothing regardless of how much data it references.

```solidity
Strand script = s('<script src="data:text/javascript;base64,') + ethfs("three.min.js") + s('"></script>');
Strand html = s('<html><head></head><body>') + script + s('</body></html>');
Strand metadata = s('{"name":"Token","animation_url":"data:text/html,') + html.encodeURI() + s('"}');
Strand uri = s("data:application/json,") + metadata.encodeURI();
return uri.toString();
```

Coming from scripty.sol? See [docs/migrate-from-scripty.md](docs/migrate-from-scripty.md) for a concept mapping and measured gas comparison.

## Design notes & invariants

The gas savings come from carrying references instead of copying. That has consequences worth knowing before use:

- **To save gas, a `Strand` is a memory pointer — so it can't be used across contract boundaries.** Internal calls share one memory space, so strands flow freely through them, but never use a `Strand` as a public/external parameter or return type, and never store one: ABI-encoding it sends the raw pointer, and the receiving frame dereferences its own unrelated memory. When a strand does need to cross a boundary, pass its serialized *recipe* rather than the pointer — small and still lazy, because inline literals travel by value while bytecode parts travel as `(pointer, start, end)` references, valid everywhere since contract code is global state:

  ```solidity
  // sender: serialize the recipe (stays small no matter how big the referenced data is)
  bytes memory recipe = serialize(strand);

  // receiver: rebuild in this frame's memory and keep composing lazily
  Strand strand = deserialize(recipe);
  ```

  The receiver inherits trust in the pointers — only deserialize recipes from senders you trust.
- **Materialize with `toString()` as late as possible, exactly once.** The materialization is where the gas goes — memory expansion and copying scale with output size, and pushing a materialized string across an external call pays the full ABI round-trip on top. Compose lazily (and cross boundaries as recipes) until the final consumer, then render.
- **Parts are shared, not copied.** `+`/`concat` copies part pointers, and `s()` keeps a reference to your string (mutating the original changes the strand). Transforms like `encodeURI` are copy-on-write: they return a new strand and never mutate their input, so sharing is safe as long as you don't mutate source strings yourself.
- **`encodeURI` only encodes inline (`s`) parts.** Bytecode parts pass through untouched — encoding them would mean materializing the referenced code, and the library has no way to know whether code is already URI-safe. That makes URI safety *your* invariant: only reference URI-safe content (e.g. base64 — whose `+` `/` `=` are tolerated in data-URI paths, if not spec-perfect percent-encoding) from strands you intend to `encodeURI`. Get it wrong and the URI is silently malformed.
- **Renders are `view`-only in spirit and can be big.** Building an ~800KB URI costs ~9.5M gas of memory and copy work — free via `eth_call`, but an on-chain caller of `toString()` is bounded by the 16.7M per-transaction gas cap (EIP-7825), reached around ~1.5MB of output.
