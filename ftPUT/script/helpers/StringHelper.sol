// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

library StringHelper {
    /**
     * @notice Trim whitespace from string
     */
    function trim(string memory str) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        if (strBytes.length == 0) return str;

        // Find start
        uint256 start = 0;
        while (start < strBytes.length && isWhitespace(strBytes[start])) {
            ++start;
        }

        // Find end
        uint256 end = strBytes.length;
        while (end > start && isWhitespace(strBytes[end - 1])) {
            --end;
        }

        return substring(str, start, end);
    }

    /**
     * @notice Check if byte is whitespace
     */
    function isWhitespace(bytes1 char) internal pure returns (bool) {
        return char == 0x20 || char == 0x09 || char == 0x0d || char == 0x0a;
    }

    /**
     * @notice Check if string starts with prefix
     */
    function startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory prefixBytes = bytes(prefix);

        if (prefixBytes.length > strBytes.length) return false;

        for (uint256 i = 0; i < prefixBytes.length; i++) {
            if (strBytes[i] != prefixBytes[i]) return false;
        }

        return true;
    }

    /**
     * @notice Extract substring
     */
    function substring(
        string memory str,
        uint256 startIndex,
        uint256 endIndex
    )
        internal
        pure
        returns (string memory)
    {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(endIndex - startIndex);

        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }

        return string(result);
    }
}
