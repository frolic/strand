// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { Base64 } from "strand~solady/utils/Base64.sol";

import { FileStore } from "ethfs/src/FileStore.sol";
import { SAFE_SINGLETON_FACTORY, SAFE_SINGLETON_FACTORY_BYTECODE } from "ethfs/test/safeSingletonFactory.sol";

import { ScriptyBuilderV2 } from "scripty/ScriptyBuilderV2.sol";
import { HTMLRequest, HTMLTag, HTMLTagType } from "scripty/core/ScriptyStructs.sol";
import { ETHFSV2FileStorage } from "scripty/externalStorage/ethfs/ETHFSV2FileStorage.sol";

import { Strand, s } from "../src/Strand.sol";
import { ethfs, fileStore } from "../src/ethfs.sol";

/// NFT contract using scripty end to end, mirroring scripty's own
/// EthFS_P5_URLSafe example: pre-encoded JSON literal wrapping a URL-safe
/// html data URI whose base64 script is fetched via the EthFS adapter.
contract ScriptyNFT {
  ScriptyBuilderV2 immutable builder;
  ETHFSV2FileStorage immutable ethfsStorage;

  constructor(ScriptyBuilderV2 _builder, ETHFSV2FileStorage _ethfsStorage) {
    builder = _builder;
    ethfsStorage = _ethfsStorage;
  }

  function tokenURI(uint256) external view returns (string memory) {
    HTMLTag[] memory bodyTags = new HTMLTag[](1);
    bodyTags[0].name = "three.min.js";
    bodyTags[0].contractAddress = address(ethfsStorage);
    bodyTags[0].tagType = HTMLTagType.scriptBase64DataURI;

    HTMLRequest memory htmlRequest;
    htmlRequest.bodyTags = bodyTags;

    return string(
      abi.encodePacked(
        "data:application/json,%7B%22name%22%3A%22Token%22%2C%22animation_url%22%3A%22",
        builder.getHTMLURLSafe(htmlRequest),
        "%22%7D"
      )
    );
  }
}

/// NFT contract using Strand end to end, idiomatic style: plain-text
/// literals encoded at render time.
contract StrandNFT {
  function tokenURI(uint256) external view returns (string memory) {
    Strand page = s('<html><head></head><body><script src="data:text/javascript;base64,') + ethfs("three.min.js")
      + s('"></script></body></html>');
    Strand metadata = s('{"name":"Token","animation_url":"data:text/html,') + page.encodeURI() + s('"}');
    return (s("data:application/json,") + metadata.encodeURI()).toString();
  }
}

