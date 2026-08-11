> **Provenance:** independent audit produced by OpenAI Codex CLI (`codex exec`, v0.146.0) against a pristine copy of this repository at commit `4d88b5d`, with no access to any other audit's findings or this branch's changes. Recorded verbatim (only sandbox file paths rewritten to repo-relative). Several findings (M-01, M-02, L-01, the unused-param warning, and the H-01 documentation recommendation) were independently found and are already addressed on this branch — see [2026-08-11-claude/audit.md](../2026-08-11-claude/audit.md).

# Strand Solidity Library — Security and Correctness Audit

## Executive summary

Strand’s bytecode-backed string composition remains a useful EVM pattern, particularly for large immutable assets. However, the current API represents a memory pointer as an ordinary `uint256`-backed value type. Solidity consequently allows `Strand` values to cross external-call and storage boundaries even though they are only valid inside the memory frame where they were created.

This is the most serious architectural issue. Consumers can write code that compiles normally but silently loses strings, reverts, exhausts gas, or accesses attacker-selected memory.

The audit also identified unsafe bytecode-slice bounds handling, mutating transform semantics, stale cached lengths, and quadratic concatenation costs.

| Severity | Count |
|---|---:|
| High | 1 |
| Medium | 2 |
| Low | 3 |
| Informational | 3 |

No direct asset-theft vulnerability was identified in the repository itself. The library is nevertheless not safe for unrestricted production use without documenting and enforcing its memory-frame limitations.

## Scope

Reviewed:

- [src/Strand.sol](../../src/Strand.sol)
- [src/transforms.sol](../../src/transforms.sol)
- [src/utils.sol](../../src/utils.sol)
- [src/ethfs.sol](../../src/ethfs.sol)
- Both test contracts, repository configuration, package metadata, and directly relevant pinned Solady/EthFS implementations.

The configured Forge suite passes:

```text
4 tests passed; 0 failed; 0 skipped
```

Compiler warning:

```text
Unused function parameter `length` in transforms.sol:_toString
```

No fuzz, invariant, malformed-input, storage-boundary, external-call-boundary, or slice-boundary tests are currently present.

---

# Findings

## High severity

### H-01 — `Strand` disguises a frame-local memory pointer as an ABI- and storage-compatible integer

**Affected code:** [Strand.sol:6](../../src/Strand.sol:6), [Strand.sol:63](../../src/Strand.sol:63), [Strand.sol:69](../../src/Strand.sol:69)

`Strand` is declared as:

```solidity
type Strand is uint256;
```

But `_wrap` stores the address of an in-memory `_Strand` struct in that integer, and `_unwrap` later treats the integer as a memory pointer:

```solidity
assembly {
    _strand := strand
}
```

The pointer is only meaningful during the current EVM call frame. Solidity does not know this and therefore permits a `Strand` to be:

- stored in contract storage;
- returned through an external ABI;
- supplied as an external function argument;
- passed through an external self-call;
- emitted and later reconstructed as a numeric value.

Each external call has independent memory. A pointer returned by one call does not refer to the same object in another call.

#### Concrete failure scenario

A consumer can write code that appears type-safe:

```solidity
Strand private saved;

function save() external {
    saved = s("important metadata");
}

function read() external view returns (string memory) {
    return saved.toString();
}
```

`save()` persists something such as `0x80`, not the string representation. During `read()`, memory at `0x80` contains unrelated call-frame data. Depending on that data, `toString()` may:

- return an empty or corrupted string;
- interpret unrelated memory as a parts array;
- loop over a nonsensical array length;
- attempt a huge allocation and exhaust gas;
- revert while decoding a fabricated part.

An externally supplied `Strand` is worse: the caller controls the numeric “pointer.” If a consuming contract exposes a function accepting `Strand`, the value can be aimed at memory populated by the ABI decoder and interpreted as an `_Strand`. `map()` then writes through the resulting fabricated pointers at [utils.sol:13-19](../../src/utils.sol:13). The exact exploitability depends on the surrounding contract’s memory layout, but denial of service and corrupted return values are straightforward.

#### Recommendation

Do not encode a memory pointer in a user-defined value type whose underlying type is ABI-compatible.

Preferred options:

1. Represent `Strand` as an ordinary memory struct:

   ```solidity
   struct Strand {
       uint256 length;
       Part[] parts;
   }
   ```

