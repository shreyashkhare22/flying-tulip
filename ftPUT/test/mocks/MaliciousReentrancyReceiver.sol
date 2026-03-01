// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {PutManager} from "contracts/PutManager.sol";
import {pFT} from "contracts/pFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MaliciousReentrancyReceiver
/// @notice Malicious contract that attempts to reenter during ERC721 onERC721Received callback
/// @dev Tests reentrancy protection when _safeMint is used instead of _mint
contract MaliciousReentrancyReceiver is IERC721Receiver {
    PutManager public manager;
    pFT public pft;
    address public token;

    uint256 public reentrancyAttempts;
    bool public shouldAttemptReentrancy;

    // Track what attack vector to use
    enum AttackType {
        NONE,
        WITHDRAW_FT,
        DIVEST,
        DIVEST_UNDERLYING,
        TRANSFER,
        INVEST_AGAIN
    }

    AttackType public attackType;
    uint256 public receivedTokenId;
    bool public attackSucceeded;
    string public failureReason;

    event ReentrancyAttempted(uint256 tokenId, AttackType attackType);
    event ReentrancyFailed(uint256 tokenId, AttackType attackType, string reason);
    event ReentrancySucceeded(uint256 tokenId, AttackType attackType);

    constructor(address _manager, address _pft) {
        manager = PutManager(_manager);
        pft = pFT(_pft);
    }

    /// @notice Configure the attack vector
    function setAttackType(AttackType _attackType) external {
        attackType = _attackType;
        shouldAttemptReentrancy = _attackType != AttackType.NONE;
        attackSucceeded = false;
        failureReason = "";
    }

    /// @notice Set the token to use for reinvestment attack
    function setToken(address _token) external {
        token = _token;
    }

    /// @notice ERC721 receiver callback - this is where reentrancy happens
    function onERC721Received(
        address,
        /*operator*/
        address,
        /*from*/
        uint256 tokenId,
        bytes calldata /*data*/
    )
        external
        override
        returns (bytes4)
    {
        receivedTokenId = tokenId;

        if (shouldAttemptReentrancy) {
            reentrancyAttempts++;
            emit ReentrancyAttempted(tokenId, attackType);

            try this._attemptAttack(tokenId) {
                attackSucceeded = true;
                emit ReentrancySucceeded(tokenId, attackType);
            } catch Error(string memory reason) {
                failureReason = reason;
                emit ReentrancyFailed(tokenId, attackType, reason);
            } catch (bytes memory) {
                failureReason = "Low-level revert";
                emit ReentrancyFailed(tokenId, attackType, "Low-level revert");
            }
        }

        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice External function to attempt attack (allows try/catch)
    function _attemptAttack(uint256 tokenId) external {
        require(msg.sender == address(this), "Only self");

        if (attackType == AttackType.WITHDRAW_FT) {
            // Try to withdraw FT during mint
            (,, uint96 ft,,,,,,) = pft.puts(tokenId);
            manager.withdrawFT(tokenId, ft / 2);
        } else if (attackType == AttackType.DIVEST) {
            // Try to divest during mint
            (,, uint96 ft,,,,,,) = pft.puts(tokenId);
            manager.divest(tokenId, ft / 2);
        } else if (attackType == AttackType.DIVEST_UNDERLYING) {
            // Try to divest underlying during mint
            (,, uint96 ft,,,,,,) = pft.puts(tokenId);
            manager.divestUnderlying(tokenId, ft / 2);
        } else if (attackType == AttackType.TRANSFER) {
            // Try to transfer the NFT during mint
            pft.transferFrom(address(this), address(0xdead), tokenId);
        } else if (attackType == AttackType.INVEST_AGAIN) {
            // Try to invest again during mint (drain FT supply)
            uint256 amount = 1000e6; // 1000 USDC
            IERC20(token).approve(address(manager), amount);
            manager.invest(token, amount, address(this), 0, new bytes32[](0));
        }
    }

    /// @notice Helper to invest and trigger the attack
    function investAndAttack(address _token, uint256 amount) external {
        IERC20(_token).approve(address(manager), amount);
        manager.invest(_token, amount, address(this), 0, new bytes32[](0));
    }

    /// @notice Reset attack state
    function reset() external {
        reentrancyAttempts = 0;
        attackSucceeded = false;
        failureReason = "";
        receivedTokenId = 0;
    }
}
