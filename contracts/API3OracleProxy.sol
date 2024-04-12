// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./External/SafeMath.sol";
import "./OErc20.sol";
import "./External/FullMath.sol";
import "./PriceOracle.sol";
import "@api3/contracts/v0.8/interfaces/IProxy.sol";
import "hardhat/console.sol";

contract API3OracleProxy is Ownable, PriceOracle {
    using SafeMath for uint32;
    using SafeMath for uint;

    error OraclePriceLessThanZero();
    error OraclePriceExpired();

    mapping(address => address) public underlyingToAPI3Address;
    uint private priceInvalidAfterSeconds = 86400;

    constructor() Ownable(msg.sender) {}

    function setAddresses(
        address[] calldata underlyingAssets,
        address[] calldata api3Addresses
    ) external onlyOwner {
        require(
            underlyingAssets.length == api3Addresses.length,
            "API3OracleProxy: assets and priceFeedIds length mismatch"
        );
        for (uint i = 0; i < underlyingAssets.length; i++) {
            underlyingToAPI3Address[underlyingAssets[i]] = api3Addresses[i];
        }
    }

    function getUnderlyingPrice(
        OToken oToken
    ) public view override returns (uint) {
        address asset = _getUnderlyingAddress(oToken);
        (int224 value, uint256 timestamp) = IProxy(underlyingToAPI3Address[asset]).read();

        if (value < 0) {
            revert OraclePriceLessThanZero();
        }

        if (timestamp < block.timestamp - priceInvalidAfterSeconds) {
            revert OraclePriceExpired();
        }

        // Converts price to a format as defined by the Comptroller
        uint32 expToUse = uint32(36 - 18); // API3 returns 18 decimals
        // get underlying decimals
        uint underlyingDecimals = asset == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE ? 18 : OErc20(asset).decimals();

        return FullMath.mulDiv(
            10 ** expToUse,
            uint256(int256(value)),
            10 ** underlyingDecimals
        );
    }

    function _getUnderlyingAddress(
        OToken oToken
    ) private view returns (address) {
        address asset;
        if (compareStrings(oToken.symbol(), "oETH")) {
            asset = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        } else {
            asset = address(OErc20(address(oToken)).underlying());
        }
        return asset;
    }

    function _setPriceInvalidAfterSec(uint val) external onlyOwner {
        priceInvalidAfterSeconds = val;
    }

    function compareStrings(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) ==
            keccak256(abi.encodePacked((b))));
    }
}
