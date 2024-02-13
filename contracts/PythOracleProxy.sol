// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./PythDependency/IPyth.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./External/SafeMath.sol";
import "./OErc20.sol";
import "./External/FullMath.sol";
import "./PriceOracle.sol";

contract PythOracleProxy is Ownable, PriceOracle {
    using SafeMath for uint32;
    using SafeMath for uint;

    error OraclePriceLessThanZero();

    IPyth public pyth;
    mapping(address => bytes32) public addressToPriceFeedID;
    uint private priceInvalidAfterSeconds = 60;

    constructor() Ownable(msg.sender) {}

    function setPythOracle(IPyth _pyth) external onlyOwner {
        pyth = _pyth;
    }

    function setPriceFeedIds(
        address[] calldata underlyingAssets,
        bytes32[] calldata priceFeedIds
    ) external onlyOwner {
        require(
            underlyingAssets.length == priceFeedIds.length,
            "PythOracleProxy: assets and priceFeedIds length mismatch"
        );
        for (uint i = 0; i < underlyingAssets.length; i++) {
            addressToPriceFeedID[underlyingAssets[i]] = priceFeedIds[i];
        }
    }

    function getUnderlyingPrice(OToken oToken) public view override returns (uint) {
        address asset = _getUnderlyingAddress(oToken);
        // Get the price from Pyth
        PythStructs.Price memory price = pyth.getPriceNoOlderThan(
            addressToPriceFeedID[asset],
            priceInvalidAfterSeconds
        );
        if (price.price < 0) {
            revert OraclePriceLessThanZero();
        }
        // Converts price to a format as defined by the Comptroller
        uint32 expToUse = uint32(36 + price.expo);
        if (expToUse > 0) {
            // uint priceFormatted = uint(int256(price.price)).mul(10**expToUse).div(10**oToken.decimals());
            return
                FullMath.mulDiv(
                    10 ** expToUse,
                    uint256(int256(price.price)),
                    10 ** oToken.decimals()
                );
        }
        return uint(int256(price.price));
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
