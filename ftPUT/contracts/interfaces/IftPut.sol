// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {
    IERC721Enumerable
} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

interface IftPut is IERC721Enumerable {
    function mint(
        address owner,
        uint256 amount,
        uint256 ft,
        uint256 usd,
        address token,
        uint64 ftPerUSD
    )
        external
        returns (uint256);

    function withdrawFT(
        address owner,
        uint256 id,
        uint256 amount,
        uint256 amountDivested
    )
        external
        returns (uint256, address);

    function divest(
        address owner,
        uint256 id,
        uint256 amount,
        uint256 amountDivested
    )
        external
        returns (uint256, address);

    function burn(address owner, uint256 id) external;

    function setPutManager(address _putManager) external;

    function divestable(uint256 id) external view returns (uint256, uint256, address, uint64);

    function baseTokenURI() external view returns (string memory);

    function appendTokenIdInURI() external view returns (bool);

    function setBaseTokenURI(string calldata newBaseURI) external;

    function setAppendTokenIdInURI(bool enabled) external;

    function puts(uint256 id)
        external
        view
        returns (
            address token,
            uint96 amount,
            uint96 ft,
            uint96 ft_bought,
            uint96 withdrawn,
            uint96 burned,
            uint96 strike,
            uint96 amountRemaining,
            uint64 ftPerUSD
        );
}
