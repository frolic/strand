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

- **A `Strand` is a memory pointer.** It lives and dies inside the call frame that built it. Never use one as a public/external parameter or return type, and never store one — render with `toString()` first. ABI-encoding a `Strand` across a call boundary sends the raw pointer, and the receiving frame dereferences its own unrelated memory.
- **Parts are shared, not copied.** `+`/`concat` copies part pointers, and `s()` keeps a reference to your string (mutating the original changes the strand). Transforms like `encodeURI` are copy-on-write: they return a new strand and never mutate their input, so sharing is safe as long as you don't mutate source strings yourself.
- **`encodeURI` only encodes inline (`s`) parts.** Bytecode parts pass through untouched — encoding them would mean materializing the referenced code, and the library has no way to know whether code is already URI-safe. That makes URI safety *your* invariant: only reference URI-safe content (e.g. base64 — whose `+` `/` `=` are tolerated in data-URI paths, if not spec-perfect percent-encoding) from strands you intend to `encodeURI`. Get it wrong and the URI is silently malformed.
- **Renders are `view`-only in spirit and can be big.** Building an ~800KB URI costs ~9.5M gas of memory and copy work — free via `eth_call`, but an on-chain caller of `toString()` is bounded by the 16.7M per-transaction gas cap (EIP-7825), reached around ~1.5MB of output.
