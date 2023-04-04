// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../interfaces/IBribeFactory.sol";
import "../ExternalBribe.sol";
import "../SimpleProxy.sol";

contract BribeFactory is IBribeFactory {
    address public externalBribeImplementation;

    address public last_internal_bribe;
    address public last_external_bribe;

    constructor(address _externalBribeImplementation) {
        externalBribeImplementation = _externalBribeImplementation;
    }

    function createExternalBribe(
        address[] memory allowedRewards
    ) external returns (address) {
        last_external_bribe = address(
            new SimpleProxy(externalBribeImplementation)
        );
        ExternalBribe(last_external_bribe).initialize(
            msg.sender,
            allowedRewards
        );
        return last_external_bribe;
    }
}
