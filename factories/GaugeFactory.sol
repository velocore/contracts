// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../interfaces/IGaugeFactory.sol";
import "../Gauge.sol";
import "../SimpleProxy.sol";

contract GaugeFactory is IGaugeFactory {
    address public last_gauge;
    address public gaugeImplementation;

    constructor(address _gaugeImplementation) {
        gaugeImplementation = _gaugeImplementation;
    }

    function createGauge(
        address _pool,
        address _external_bribe,
        address _ve,
        bool isPair,
        address[] memory allowedRewards
    ) external returns (address) {
        last_gauge = address(new SimpleProxy(gaugeImplementation));

        Gauge(last_gauge).initialize(
            _pool,
            _external_bribe,
            _ve,
            msg.sender,
            isPair,
            allowedRewards
        );

        return last_gauge;
    }
}
