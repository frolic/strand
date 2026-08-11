// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { Base64 } from "strand~solady/utils/Base64.sol";
import { LibString } from "strand~solady/utils/LibString.sol";

import { File } from "ethfs/src/File.sol";
import { FileStore } from "ethfs/src/FileStore.sol";
import { SAFE_SINGLETON_FACTORY, SAFE_SINGLETON_FACTORY_BYTECODE } from "ethfs/test/safeSingletonFactory.sol";

import { Strand, bytecode, s } from "./Strand.sol";
import { ethfs, fileStore } from "./ethfs.sol";

contract ethfsTest is Test {
  function setUp() public {
    vm.etch(SAFE_SINGLETON_FACTORY, SAFE_SINGLETON_FACTORY_BYTECODE);
    vm.etch(address(fileStore), address(new FileStore(SAFE_SINGLETON_FACTORY)).code);
    fileStore.createFile("three.min.js", Base64.encode(bytes(vm.readFile("data/three.min.js"))));
  }

  function testFile() public {
    Strand page = s('<script src="data:text/javascript;base64,') + ethfs("three.min.js") + s('"></script>');
    Strand metadata = s('{"name":"Token","animation_url":"data:text/html,') + page.encodeURI() + s('"}');
    Strand uri = s("data:application/json,") + metadata.encodeURI();

    vm.startSnapshotGas("build token URI with EthFS file");
    string memory out = uri.toString();
    vm.stopSnapshotGas("build token URI with EthFS file");

    assertEq(bytes(out).length, 810588);
    assertEq(keccak256(bytes(out)), 0xd1ca719dcd58916bf2f6f4aaea72620cd31466edc55b5dd8c904e4dbd0e18e71);
  }
}
