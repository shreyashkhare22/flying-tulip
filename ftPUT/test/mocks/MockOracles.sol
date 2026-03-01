// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MockFlyingTulipOracle {
    uint256 private constant ORACLE_DECIMALS = 1e8; // aaveOracle price scale
    uint256 private constant ONE_E18 = 1e18;

    mapping(address => uint256) public assetPrices;
    uint256 public ftPerUSD = 10 * 1e8; // FT per USD scaled to 1e8

    constructor() {
        // Set default prices (in 8 decimals)
        // 1 token = 1 USD by default
    }

    function getAssetPrice(address asset) public view returns (uint256) {
        uint256 price = assetPrices[asset];
        return price == 0 ? 1e8 : price; // Default to $1 if not set
    }

    function setAssetPrice(address asset, uint256 price) external {
        assetPrices[asset] = price;
    }

    function getAaveOracleAddress() external view returns (address) {
        return address(this);
    }

    // --- Pricing helpers (single source of truth for formulas) ---

    /// @dev Convert a token-denominated amount to 1e18 units (normalization).
    function _to1e18(uint256 amount, uint8 tokenDecimals) internal pure returns (uint256) {
        // tokenDecimals <= 18 is enforced at acceptance time; function is pure
        uint256 scale = 10 ** (18 - tokenDecimals); // <= 1e18
        return Math.mulDiv(amount, scale, 1); // 512-bit mul
    }

    /// @dev collateralAmount = ftAmount * (1e8^2 * 10^d) / (strike * ftPerUSD * 1e18)
    function collateralFromFT(
        uint256 ftAmount,
        uint256 strike,
        uint8 tokenDecimals
    )
        public
        view
        returns (uint256)
    {
        uint256 numScale = ORACLE_DECIMALS * ORACLE_DECIMALS * (10 ** tokenDecimals);
        uint256 den = strike * ftPerUSD * ONE_E18;
        return Math.mulDiv(ftAmount, numScale, den);
    }

    /// @dev ftAmount = collateral * (strike * ftPerUSD * 1e18) / (1e8^2 * 10^d)
    function ftFromCollateral(
        uint256 collateral,
        uint256 strike,
        uint8 tokenDecimals
    )
        public
        view
        returns (uint256)
    {
        uint256 num = strike * ftPerUSD * ONE_E18;
        uint256 den = ORACLE_DECIMALS * ORACLE_DECIMALS * (10 ** tokenDecimals);
        return Math.mulDiv(collateral, num, den);
    }

    function getAssetFTPrice(
        address token,
        uint256 amount,
        uint8 tokenDecimals
    )
        public
        view
        returns (uint256 ftToTransfer, uint256 assetToUSD)
    {
        assetToUSD = getAssetPrice(token);
        // Normalize deposit to 1e18 and then apply (ftPerUSD scaled to 1e8) with oracle in 1e8
        uint256 normalized = _to1e18(amount, tokenDecimals);
        // normalized * (price * ftPerUSD) / (1e8 * 1e8)
        ftToTransfer =
            Math.mulDiv(normalized, ftPerUSD * assetToUSD, ORACLE_DECIMALS * ORACLE_DECIMALS);
    }
}

contract MockAaveOracle {
    mapping(address => uint256) public assetPrices;

    constructor() {
        // Set default prices (in 8 decimals)
        // 1 token = 1 USD by default
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        uint256 price = assetPrices[asset];
        return price == 0 ? 1e8 : price; // Default to $1 if not set
    }

    function setAssetPrice(address asset, uint256 price) external {
        assetPrices[asset] = price;
    }
}

contract MockChainlinkOracle {
    int256 public price;

    constructor(int256 _price) {
        price = _price;
    }

    function latestAnswer() external view returns (int256) {
        return price;
    }

    function setPrice(int256 _price) external {
        price = _price;
    }
}

contract MockBeetsStaking {
    string public name = "Staked S";
    string public symbol = "stS";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Conversion rate: 1 stS = 1.1 S (10% staking reward)
    uint256 public conversionRate = 1.1e18;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function convertToAssets(uint256 sharesAmount) external view returns (uint256) {
        return (sharesAmount * conversionRate) / 1e18;
    }

    function setConversionRate(uint256 _rate) external {
        conversionRate = _rate;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= value;
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }
}
