// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/proxy/Proxy.sol";
import "@openzeppelin/contracts/utils/StorageSlot.sol";

contract SimpleProxy is Proxy {
    address immutable implementationAddress;

    constructor(address implementation_) {
        implementationAddress = implementation_;
    }

    function _implementation() internal view override returns (address) {
        return implementationAddress;
    }
}