2. If operator overloading requires a value type, redesign the representation so the wrapped integer is genuine data—not an address into transient memory.

3. Until redesigned, explicitly document that `Strand`:

   - must never cross an external-call boundary;
   - must never be stored;
   - must never be accepted from an untrusted source;
   - is valid only inside the call frame where it was constructed.

Documentation mitigates accidental misuse but does not make the type safe.

---

## Medium severity

### M-01 — Invalid bytecode slices can underflow in assembly and consume all available gas

**Affected code:** [Strand.sol:26-31](../../src/Strand.sol:26), [transforms.sol:39-50](../../src/transforms.sol:39)

The constructor handles `end <= start` by recording a zero length:

```solidity
end > start ? end - start : 0
```

But `_codeSlice` performs its own unchecked assembly subtraction:

```solidity
let length := sub(end, start)
```

Only `end > extcodesize(pointer)` is rejected. There is no check that:

- `start <= end`;
- `start <= extcodesize(pointer)`.

Moreover, `end == 0` is treated as a sentinel meaning “use the full code size.” Therefore:

```solidity
bytecode(pointer, codeSize + 1, 0)
```

becomes `sub(codeSize, codeSize + 1) == 2²⁵⁶ - 1`.

The subsequent memory-pointer calculation and `EXTCODECOPY` trigger catastrophic memory expansion or out-of-gas rather than a controlled bounds error.

#### Concrete failure scenario

An NFT renderer exposes user-selected bytecode ranges. A caller supplies:

```text
start = codeSize + 1
end   = 0
```

The `Strand` is constructed successfully. Rendering it later exhausts the transaction’s gas, potentially making token metadata or another composed response permanently unreadable if the range was persisted separately.

Supplying `end < start` with nonzero `end` has the same underflow behavior.

#### Recommendation

Resolve the sentinel and validate bounds before entering assembly:

```solidity
uint256 size = pointer.code.length;
uint256 resolvedEnd = end == 0 ? size : end;

if (start > resolvedEnd || resolvedEnd > size) {
    revert InvalidCodeSlice(pointer, start, resolvedEnd, size);
}
```

Then pass `resolvedEnd - start` into assembly. Use a typed custom error rather than `revert(0, 0)`.

Define explicitly whether `(start, end) == (0, 0)` means an empty slice or the entire contract.

---

### M-02 — Transforms mutate their input `Strand`, violating normal value-like expectations

**Affected code:** [transforms.sol:9-14](../../src/transforms.sol:9), [utils.sol:13-21](../../src/utils.sol:13)

`encodeURI()` looks like a functional transformation returning a new `Strand`, but `map()` unwraps and edits the original parts array in place:

```solidity
_Strand memory _strand = _unwrap(strand);
_strand.parts[i].kind = kind;
_strand.parts[i].length = length;
_strand.parts[i].data = data;
```

Since both the argument and returned value refer to the same memory object, the source is changed.

#### Concrete failure scenario

```solidity
Strand raw = s("a b");
Strand encoded = raw.encodeURI();

assertEq(raw.toString(), "a b");       // Fails: raw is now "a%20b"
assertEq(encoded.toString(), "a%20b");
```

A renderer that needs both raw JSON and URI-encoded JSON can unknowingly double-encode or output the encoded form in both locations. Repeated application also produces progressively encoded `%` characters.

The behavior is particularly surprising because `Strand` is presented as a value type and the transformation is declared as a free function returning a value.

#### Recommendation

Make transforms copy-on-write:

- allocate a new `_Part[]`;
- copy unchanged parts;
- write transformed parts into the new array;
- calculate a new aggregate length;
- return a pointer to a distinct `_Strand`.

If in-place mutation is intentional, rename the API accordingly and document aliasing prominently. A functional API is safer and better matches current usage.

---

## Low severity

### L-01 — Transformations do not update the aggregate cached length

**Affected code:** [utils.sol:13-21](../../src/utils.sol:13), [utils.sol:29-32](../../src/utils.sol:29)

`map()` updates each `_Part.length` but never recomputes `_Strand.length`.

URI encoding often expands data substantially. `buildString()` consequently reserves the original, smaller size and relies on repeated dynamic-buffer reallocation as encoded parts are appended.

This does not corrupt the final string because Solady’s buffer grows automatically, but it defeats the purpose of cached sizing and causes unnecessary copying and memory expansion.

