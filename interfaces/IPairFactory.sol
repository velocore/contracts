pragma solidity ^0.8.13;

interface IPairFactory {
    function allPairsLength() external view returns (uint);

    function isPair(address pair) external view returns (bool);

    function voter() external view returns (address);

    function tank() external view returns (address);

    function getInitializable() external view returns (address, address, bool);

    function getFee(bool _stable) external view returns (uint256);

    function isPaused() external view returns (bool);

    function getPair(
        address tokenA,
        address token,
        bool stable
    ) external view returns (address);

    function createPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external returns (address pair);
}
