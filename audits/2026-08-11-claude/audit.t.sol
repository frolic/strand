// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { LibString } from "strand~solady/utils/LibString.sol";
import { SSTORE2 } from "strand~solady/utils/SSTORE2.sol";

import { Strand, _Part, _Strand, _unwrap, _wrap, bytecode, s } from "../../src/Strand.sol";

/// Characterization tests from a security/correctness audit. Tests prefixed
/// `test_pitfall_` assert *current* behavior that is surprising or dangerous —
/// if a fix changes that behavior, the corresponding test should be updated to
/// assert the fixed behavior.
contract AuditTest is Test {
  /// Builds and renders a bytecode strand in an external frame so out-of-gas
  /// in the render can be caught with try/catch. Takes raw args (not a Strand)
  /// because a Strand is a memory pointer and cannot cross call boundaries.
  function buildAndRender(address pointer, uint256 start, uint256 end) external view returns (string memory) {
    return bytecode(pointer, start, end).toString();
  }

  /// Renders a strand with an unhandled part kind, built inside this frame.
  function renderUnknownKind() external view returns (string memory) {
    _Strand memory inner;
    inner.parts = new _Part[](1);
    inner.parts[0] = _Part("zz", 0, "");
    return _wrap(inner).toString();
  }

  /// Naively accepts a Strand across an external call boundary.
  function echoRender(Strand strand) external view returns (string memory) {
    return strand.toString();
  }

  //--------------------------------------------------//
  // Copy-on-write: transforms never mutate the input //
  //--------------------------------------------------//

  /// `map` allocates fresh part structs, so `encodeURI` returns a new strand
  /// and leaves the original untouched.
  function test_encodeURIReturnsNewStrand() public view {
    Strand original = s("hello world");
    Strand encoded = original.encodeURI();

    assertEq(encoded.toString(), "hello%20world");
    assertEq(original.toString(), "hello world");
    assertNotEq(Strand.unwrap(original), Strand.unwrap(encoded));
  }

  /// `concat` copies part *pointers*, not part contents, so strands built with
  /// `+` share their parts with the inputs. That sharing is safe because
  /// transforms are copy-on-write: encoding the combined strand leaves the
  /// inputs untouched.
  function test_encodeURIDoesNotMutateConcatInputs() public view {
    Strand left = s("a b");
    Strand right = s("c d");
    Strand combined = left + right;

    assertEq(combined.encodeURI().toString(), "a%20bc%20d");

    assertEq(left.toString(), "a b");
    assertEq(right.toString(), "c d");
  }

  /// Encoding twice (nesting a data URI inside another data URI) double-
  /// encodes, and each level is a distinct strand.
  function test_encodeURITwiceDoubleEncodes() public view {
    Strand page = s("x y");
    assertEq(page.encodeURI().encodeURI().toString(), "x%2520y");
    assertEq(page.toString(), "x y");
  }

  /// `map` recomputes `_Strand.length` from the transformed part lengths, so
  /// `buffer.reserve` in `buildString` sees the real size.
  function test_strandLengthUpdatedByEncodeURI() public view {
    Strand strand = s("a b").encodeURI();
    assertEq(bytes(strand.toString()).length, 5); // "a%20b"
    assertEq(_unwrap(strand).length, 5);
  }

  /// `s()` keeps a reference to the caller's string rather than copying it, so
  /// later mutation of that string changes what the strand renders.
  function test_pitfall_sAliasesCallerString() public view {
    string memory contents = "hello";
    Strand strand = s(contents);

    bytes(contents)[0] = "j";

    assertEq(strand.toString(), "jello");
  }

  //--------------------------------------------//
  // Pitfall: encodeURI skips bytecode parts    //
  //--------------------------------------------//

  /// `_encodeURI` only transforms "by" parts. Bytecode parts pass through
  /// untouched — the library can't encode them without materializing the code
  /// and can't know whether they're already URI-safe. It's the caller's
  /// responsibility to only reference URI-safe content (e.g. base64) from
  /// strands they intend to encode; otherwise the rendered URI is silently
  /// malformed, as here.
  function test_pitfall_encodeURISkipsBytecodeParts() public {
    address pointer = SSTORE2.write(bytes('alert("hi there")'));

    Strand uri = (s("data:text/html,") + s("<b>x y</b>") + bytecode(pointer, 1)).encodeURI();

    string memory out = uri.toString();
    // The literal parts were encoded, but the bytecode part still contains
    // raw spaces and quotes, producing an invalid percent-encoded URI.
    assertEq(out, 'data%3Atext%2Fhtml%2C%3Cb%3Ex%20y%3C%2Fb%3Ealert("hi there")');
    assertTrue(LibString.contains(out, '"hi there"'));
  }

  //--------------------------------------//
  // Pitfall: _codeSlice bounds behaviors //
  //--------------------------------------//

  /// Out-of-range slices revert cleanly at render: end past the code (which
  /// would otherwise silently zero-pad) and start past end (which would
  /// otherwise underflow into a ~2^256 extcodecopy).
  function test_codeSliceOutOfRangeReverts() public {
    address pointer = SSTORE2.write("0123456789");
    uint256 size = pointer.code.length;

    vm.expectRevert(bytes(""));
    this.buildAndRender(pointer, 0, size + 1);

    vm.expectRevert(bytes(""));
    this.buildAndRender(pointer, 8, 3);

    // start past size with end defaulted to size.
    vm.expectRevert(bytes(""));
    this.buildAndRender(pointer, size + 1, 0);
  }

  /// The `bytecode` constructors don't validate the range (that would cost an
  /// extcodesize per part at build time), so a bad range is only caught when
  /// the strand is rendered.
  function test_pitfall_bytecodeConstructorAcceptsInvertedRange() public {
    address pointer = SSTORE2.write("0123456789");
    Strand strand = bytecode(pointer, 8, 3);
    assertEq(_unwrap(strand).length, 0); // claims empty at build time...
    vm.expectRevert(bytes(""));
    this.buildAndRender(pointer, 8, 3); // ...and reverts at render time
  }

  //---------------------------------------------//
  // Pitfall: Strand must not cross call frames  //
  //---------------------------------------------//

  /// A Strand is a memory pointer disguised as a uint256. ABI-encoding one
  /// across an external call boundary sends the *pointer*; the callee
  /// dereferences whatever happens to be at that offset in its own memory —
  /// garbage output or a revert, never the intended string. Never use Strand
  /// as a public/external param or return type, and never store one in
  /// storage.
  function test_pitfall_strandCannotCrossCallBoundary() public view {
    Strand strand = s("hello");
    // In this frame it renders fine.
    assertEq(strand.toString(), "hello");
    // Across a call boundary the pointer is meaningless.
    try this.echoRender{ gas: 5_000_000 }(strand) returns (string memory out) {
      assertNotEq(out, "hello");
    } catch { }
  }

  //-----------------------------//
  // Coverage: basic edge cases  //
  //-----------------------------//

  function test_emptyString() public view {
    assertEq(s("").toString(), "");
    assertEq((s("") + s("")).toString(), "");
    assertEq((s("a") + s("") + s("b")).toString(), "ab");
  }

  function test_bytecodeWholeCode() public {
    address pointer = SSTORE2.write("0123456789");
    // Skip the SSTORE2 STOP-byte prefix.
    assertEq(bytecode(pointer, 1).toString(), "0123456789");
  }

  function test_bytecodeSlice() public {
    address pointer = SSTORE2.write("0123456789");
    assertEq(bytecode(pointer, 3, 6).toString(), "234");
  }

  function test_bytecodeOfEmptyAccount() public view {
    // No code: extcodesize is 0, renders as empty.
    assertEq(bytecode(address(0xdead)).toString(), "");
  }

  function test_concatManyParts() public view {
    Strand strand = s("a") + s("b") + s("c") + s("d") + s("e");
    assertEq(strand.toString(), "abcde");
    assertEq(_unwrap(strand).parts.length, 5);
  }

  function test_toStringRevertsOnUnknownKind() public {
    vm.expectRevert("Unhandled chunk kind: zz");
    this.renderUnknownKind();
  }
}