#### Recommendation

Accumulate transformed part lengths during `map()` and assign the total to `_strand.length`. Use checked arithmetic, as Solidity does outside assembly.

Add tests asserting internal length consistency after one and multiple transforms.

---

### L-02 — Open-ended bytecode slices are always recorded as zero-length

**Affected code:** [Strand.sol:18-30](../../src/Strand.sol:18)

Both `bytecode(location)` and `bytecode(location, start)` pass `end = 0`. The constructor consequently records the part length as zero even though rendering copies up to `extcodesize(location)`.

This creates systematic under-reservation for the convenient overloads. Large SSTORE2-backed strings therefore undergo avoidable reallocations and copying.

It also means aggregate length no longer describes the output length immediately after valid construction.

#### Recommendation

Because obtaining `location.code.length` requires `view`, either:

- make these constructors `view` and calculate the actual length; or
- represent “unknown length” explicitly and perform a sizing pass before reserving.

Do not use zero as both a meaningful endpoint and an open-ended sentinel without explicit API documentation.

---

### L-03 — Repeated `+` concatenation has quadratic construction cost

**Affected code:** [Strand.sol:34-47](../../src/Strand.sol:34)

Every concatenation allocates a new parts array and copies every part from both operands. Building a strand as:

```solidity
out = out + next;
```

for `n` fragments copies approximately `1 + 2 + … + n` parts: `O(n²)` work and memory churn.

This is a correctness-adjacent availability concern for on-chain rendering. A design advertised as a string builder may encourage exactly this incremental pattern.

#### Recommendation

Provide one or more of:

- a bulk `concat(Strand[] memory)` that measures once and copies once;
- a mutable builder with capacity;
- a tree/rope representation flattened only by `toString()`;
- documentation recommending balanced concatenation for large inputs.

Add gas-scaling tests at 10, 100, and 1,000 parts.

---

## Informational observations

### I-01 — `_codeSlice` leaves the free-memory pointer unaligned

**Affected code:** [transforms.sol:46-50](../../src/transforms.sol:46)

The free-memory pointer is advanced to exactly `out + 32 + length`, not the next 32-byte boundary. EVM memory itself permits unaligned access, and the current call path worked in testing, but this violates Solidity’s conventional allocator layout and makes composition with assembly libraries more fragile.

Advance it with:

```solidity
mstore(0x40, and(add(add(out, 0x3f), length), not(0x1f)))
```

Also zero the padding word.

### I-02 — EthFS integration is hard-coded to one chain/address assumption

**Affected code:** [ethfs.sol:9-12](../../src/ethfs.sol:9)

The module always calls `0xFe14…a0FB`. On a chain where that address is absent or hosts different code, `getFile()` will revert or return untrusted metadata.

Document supported networks or accept an `IFileStore` argument. If the address is expected to be deterministic across networks, validate its deployed code hash during integration or deployment.

### I-03 — Test coverage is insufficient for an assembly-heavy library

Existing tests cover:

- one literal;
- one two-part concatenation;
- one URI composition;
- one large EthFS file.

Missing cases include:

- empty strings and empty bytecode;
- `start == end`, `start > end`, and `start > codeSize`;
- nonexistent accounts;
- transform aliasing and repeated transforms;
- stored and externally round-tripped `Strand` values;
- fuzzed concatenation equivalence;
- cached-length invariants;
- many-part gas scaling;
- byte strings containing zero and invalid UTF-8;
- multiple EthFS slices and malformed slice metadata.

---

# EVM roadmap assessment

## Current direction

The core idea—keeping large immutable data in deployed bytecode and materializing it with `EXTCODECOPY`—remains directionally sound on today’s EVM.

