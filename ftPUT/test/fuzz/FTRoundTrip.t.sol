// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {PutManager} from "contracts/PutManager.sol";

/// @title Proof: FT→Collateral→FT Always Loses or Breaks Even
/// @notice Prove that users CANNOT gain from FT→Collateral→FT round-trip
/// @dev SECURITY CRITICAL: If users could gain, protocol would be under-collateralized
contract FTRoundTripTest is Test {
    PutManager public manager;

    function setUp() public {
        manager = new PutManager(address(0x1), address(0x2));
    }

    /// @notice CRITICAL SECURITY TEST: Can user gain FT from round-trip?
    /// @dev Test across WIDE parameter ranges to find any case where user gains
    function testFuzz_FTRoundTrip_cannotGain(
        uint96 ftAmount,
        uint96 strike,
        uint8 decimals,
        uint64 ftPerUSD
    )
        public
        view
    {
        // Use WIDE bounds to catch any edge case
        decimals = uint8(bound(decimals, 6, 18));
        strike = uint96(bound(strike, 1e3, 1e12)); // $0.00001 to $10,000
        ftPerUSD = uint64(bound(ftPerUSD, 1e5, 1e11)); // 0.001 to 1000 FT per USD
        ftAmount = uint96(bound(ftAmount, 1e10, type(uint96).max / 1e6)); // Reasonable FT amounts

        // FT → Collateral → FT
        uint256 collateral = manager.collateralFromFT(ftAmount, strike, decimals, ftPerUSD);
        if (collateral == 0) return; // Skip if rounds to zero

        uint256 ftBack = manager.ftFromCollateral(collateral, strike, decimals, ftPerUSD);

        // CRITICAL SECURITY INVARIANT: ftBack MUST be ≤ ftAmount
        // If ftBack > ftAmount, user gained FT with no additional collateral!
        assertLe(ftBack, ftAmount, "CRITICAL: User gained FT from round-trip!");
    }

    /// @notice Test the specific failing case from PricingPrecisionFuzz
    function test_specificFailingCase() public view {
        uint256 ftAmount = 6936660862766891857; // 6.936e18
        uint256 strike = 18886996189; // $188.87
        uint8 decimals = 6;
        uint64 ftPerUSD = 9990059632; // 99.9 FT per USD

        console2.log("Testing specific failing case...");
        console2.log("");
        console2.log("Input FT:", ftAmount);

        uint256 collateral = manager.collateralFromFT(ftAmount, strike, decimals, ftPerUSD);
        console2.log("Intermediate collateral:", collateral, "wei");

        uint256 ftBack = manager.ftFromCollateral(collateral, strike, decimals, ftPerUSD);
        console2.log("Output FT:", ftBack);
        console2.log("");

        if (ftBack > ftAmount) {
            console2.log("CRITICAL: User GAINED FT!");
            console2.log("Gain:", ftBack - ftAmount);
        } else if (ftBack < ftAmount) {
            console2.log("Result: User LOST FT (protocol gains)");
            console2.log("Loss:", ftAmount - ftBack);
            uint256 lossPercent = ((ftAmount - ftBack) * 10000) / ftAmount;
            console2.log("Loss percentage (bps):", lossPercent);
        } else {
            console2.log("Result: Perfect round-trip");
        }
        console2.log("");

        // Security check
        assertLe(ftBack, ftAmount, "User gained FT!");
    }

    /// @notice Test many extreme scenarios with dust intermediate collateral
    function test_extremeDustScenarios() public view {
        console2.log("========================================");
        console2.log("TESTING EXTREME DUST SCENARIOS");
        console2.log("========================================");
        console2.log("");

        uint256 userGainCases = 0;
        uint256 totalCases = 0;

        // Very large FT amounts with parameters that create dust collateral
        uint256[5] memory largeFT = [
            uint256(1e18), // 1 FT
            uint256(1e19), // 10 FT
            uint256(1e20), // 100 FT
            uint256(1e21), // 1,000 FT
            uint256(1e22) // 10,000 FT
        ];

        uint256[5] memory strikes = [
            uint256(1e8), // $1
            uint256(1e9), // $10
            uint256(1e10), // $100
            uint256(1e11), // $1,000
            uint256(5e11) // $5,000
        ];

        uint64[3] memory ftPerUSDValues = [
            uint64(1e7), // 0.1 FT per USD
            uint64(1e9), // 10 FT per USD
            uint64(1e10) // 100 FT per USD
        ];

        for (uint256 i = 0; i < largeFT.length; i++) {
            for (uint256 j = 0; j < strikes.length; j++) {
                for (uint256 k = 0; k < ftPerUSDValues.length; k++) {
                    uint256 ftAmount = largeFT[i];
                    uint256 strike = strikes[j];
                    uint64 ftPerUSD = ftPerUSDValues[k];

                    uint256 collateral = manager.collateralFromFT(ftAmount, strike, 6, ftPerUSD);
                    if (collateral == 0) continue;

                    uint256 ftBack = manager.ftFromCollateral(collateral, strike, 6, ftPerUSD);

                    totalCases++;

                    if (ftBack > ftAmount) {
                        userGainCases++;
                        console2.log("USER GAIN FOUND!");
                        console2.log("FT amount:", ftAmount);
                        console2.log("Strike:", strike);
                        console2.log("ftPerUSD:", ftPerUSD);
                        console2.log("Collateral:", collateral);
                        console2.log("FT back:", ftBack);
                        console2.log("Gain:", ftBack - ftAmount);
                        console2.log("");
                    }
                }
            }
        }

        console2.log("========================================");
        console2.log("RESULTS:");
        console2.log("Total cases tested:", totalCases);
        console2.log("User gain cases:", userGainCases);
        console2.log("========================================");

        assertEq(userGainCases, 0, "Found cases where user gains FT!");
    }
}