/// Gas comparison for the scripty.sol migration doc: the same token URI (an
/// html page loading a base64 script from EthFS, wrapped in URL-encoded JSON
/// metadata) built with ScriptyBuilderV2 vs Strand. The outputs are not
/// byte-identical (scripty encodes its html wrapper once, Strand twice) but
/// decode to the same document and differ by <100 bytes.
contract ScriptyComparisonTest is Test {
  ScriptyBuilderV2 builder;
  ETHFSV2FileStorage ethfsStorage;

  function setUp() public {
    vm.etch(SAFE_SINGLETON_FACTORY, SAFE_SINGLETON_FACTORY_BYTECODE);
    vm.etch(address(fileStore), address(new FileStore(SAFE_SINGLETON_FACTORY)).code);
    fileStore.createFile("three.min.js", Base64.encode(bytes(vm.readFile("data/three.min.js"))));

    builder = new ScriptyBuilderV2();
    ethfsStorage = new ETHFSV2FileStorage(address(fileStore));

    // ~3KB of script for the small-payload comparison.
    bytes memory smallScript;
    for (uint256 i = 0; i < 32; i++) {
      smallScript = bytes.concat(smallScript, 'console.log("hello from a small but not tiny on-chain script");\n');
    }
    fileStore.createFile("app.js", Base64.encode(smallScript));

    // ~43KB base64 for the mid-size comparison.
    bytes memory midScript;
    for (uint256 i = 0; i < 512; i++) {
      midScript = bytes.concat(midScript, 'console.log("hello from a small but not tiny on-chain script");\n');
    }
    fileStore.createFile("mid.js", Base64.encode(midScript));
  }

  function _scriptyTokenURI(string memory filename) internal view returns (string memory) {
    HTMLTag[] memory bodyTags = new HTMLTag[](1);
    bodyTags[0].name = filename;
    bodyTags[0].contractAddress = address(ethfsStorage);
    bodyTags[0].tagType = HTMLTagType.scriptBase64DataURI;

    HTMLRequest memory htmlRequest;
    htmlRequest.bodyTags = bodyTags;

    return string(
      abi.encodePacked(
        "data:application/json,%7B%22name%22%3A%22Token%22%2C%22animation_url%22%3A%22",
        builder.getHTMLURLSafe(htmlRequest),
        "%22%7D"
      )
    );
  }

  function _strandTokenURI(string memory filename) internal view returns (string memory) {
    Strand page = s('<html><head></head><body><script src="data:text/javascript;base64,') + ethfs(filename)
      + s('"></script></body></html>');
    Strand metadata = s('{"name":"Token","animation_url":"data:text/html,') + page.encodeURI() + s('"}');
    return (s("data:application/json,") + metadata.encodeURI()).toString();
  }

  /// Same output as `_scriptyTokenURI`, byte for byte: literals are authored
  /// pre-encoded (as scripty's hardcoded wrappers are), so no `encodeURI`
  /// pass runs at render time. Isolates Strand's part machinery from the
  /// cost of runtime percent-encoding.
  function _strandPreEncodedTokenURI(string memory filename) internal view returns (string memory) {
    return (
      s(
        "data:application/json,%7B%22name%22%3A%22Token%22%2C%22animation_url%22%3A%22data%3Atext%2Fhtml%2C%3Chtml%3E%3Chead%3E%3C%2Fhead%3E%3Cbody%3E%253Cscript%2520src%253D%2522data%253Atext%252Fjavascript%253Bbase64%252C"
      ) + ethfs(filename) + s("%2522%253E%253C%252Fscript%253E%3C%2Fbody%3E%3C%2Fhtml%3E%22%7D")
    ).toString();
  }

  function testStrandPreEncodedMatchesScriptyOutput() public {
    assertEq(keccak256(bytes(_strandPreEncodedTokenURI("app.js"))), keccak256(bytes(_scriptyTokenURI("app.js"))));
  }

  function testScriptyTokenURI() public {
    vm.startSnapshotGas("scripty: 810KB EthFS file");
    string memory out = _scriptyTokenURI("three.min.js");
    vm.stopSnapshotGas("scripty: 810KB EthFS file");

    assertEq(bytes(out).length, 810657);
  }

  function testStrandTokenURI() public {
    vm.startSnapshotGas("strand: 810KB EthFS file");
    string memory out = _strandTokenURI("three.min.js");
    vm.stopSnapshotGas("strand: 810KB EthFS file");

    assertEq(bytes(out).length, 810687);
  }

  /// End-to-end external tokenURI() calls, as a marketplace or on-chain
  /// consumer would pay them (includes the return-data copy both ways).
  /// Separate tests so each call starts from a fresh caller frame.
  function testScriptyNFTTokenURI() public {
    ScriptyNFT scriptyNFT = new ScriptyNFT(builder, ethfsStorage);
    vm.startSnapshotGas("scripty NFT: tokenURI() with 810KB EthFS file");
    string memory out = scriptyNFT.tokenURI(0);
    vm.stopSnapshotGas("scripty NFT: tokenURI() with 810KB EthFS file");
    assertEq(bytes(out).length, 810657);
  }

  function testStrandNFTTokenURI() public {
    StrandNFT strandNFT = new StrandNFT();
    vm.startSnapshotGas("strand NFT: tokenURI() with 810KB EthFS file");
    string memory out = strandNFT.tokenURI(0);
    vm.stopSnapshotGas("strand NFT: tokenURI() with 810KB EthFS file");
    assertEq(bytes(out).length, 810687);
  }

  function testScriptyMidTokenURI() public {
    vm.startSnapshotGas("scripty: 43KB EthFS file");
    string memory out = _scriptyTokenURI("mid.js");
    vm.stopSnapshotGas("scripty: 43KB EthFS file");
    assertGt(bytes(out).length, 43000);
  }

  function testStrandMidTokenURI() public {
    vm.startSnapshotGas("strand: 43KB EthFS file");
    string memory out = _strandTokenURI("mid.js");
    vm.stopSnapshotGas("strand: 43KB EthFS file");
    assertGt(bytes(out).length, 43000);
  }

  function testStrandPreEncodedTokenURI() public {
    vm.startSnapshotGas("strand pre-encoded: 810KB EthFS file");
    string memory out = _strandPreEncodedTokenURI("three.min.js");
    vm.stopSnapshotGas("strand pre-encoded: 810KB EthFS file");
    assertEq(bytes(out).length, 810657);
  }

  function testStrandPreEncodedSmallTokenURI() public {
    vm.startSnapshotGas("strand pre-encoded: 3KB EthFS file");
    string memory out = _strandPreEncodedTokenURI("app.js");
    vm.stopSnapshotGas("strand pre-encoded: 3KB EthFS file");
    assertEq(bytes(out).length, 3009);
  }

  function testScriptySmallTokenURI() public {
    vm.startSnapshotGas("scripty: 3KB EthFS file");
    string memory out = _scriptyTokenURI("app.js");
    vm.stopSnapshotGas("scripty: 3KB EthFS file");

    assertEq(bytes(out).length, 3009);
  }

  function testStrandSmallTokenURI() public {
    vm.startSnapshotGas("strand: 3KB EthFS file");
    string memory out = _strandTokenURI("app.js");
    vm.stopSnapshotGas("strand: 3KB EthFS file");

    assertEq(bytes(out).length, 3039);
  }
}
