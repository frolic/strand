# Strand — Security & Correctness Audit

**Date:** 2026-08-11
**Scope:** `src/Strand.sol`, `src/utils.sol`, `src/transforms.sol`, `src/ethfs.sol` (solady and EthFS treated as trusted dependencies)
**Context:** view-only string-composition library for building token URIs from literals and contract bytecode (SSTORE2/EthFS). No storage, no funds, no privileged roles — so the risk surface is correctness (silently wrong URIs), denial of service (reverting `tokenURI`), and API footguns for integrators.

Every finding below is demonstrated by a passing characterization test in [audit.t.sol](audit.t.sol) (prefixed `test_pitfall_`). If you fix a finding, flip the corresponding test to assert the fixed behavior.

## Summary

| # | Severity | Finding |
|---|----------|---------|
| 1 | Medium | `encodeURI` mutates strands in place; `concat` shares parts, so mutation propagates to every strand built from the same parts |
| 2 | Medium | `encodeURI` silently skips bytecode parts, producing malformed URIs for non-URI-safe code content |
| 3 | Low | `_codeSlice` underflows on `start > end`, dying with out-of-gas instead of a clean revert; `bytecode()` constructors accept invalid ranges |
| 4 | Low | `Strand` is a memory pointer disguised as a value type — crossing a call frame or being stored yields garbage |
| 5 | Low | `s()` aliases the caller's string; later mutation changes the strand |
| 6 | Info | `_Strand.length` metadata is unreliable (stale after `map`, zero for open-ended `bytecode` parts) |
| 7 | Info | Misc: unaligned free-memory pointer, O(n²) concat, unused-param warning, hardcoded FileStore address, test-file layout |

## Resolution (2026-08-11, same branch)

- **1 & 6 fixed:** `map` is now copy-on-write (fresh `_Part[]` + structs, shared data bytes) and recomputes `_Strand.length`. Cost: +1.6% gas on the small tokenURI flow, +1.2% on the 810KB EthFS render. Tests renamed to `test_encodeURI*`/`test_strandLengthUpdatedByEncodeURI` and assert the new behavior.
- **3 fixed:** `_codeSlice` reverts on `start > end` (folded into the existing bounds check). The `bytecode()` constructors intentionally still defer validation to render time — checking eagerly would cost an `extcodesize` per part at build time (`test_pitfall_bytecodeConstructorAcceptsInvertedRange`).
- **2, 4, 5 resolved as documentation:** intent and invariants (frame lifetime, part/string sharing, URI safety of bytecode content) are now stated in the README and in a comment in `_encodeURI`. Two enforcement designs were considered and rejected: reverting `encodeURI` on `"bc"` parts (breaks the canonical nested-data-URI flow, which depends on base64 bytecode passing through), and a declared-URI-safe part kind/encoding field (the library can never verify the claim — bytecode is opaque at construction — so the tag would be an unverifiable promise dressed up as a type). Render-time encoding is gas-prohibitive for large payloads. URI safety of referenced code is a documented caller invariant, pinned by `test_pitfall_encodeURISkipsBytecodeParts`.
- **7:** unused-param warning fixed; the rest left as notes.

The finding sections below describe the code as audited, pre-fix.

---

## 1. Medium — `encodeURI` has reference semantics behind a value-type API

