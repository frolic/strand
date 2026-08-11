// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Strand, _Part, _Strand, _unwrap, _wrap } from "./Strand.sol";
import { DynamicBufferLib } from "strand~solady/utils/DynamicBufferLib.sol";

using DynamicBufferLib for DynamicBufferLib.DynamicBuffer;

/// Copy-on-write: allocates fresh part structs (data bytes are shared unless
/// the transform replaces them) so the input strand — and anything sharing
/// parts with it via concat — is never mutated.
function map(
  Strand strand,
  function(bytes2, uint256, bytes memory) view returns (bytes2, uint256, bytes memory) transform
) view returns (Strand) {
  _Strand memory input = _unwrap(strand);
  _Strand memory output;
  output.parts = new _Part[](input.parts.length);
  for (uint256 i = 0; i < input.parts.length; i++) {
    (bytes2 kind, uint256 length, bytes memory data) =
      transform(input.parts[i].kind, input.parts[i].length, input.parts[i].data);
    output.parts[i] = _Part(kind, length, data);
    output.length += length;
  }
  return _wrap(output);
}

function buildString(Strand strand, function(bytes2, uint256, bytes memory) view returns (string memory) transform)
  view
  returns (string memory)
{
  DynamicBufferLib.DynamicBuffer memory buffer;
  _Strand memory _strand = _unwrap(strand);
  buffer.reserve(_strand.length);
  for (uint256 i = 0; i < _strand.parts.length; i++) {
    buffer.p(bytes(transform(_strand.parts[i].kind, _strand.parts[i].length, _strand.parts[i].data)));
  }
  return buffer.s();
}
