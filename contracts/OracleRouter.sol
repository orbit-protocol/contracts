import "@openzeppelin/contracts/access/Ownable.sol";
import "./PriceOracle.sol";

contract OracleRouter is Ownable, PriceOracle {
    constructor() Ownable(msg.sender) {}

    mapping(address => address) public oTokenToOracleAddress;

    function getUnderlyingPrice(
        OToken oToken
    ) public view override returns (uint) {
        return PriceOracle(oTokenToOracleAddress[address(oToken)]).getUnderlyingPrice(oToken);
    }

    function setRouterAddresses (
        address[] calldata underlying,
        address[] calldata oracleAddress
    ) external onlyOwner {
        require (
            underlying.length == oracleAddress.length,
            "OracleRouter: assets and oracleAddress length mismatch"
        );
        for (uint i = 0; i < underlying.length; i++) {
            oTokenToOracleAddress[underlying[i]] = oracleAddress[i];
        }
    }
}