Compared with storage reads, bytecode blobs remain attractive for immutable assets. Cancun’s EIP-6780 strengthened the persistence assumption for ordinary, already-deployed data contracts: `SELFDESTRUCT` no longer deletes their code unless destruction occurs in the same transaction as creation. This reduces the historical risk of bytecode pointers disappearing after deployment. See [EIP-6780](https://eips.ethereum.org/EIPS/eip-6780).

That benefit applies most strongly to purpose-built SSTORE2/EthFS pointers. Arbitrary addresses should not be treated as equally stable.

## EIP-7702 delegation accounts

EIP-7702 changes the meaning of “an address with code.” An authorized EOA stores a 23-byte delegation indicator:

```text
0xef0100 || target
```

Calls follow the delegation, but `EXTCODESIZE`, `EXTCODECOPY`, and `EXTCODEHASH` operate on the indicator itself rather than the delegated implementation. See [EIP-7702](https://eips.ethereum.org/EIPS/eip-7702).

Consequences for Strand:

- `bytecode(delegatedEOA)` returns the 23-byte indicator, not the implementation bytecode.
- Code obtained from arbitrary user-selected addresses is no longer necessarily the code that executes when called.
- An EOA can update or clear its delegation in later authorization transactions, so its copied bytes are not immutable.

This does not invalidate EthFS/SSTORE2 pointer contracts, but the generic `bytecode(address)` API should document that it reads raw account code and does not resolve delegations.

## Contract-size proposals: EIP-7907 and EIP-7954

Two reviewed proposals seek to raise the EIP-170 runtime-code limit from 24 KiB to 64 KiB:

- [EIP-7907](https://eips.ethereum.org/EIPS/eip-7907) also proposes proportional cold-code loading charges, including additional costs for `EXTCODECOPY` when accessing code beyond the old 24 KiB threshold.
- [EIP-7954](https://eips.ethereum.org/EIPS/eip-7954) proposes a simpler increase to runtime- and initcode-size limits.

If a variant is adopted:

- EthFS can potentially use fewer, larger data contracts.
- Strand can represent a large file with fewer `_Part` entries.
- This reduces its per-part loop and concatenation overhead.
- Under EIP-7907 specifically, cold access to large bytecode containers may become more expensive, partially offsetting the benefit.

Neither proposal makes Strand obsolete. It strengthens the case for bulk bytecode slices while making gas benchmarking fork-dependent. The library should not hard-code the current `0x6000` deployment limit in its own abstractions.

## EOF and bytecode-as-data

The former EOF data-section proposal, EIP-7480, is currently marked stagnant. Its design explicitly discouraged external contracts from using another contract’s EOF data section: it proposed no `EXTDATACOPY`, and described `EXTCODECOPY` as unable to copy an EOF target’s data section. See [EIP-7480](https://eips.ethereum.org/EIPS/eip-7480).

Had that design shipped broadly, newly deployed EOF data containers would not have been drop-in replacements for legacy SSTORE2 contracts. Existing legacy bytecode contracts would still require backward compatibility, so Strand would not immediately break.

As of this audit, EOF is not an imminent reason to abandon the approach. It is, however, the clearest long-term architectural risk: future structured-code formats may intentionally separate executable code from bulk data and may not expose external data-copy operations.

Recommendation: keep the bytecode reader behind a small adapter boundary so an eventual alternative—dedicated data contracts, protocol-level data sections, or another storage mechanism—can be added without changing the string-composition API.

## Gas repricing and L1 scaling roadmap

Upcoming Ethereum work is increasingly concerned with accurate state and code-access pricing. Glamsterdam is planned for the second half of 2026, with its exact EIP set still evolving. Its published goals include higher L1 capacity and more sustainable database pricing. See the official [Glamsterdam roadmap](https://ethereum.org/roadmap/glamsterdam/).

The main risk to Strand is economic, not semantic:

- memory expansion remains quadratic at sufficiently large sizes;
- returning an 810 KB string is inherently expensive;
- cold account accesses are charged per distinct pointer;
- future code-loading metering may raise the price of very large pointer contracts;
- transaction or block gas policies can make giant on-chain renders impractical even if the opcodes remain available.

The existing EthFS test already consumes roughly 9.7 million gas to materialize an approximately 810 KB URI. Production systems should treat outputs of that scale as near block-resource workloads, benchmark them against each target network, and avoid requiring successful materialization inside state-changing critical paths.

## Roadmap conclusion

The bytecode-backed storage approach is not obsolete and is unlikely to become so abruptly because legacy contracts require long-lived compatibility. Purpose-built immutable pointer contracts remain a reasonable foundation.

The architecture should nevertheless evolve in three ways:

1. Separate the safe string-builder abstraction from the storage backend.
2. Treat arbitrary account code, EIP-7702 delegation accounts, and immutable SSTORE2/EthFS pointers as distinct sources.
3. Remove the transient-memory pointer masquerading as an ordinary Solidity value.

The third item is urgent: protocol evolution does not threaten Strand as directly as its current type representation does.