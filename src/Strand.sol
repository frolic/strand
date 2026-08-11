// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { encodeURI, toString } from "./transforms.sol";

type Strand is uint256;

using { concat as +, encodeURI, toString } for Strand global;

function s(string memory contents) pure returns (Strand strand) {
  _Strand memory _strand;
  _strand.parts = new _Part[](1);
  _strand.parts[0] = _Part("by", bytes(contents).length, bytes(contents));
  _strand.length = _strand.parts[0].length;
  return _wrap(_strand);
}

function bytecode(address location) pure returns (Strand strand) {
  return bytecode(location, 0, 0);
}

function bytecode(address location, uint256 start) pure returns (Strand strand) {
  return bytecode(location, start, 0);
}

function bytecode(address location, uint256 start, uint256 end) pure returns (Strand strand) {
  _Strand memory _strand;
  _strand.parts = new _Part[](1);
  _strand.parts[0] = _Part("bc", end > start ? end - start : 0, abi.encode(location, start, end));
  _strand.length = _strand.parts[0].length;
  return _wrap(_strand);
}

function concat(Strand left, Strand right) pure returns (Strand strand) {
  _Strand memory a = _unwrap(left);
  _Strand memory b = _unwrap(right);

  _Part[] memory parts = new _Part[](a.parts.length + b.parts.length);

  for (uint256 i = 0; i < a.parts.length; i++) {
    parts[i] = a.parts[i];
  }
  for (uint256 i = 0; i < b.parts.length; i++) {
    parts[a.parts.length + i] = b.parts[i];
  }

  return _wrap(_Strand(a.length + b.length, parts));
}

//--------------------//  INTERNAL  //--------------------//

struct _Strand {
  /// Cached total so buildString can reserve the output buffer once —
  /// measured cheaper than a sizing pass or letting the buffer grow.
  /// Open-ended bytecode parts contribute 0 (size unknown until render).
  uint256 length;
  _Part[] parts;
}

struct _Part {
  bytes2 kind;
  uint256 length;
  bytes data;
}

function _unwrap(Strand strand) pure returns (_Strand memory _strand) {
  assembly {
    _strand := strand
  }
}

function _wrap(_Strand memory _strand) pure returns (Strand strand) {
  assembly {
    strand := _strand
  }
}
