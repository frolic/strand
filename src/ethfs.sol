// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { File } from "ethfs/src/File.sol";
import { IFileStore } from "ethfs/src/IFileStore.sol";

import { Strand, _Part, _Strand, _wrap } from "./Strand.sol";

IFileStore constant fileStore = IFileStore(0xFe1411d6864592549AdE050215482e4385dFa0FB);

function ethfs(string memory filename) view returns (Strand strand) {
  File memory file = fileStore.getFile(filename);
  _Strand memory _strand;
  _strand.length = file.size;
  _strand.parts = new _Part[](file.slices.length);
  for (uint256 i = 0; i < file.slices.length; i++) {
    _strand.parts[i] = _Part(
      "bc",
      file.slices[i].end - file.slices[i].start,
      abi.encode(file.slices[i].pointer, file.slices[i].start, file.slices[i].end)
    );
  }
  return _wrap(_strand);
}
