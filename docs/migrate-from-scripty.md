# Migrating from scripty.sol

Strand replaces [scripty.sol](https://github.com/intartnft/scripty.sol) for assembling on-chain HTML/metadata: instead of a deployed builder contract that fetches whole scripts through storage-adapter calls, Strand composes references and reads bytecode directly into the final buffer with `EXTCODECOPY` at render time.

## Gas

Measured by [scripty.t.sol](../benchmarks/scripty.t.sol) — a full NFT token URI (base64 asset from EthFS in an HTML page, embedded as a URL-encoded `animation_url` data URI inside URL-encoded JSON metadata) built with `ScriptyBuilderV2.getHTMLURLSafe` + `ETHFSV2FileStorage` vs Strand. "Strand" is the idiomatic style (plain-text literals, `encodeURI()` at render time); "Strand pre-encoded" authors the literals already percent-encoded — exactly what scripty's hardcoded URL-safe wrappers do — and produces byte-identical output to scripty (asserted by hash in the test):

| asset size (base64) | scripty | Strand | Strand pre-encoded |
|---|---|---|---|
| 3KB | 96,083 | 102,167 (−6%) | 39,499 (**2.4×**) |
| 43KB | 833,791 | 258,028 (**3.2×**) | — |
| 810KB (three.js) | 49,003,257 | 9,825,573 (**5.0×**) | 9,416,229 (**5.2×**) |
| 810KB, external `tokenURI()` end to end | 66,897,548 | 26,149,160 (**2.6×**) | — |

Two separate effects are visible:

- **The payload path** is where the big savings live. scripty materializes the full asset several times — EthFS `File.read()` assembles it, the `getContent` adapter ABI-encodes it across an external call, the builder decodes and appends it, and your JSON wrap copies the result again. Strand copies once, `EXTCODECOPY`ing each slice directly into the output buffer. The extra copies also inflate peak memory, and EVM memory expansion is quadratic — that's most of the 49M.
- **Literal encoding** explains the small-file column. scripty's wrappers are pre-encoded at authoring time, so it does zero encoding on-chain; idiomatic Strand percent-encodes its literals at render time via `encodeURI()`, which costs a roughly flat ~60k here. That's a readability convenience, not part machinery — write your literals pre-encoded (skip `encodeURI()` entirely) and Strand is strictly cheaper at every size.

The end-to-end row is a caveat for *on-chain* consumers: an external `tokenURI()` call ABI-copies the 810KB result out of the callee and back into the caller, adding ~16M to both sides. If another contract needs the rendered string, compile Strand into that contract and render in-frame instead of calling `tokenURI()` externally.

The absolute numbers matter post-Fusaka: [EIP-7825](https://eips.ethereum.org/EIPS/eip-7825) caps any transaction at 16,777,216 gas. Off-chain `eth_call` (`tokenURI`) is unaffected either way, but the scripty version of the 810KB page can no longer be rendered *on-chain* at all (49M > 16.7M), while the Strand version fits with headroom.

## Concept mapping

| scripty | Strand |
|---|---|
| `HTMLRequest` / `HTMLTag[]` | a `Strand` built with `+` |
| `tagOpen` / `tagClose` literals | `s("...")` parts |
| `tagContent` (inline script) | `s(script)` |
| `contractAddress` + `ETHFSV2FileStorage` + `name` | `ethfs(name)` — no adapter contract |
| `contractAddress` + `ScriptyStorageV2` | `bytecode(pointer, 1)` on the SSTORE2 pointer |
| `HTMLTagType.scriptBase64DataURI` | `s('<script src="data:text/javascript;base64,') + ethfs(name) + s('"></script>')` |
| `HTMLTagType.scriptGZIPBase64DataURI` | same, with `type="text/javascript+gzip"` in your literal |
| `getHTMLURLSafe` | compose, then `.encodeURI()` — or author literals pre-encoded (like scripty's wrappers) and skip it |
| `getHTML` (raw) | compose, then `.toString()` |
| `getEncodedHTML` (base64 of whole page) | prefer `encodeURI()`: already-base64 payloads pass through at 1× growth and zero work, while whole-page base64 re-encodes them at 4/3. If you truly need it: `Base64.encode(bytes(page.toString()))` (e.g. solady) |
| deployed builder + storage contracts | a library compiled into your contract; the only external reads are the data contracts themselves |

## Before / after

scripty:

```solidity
HTMLTag[] memory bodyTags = new HTMLTag[](1);
bodyTags[0].name = "three.min.js";
bodyTags[0].contractAddress = ethfsFileStorageAddress;
bodyTags[0].tagType = HTMLTagType.scriptBase64DataURI;

HTMLRequest memory htmlRequest;
htmlRequest.bodyTags = bodyTags;

return string(
  abi.encodePacked(
    "data:application/json,%7B%22name%22%3A%22Token%22%2C%22animation_url%22%3A%22",
    IScriptyBuilderV2(scriptyBuilderAddress).getHTMLURLSafe(htmlRequest),
    "%22%7D"
  )
);
```

Strand:

```solidity
Strand script = s('<script src="data:text/javascript;base64,') + ethfs("three.min.js") + s('"></script>');
Strand page = s('<html><head></head><body>') + script + s('</body></html>');
Strand metadata = s('{"name":"Token","animation_url":"data:text/html,') + page.encodeURI() + s('"}');
Strand uri = s("data:application/json,") + metadata.encodeURI();
return uri.toString();
```

Note the JSON is plain text — `encodeURI()` does the escaping that scripty required you to hand-encode (`%7B%22name%22...`) in a comment-annotated blob.

## What to watch when migrating

1. **Tag types are just literals now.** scripty's enum picked wrapper strings for you; with Strand you write the `<script ...>` wrapper yourself. Copy the exact wrappers from `ScriptyCore.tagOpenCloseForHTMLTag` if you want identical markup.
2. **No render-time base64.** scripty's `HTMLTagType.script` base64-encodes raw content inside `getHTMLURLSafe` (its own docs warn this risks gas-out). Strand doesn't encode bytecode content at all — store scripts base64-encoded (the EthFS convention), which is also what scripty recommends.
3. **URI safety of referenced code is your invariant.** `encodeURI()` encodes `s(...)` literals and passes bytecode parts through untouched. This is the same assumption `scriptBase64DataURI` made (content already URI-safe base64) — it's just explicit now. See the README design notes.
4. **Encoding nesting differs cosmetically.** scripty single-encodes the `<html><head><body>` wrapper and double-encodes script tags; Strand's idiomatic flow double-encodes the whole page. Both decode to the same document; outputs differ by a few dozen bytes.
5. **A `Strand` never leaves the call frame.** It's a memory pointer — always `.toString()` before returning or passing across a call boundary. (scripty returned materialized `bytes`, so this footgun didn't exist there.)
6. **No deployed infrastructure.** There is no builder or storage-adapter address to configure per chain; anything readable with `EXTCODECOPY` (SSTORE2 pointers, EthFS slices) is a valid source. The EthFS `FileStore` address in [ethfs.sol](../src/ethfs.sol) is the deterministic v2 deploy, the same one scripty's `ETHFSV2FileStorage` wraps.
