// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "../../contracts/interfaces/IftPut.sol";
import {
    ERC721Enumerable,
    ERC721
} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

contract MockFTPUT is IftPut, ERC721Enumerable {
    address public putManager;
    string internal _baseTokenURI;
    bool internal _appendTokenIdInURI = true;

    constructor() ERC721("Mock Flying Tulip PUT", "mpFT") {}

    function mint(
        address,
        uint256,
        uint256,
        uint256,
        address,
        uint64
    )
        external
        pure
        override
        returns (uint256)
    {
        return 1;
    }

    function withdrawFT(
        address,
        uint256,
        uint256,
        uint256
    )
        external
        pure
        override
        returns (uint256 strikeAmount, address token)
    {
        return (1, address(0));
    }

    function divest(
        address,
        uint256,
        uint256,
        uint256
    )
        external
        pure
        override
        returns (uint256 strikeAmount, address token)
    {
        return (1, address(0));
    }

    function setPutManager(address _putManager) external override {
        putManager = _putManager;
    }

    function burn(
        address,
        /* owner */
        uint256 id
    )
        external
        override
    {
        _burn(id);
    }

    function divestable(
        uint256 /* id */
    )
        external
        pure
        override
        returns (uint256, uint256, address, uint64)
    {
        return (1, 1, address(0), uint64(10 * 1e8));
    }

    function baseTokenURI() external view override(IftPut) returns (string memory) {
        return _baseTokenURI;
    }

    function appendTokenIdInURI() external view override(IftPut) returns (bool) {
        return _appendTokenIdInURI;
    }

    function setBaseTokenURI(string calldata newBaseURI) external override(IftPut) {
        _baseTokenURI = newBaseURI;
    }

    function setAppendTokenIdInURI(bool enabled) external override(IftPut) {
        _appendTokenIdInURI = enabled;
    }

    function puts(
        uint256 /* id */
    )
        external
        pure
        override
        returns (
            address token,
            uint96 amount,
            uint96 ft,
            uint96 ft_bought,
            uint96 withdrawn,
            uint96 burned,
            uint96 strike,
            uint96 capital_remaining,
            uint64 ftPerUSD
        )
    {
        return (address(0), 1, 1, 1, 1, 1, 1, 1, uint64(10 * 1e8));
    }
}