`Strand` + the `+` operator present a value-semantics API, but the implementation is a memory pointer (`_wrap`/`_unwrap`), and `map` ([utils.sol:17-19](../../src/utils.sol#L17)) writes transformed parts back into the same structs. Two consequences:

- `encoded = original.encodeURI()` also rewrites `original` (they are the same pointer — `test_pitfall_encodeURIMutatesOriginal`).
- `concat` ([Strand.sol:41](../../src/Strand.sol#L41)) copies part *pointers* (memory-to-memory struct assignment into a `_Part[]` copies references), so `combined.encodeURI()` reaches back and mutates `left` and `right` (`test_pitfall_concatSharesPartsWithInputs`).

The library's own canonical flow only works by coincidence: in `testTokenURI`, `metadata.encodeURI()` re-encodes the already-encoded `page` parts *in place*, which happens to be the desired nesting. But any caller who renders or reuses an input strand after composing it gets double-encoded or unexpectedly-encoded output (`test_pitfall_doubleEncodeURI`). For a tokenURI library, that means silently corrupt metadata — hence Medium.

**Recommendation:** make `map` copy-on-write — allocate a fresh `_Part[]` and fresh `_Part` structs for transformed parts (untransformed parts can keep shared `data` bytes since nothing mutates part contents after construction… but note `map` is the thing that mutates, so copying the structs suffices). Alternatively, deep-copy in `concat`. Copying structs is cheap relative to rendering; correctness beats the gas here. Also recompute `length` while you're at it (finding 6).

## 2. Medium — `encodeURI` silently skips bytecode parts

`_encodeURI` ([transforms.sol:19-25](../../src/transforms.sol#L19)) only transforms `"by"` parts; `"bc"` parts pass through untouched. If the referenced bytecode contains URI-unsafe characters (spaces, quotes, `<`, `%`, …) the rendered URI is malformed with no error (`test_pitfall_encodeURISkipsBytecodeParts`).

Today this is survivable because the intended payloads are base64 (EthFS files, the SSTORE2 examples), which is *mostly* URI-safe — but even standard base64 emits `+`, `/`, and `=`. Those happen to be tolerated in a data-URI path segment by browsers, but `+` becomes a space under `application/x-www-form-urlencoded` interpretation and strict `encodeURIComponent` semantics say all three should be escaped. So the current output is "works in browsers" rather than "spec-correct percent-encoding".

**Recommendation:** at minimum, document loudly that `encodeURI` assumes bytecode parts are URI-safe and that callers must only reference base64/hex content. Better: percent-encode bytecode parts at render time (a streaming variant of `encodeURIComponent` in `_toString`), or add a part flag recording whether encoding is pending so `toString` can apply it. Note you cannot eagerly encode a `"bc"` part in `map` without materializing the code — a render-time transform is the natural fit.

## 3. Low — `_codeSlice` bounds: underflow to OOG, constructors accept bad ranges

In `_codeSlice` ([transforms.sol:39-52](../../src/transforms.sol#L39)):

- `end > size` reverts (good — but the comment calls it "optional"; it is not, since `extcodecopy` zero-pads past the end and would silently append NUL bytes to the string without it).
- `start > end` is unchecked: `sub(end, start)` wraps to ~2^256, and the call dies from out-of-gas on the giant `extcodecopy` instead of reverting cleanly (`test_pitfall_codeSliceStartPastEndRunsOutOfGas`). Same failure for `start > size` with the open-ended (`end = 0`) form, since `end` becomes `size`.
- The `bytecode()` constructors ([Strand.sol:29](../../src/Strand.sol#L29)) already detect `end <= start` — they clamp the *recorded* length to 0 — but still encode the bad range, deferring the explosion to render time (`test_pitfall_bytecodeConstructorAcceptsInvertedRange`).

An OOG in `tokenURI` is functionally a bricked URI, and it's much harder to debug than a revert, especially for the open-ended form where `start > size` only at render time. Since `map`/`toString` are `view`, an OOG also swallows the whole `eth_call` rather than pinpointing the bad part.

**Recommendation:** in `_codeSlice`, add `if gt(start, end) { revert(0, 0) }` (ideally a custom error via `mstore`+`revert`), and consider reverting in the `bytecode()` constructor on `end != 0 && end <= start` so bad ranges fail at construction where the stack trace is useful.

## 4. Low — `Strand` values must never cross call frames or be stored

`Strand` is a `uint256` holding a memory offset. It ABI-encodes as an integer, so passing one through an external call (or storing it) transmits the pointer, not the data — the receiving frame dereferences its own unrelated memory and returns garbage or reverts (`test_pitfall_strandCannotCrossCallBoundary`). Nothing in the type system stops an integrator from declaring `function preview(Strand page) external`.

**Recommendation:** document this prominently ("a Strand only lives within the call frame that built it; render with `toString()` before crossing any boundary"). There is no clean way to make the compiler enforce it for a UDVT, which is worth an explicit warning in the README.

## 5. Low — `s()` aliases the caller's string

`bytes(contents)` is a no-copy cast, so the part references the caller's string memory; mutating the original afterward changes what the strand renders (`test_pitfall_sAliasesCallerString`). Fine for the typical build-and-render-immediately flow, surprising otherwise — and it compounds with finding 1 (the same bytes can end up referenced by many strands).

**Recommendation:** document, or copy in `s()` if you adopt copy-on-write semantics elsewhere. Consistency matters more than the choice.

## 6. Info — `_Strand.length` is unreliable metadata

Two ways it diverges from the rendered length:

- `map` updates per-part lengths but never the strand total, so `encodeURI` leaves the pre-encoding total (`test_pitfall_strandLengthStaleAfterEncodeURI`).
- Open-ended `bytecode(location)` / `bytecode(location, start)` parts record length 0 because the code size isn't known at construction ([Strand.sol:29](../../src/Strand.sol#L29)).

Today the only consumer is `buffer.reserve(_strand.length)` in `buildString`, so the impact is just extra buffer reallocation (perf). But it's a latent correctness trap for any future consumer, and `reserve` under-reserving on the EthFS path (where lengths *are* known) forfeits most of the point of reserving.

**Recommendation:** recompute the total in `map` from the transformed part lengths, and either document that 0 means "unknown" or resolve `extcodesize` at construction (costs a cold account access; probably fine since render touches the same accounts anyway and warms them).

## 7. Info — miscellany

- **Unaligned free-memory pointer:** `_codeSlice` advances FMP by exactly `length` without rounding up to a 32-byte word. Legal, but breaks the alignment convention most hand-written assembly (including solady's) assumes when doing word-granular tricks after allocation. Cheap to fix: `and(add(length, 31), not(31))`.
- **O(n²) concat:** each `+` copies all accumulated part pointers. Negligible at current part counts (EthFS three.min.js ≈ 34 slices); worth a note in docs so nobody builds thousand-part strands one `+` at a time.
- **Compiler warning:** unused `length` param in `_toString` ([transforms.sol:27](../../src/transforms.sol#L27)) — comment the name out to keep the build warning-free.
- **Hardcoded FileStore address** ([ethfs.sol:9](../../src/ethfs.sol#L9)): `0xFe14…a0FB` is the deterministic EthFS v2 deploy, so it's stable across chains — but only where EthFS is actually deployed; on other chains `getFile` reverts. Worth a doc note.
- **Layout:** `ethfs.sol` and `ethfs.t.sol` live in `src/` but import `"../src/Strand.sol"`, which only resolves because `../src` loops back. Either move them (they read like an extension + test that belong in `src/` with `"./Strand.sol"` imports) or move tests to `test/` and drop `test = "src"`.
- **Strengthened test:** `ethfsTest.testFile` asserted only output length; a content keccak assertion was added so corruption (not just truncation) fails the test.

---

# EVM roadmap review (as of Aug 2026)

The user question: is bytecode-as-data + `EXTCODECOPY` still directionally correct, or does a recent/upcoming EVM change obsolete it? **Short answer: it's safe through Glamsterdam, and nothing scheduled replaces it.** Sources are the EIPs repo, ethereum.org fork pages, EF blog, and ACD notes.

**No threat:**

- **EOF (EIP-3540/7692)** — the one change that would have altered `EXTCODECOPY` semantics — was removed from Fusaka (Apr 2025), is marked Stagnant, and was formally *declined* for Glamsterdam in the meta EIP-7773. Even in the hypothetical revival, EOF only affects contracts deployed with the `0xEF00` prefix; legacy SSTORE2/EthFS data contracts would remain fully readable.
- **Blobs (EIP-4844/PeerDAS)** remain ephemeral (~18-day retention) — still not a substitute for persistent on-chain data. No persistent-blob or state-expiry EIP is scheduled.
- **EIP-7928 (block-level access lists, Glamsterdam headliner)** changes block building, not `eth_call` semantics or gas.

**Watch items:**

- **EIP-7825 (Fusaka, live):** transactions are capped at 16,777,216 gas. The EthFS render in this repo costs ~9.36M gas ([snapshots/ethfsTest.json](../../snapshots/ethfsTest.json)) — fine for off-chain `eth_call` (the cap is transaction-validation only, though individual RPC providers set their own `eth_call` caps), but an *on-chain* caller composing a file ~1.5MB+ would exceed the cap. If you expect on-chain consumers of `toString()`, the practical ceiling is now hard, not just block-gas-soft. Memory expansion is quadratic, so it dominates well before then anyway.
- **EIP-8038 (Glamsterdam, scheduled):** cold account access 2,600 → 3,000 and an added warm-access charge on `EXTCODESIZE`/`EXTCODECOPY`. For slice-per-24KB patterns this is a few thousand gas per data contract — immaterial, but it nudges toward fewer, larger slices.
- **EIP-7954 (Glamsterdam, CFI'd not final):** max code size 24KiB → 32KiB. Pure upside — fewer slices per file. (The heavier EIP-7907 metering variant was declined.)
- **EIP-7702 (Pectra, live):** `bytecode(eoa)` on a delegated EOA returns the 23-byte delegation designator (`0xef0100‖address`), not the delegate's code — by design. Only matters if someone points `bytecode()` at an EOA; worth a doc sentence.

**Verdict:** the library's premise (persistent data lives in contract code; assemble lazily; render in a view call) remains the canonical pattern with no scheduled successor. Nothing to redesign.
