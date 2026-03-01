// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {
    IERC20Metadata,
    IERC20
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IERC20MetadataBurnable is IERC20Metadata {
    function burn(uint256 amount) external;
}
