// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IFlyingTulipOracle} from "./interfaces/IFlyingTulipOracle.sol";
import {IAaveOracle} from "./interfaces/IAaveOracle.sol";

// Oracle uses an external Aave oracle and simple bounds; not a proxy
contract FlyingTulipOracle is IFlyingTulipOracle {
    event MsigUpdateScheduled(address newMsig, uint256 effectiveTime);
    event MsigUpdated(address newMsig);
    event ftPerUSDUpdated(uint256 newFtPerUSD);
    event PriceBoundsUpdated(address token, uint256 minPrice, uint256 maxPrice);

    error ftOracleNotMsig();
    error ftOracleZeroAddress();
    error ftOracleInvalidMsig();
    error ftOracleError();

    IAaveOracle immutable aaveOracle;

    // Optimized storage layout - packing saves gas
    // Slot 0: address (20 bytes) + uint64 (8 bytes) = 28 bytes, 4 bytes free
    address public msig;
    // FT per USD scaled to 1e8 (oracle base)
    uint64 public ftPerUSD = uint64(10 * 1e8); // 10 FT per $1 collateral

    // Slot 1: address (20 bytes) + uint64 (8 bytes) = 28 bytes, 4 bytes free
    address public nextMsig;
    uint64 public delayMsig; // Timestamp fits in uint64 (good until year 584942417)

    uint256 internal constant DELAY_MULTISIG = 1 hours; // 1 days in production

    mapping(address => uint256) public minPrice; // 1e8
    mapping(address => uint256) public maxPrice; // 1e8

    modifier onlyMsig() {
        if (msg.sender != msig) revert ftOracleNotMsig();
        _;
    }

    constructor(address _aaveOracle) {
        if (_aaveOracle == address(0x0)) revert ftOracleZeroAddress();
        aaveOracle = IAaveOracle(_aaveOracle);
        msig = msg.sender;
        emit MsigUpdated(msig);
    }

    function setMsig(address _msig) external onlyMsig {
        if (_msig == address(0x0)) revert ftOracleZeroAddress();
        if (_msig == msig || _msig == nextMsig) revert ftOracleInvalidMsig();
        uint256 effectiveTime = block.timestamp + DELAY_MULTISIG;
        emit MsigUpdateScheduled(_msig, effectiveTime);
        nextMsig = _msig;
        delayMsig = uint64(effectiveTime);
    }

    function acceptMsig() external {
        if (msg.sender != nextMsig || block.timestamp < delayMsig) {
            revert ftOracleInvalidMsig();
        }
        emit MsigUpdated(nextMsig);
        msig = nextMsig;
        // clear pending state
        nextMsig = address(0);
        delayMsig = 0;
    }

    function setftPerUSD(uint64 newFtPerUSD) external onlyMsig {
        if (newFtPerUSD == 0) revert ftOracleError();
        emit ftPerUSDUpdated(newFtPerUSD);
        ftPerUSD = newFtPerUSD;
    }

    function setPriceBounds(address token, uint256 minP, uint256 maxP) external onlyMsig {
        // allow 0 to mean “unset”
        if (minP != 0 && maxP != 0 && minP > maxP) {
            revert ftOracleError();
        }
        minPrice[token] = minP;
        maxPrice[token] = maxP;
        emit PriceBoundsUpdated(token, minP, maxP);
    }

    function getAssetPrice(address token) public view returns (uint256 strike) {
        strike = aaveOracle.getAssetPrice(token);
        if (strike == 0) revert ftOracleError();
        uint256 minP = minPrice[token];
        uint256 maxP = maxPrice[token];
        if ((minP != 0 && strike < minP) || (maxP != 0 && strike > maxP)) {
            revert ftOracleError();
        }
    }

    function getAaveOracleAddress() external view returns (address) {
        return address(aaveOracle);
    }
}
