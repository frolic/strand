// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibString } from "strand~solady/utils/LibString.sol";

import { Strand } from "./Strand.sol";
import { buildString, map } from "./utils.sol";

function encodeURI(Strand strand) view returns (Strand) {
  return map(strand, _encodeURI);
}

function toString(Strand strand) view returns (string memory) {
  return buildString(strand, _toString);
}

//--------------------//  INTERNAL  //--------------------//

function _encodeURI(bytes2 kind, uint256 length, bytes memory data) pure returns (bytes2, uint256, bytes memory) {
  if (kind == "by") {
    bytes memory encoded = bytes(LibString.encodeURIComponent(string(data)));
    return (kind, encoded.length, encoded);
  }
  // Bytecode parts pass through unencoded: their content can't be encoded
  // without materializing it, and the library can't know whether it's already
  // URI-safe. It's the caller's responsibility to only reference URI-safe
  // content (e.g. base64) from strands they intend to encode — see README.
  return (kind, length, data);
}

function _toString(bytes2 kind, uint256, bytes memory data) view returns (string memory out) {
  if (kind == "by") {
    return string(data);
  }
  if (kind == "bc") {
    (address pointer, uint256 start, uint256 end) = abi.decode(data, (address, uint256, uint256));
    return string(_codeSlice(pointer, start, end));
  }

  revert(string.concat("Unhandled chunk kind: ", LibString.fromSmallString(kind)));
}

function _codeSlice(address pointer, uint256 start, uint256 end) view returns (bytes memory out) {
  assembly {
    let size := extcodesize(pointer)
    if iszero(end) { end := size }

    // Bounds check: end past code would silently zero-pad the string, and
    // start past end would underflow the length below.
    if or(gt(end, size), gt(start, end)) { revert(0, 0) }

    let length := sub(end, start)
    out := mload(0x40)
    mstore(out, length)
    extcodecopy(pointer, add(out, 32), start, length)
    mstore(0x40, add(add(out, 32), length))
  }
}
