// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../SimpleProxy.sol";
import {WrappedExternalBribe} from "../WrappedExternalBribe.sol";

contract WrappedExternalBribeFactory {
    bool internal _initialized;
    address public voter;
    mapping(address => address) public oldBribeToNew;
    address public last_bribe;
    address public wximpl;

    constructor(address _wximpl) {
        wximpl = _wximpl;
    }

    function createBribe(address existing_bribe) external returns (address) {
        require(
            oldBribeToNew[existing_bribe] == address(0),
            "Wrapped bribe already created"
        );
        last_bribe = address(new SimpleProxy(wximpl));

        WrappedExternalBribe(last_bribe).initialize(voter, existing_bribe);
        oldBribeToNew[existing_bribe] = last_bribe;
        return last_bribe;
    }

    function setVoter(address _voter) external {
        require(!_initialized, "Already initialized");
        voter = _voter;
        _initialized = true;
    }
}
