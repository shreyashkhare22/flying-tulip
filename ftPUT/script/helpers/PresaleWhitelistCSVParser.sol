// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {StringHelper} from "./StringHelper.sol";
import {MerkleHelper} from "../../test/helpers/MerkleHelper.sol";

library PresaleWhitelistCSVParser {
    using StringHelper for string;

    error EmptyCSV();
    error NoEntriesFoundInCSV();
    error InvalidColumnCount();

    /**
     * @notice Parse CSV string into array of ACL entries
     * @dev CSV format: address,chain,asset,amount
     *      - chain: 0 for any chain, or specific chain ID
     *      - asset: 0x0000000000000000000000000000000000000000 for any asset, or specific address
     *      - amount: 0 for any amount, or specific amount limit
     * @param csv CSV content with ACL entry data
     * @return entries Array of parsed ACL entries
     */
    function parseACL(
        string memory csv,
        Vm vm
    )
        internal
        pure
        returns (MerkleHelper.ACLEntry[] memory)
    {
        string[] memory lines = splitLines(csv);
        require(lines.length > 0, EmptyCSV());

        // Auto-detect header (skip if first line doesn't start with 0x)
        uint256 startLine = 0;
        string memory firstLine = lines[0].trim();
        if (bytes(firstLine).length > 0 && !firstLine.startsWith("0x")) {
            startLine = 1;
        }

        // Count valid lines
        uint256 count = 0;
        for (uint256 i = startLine; i < lines.length; i++) {
            if (bytes(lines[i].trim()).length > 0) {
                count++;
            }
        }

        // Parse entries
        MerkleHelper.ACLEntry[] memory entries = new MerkleHelper.ACLEntry[](count);
        uint256 index = 0;

        for (uint256 i = startLine; i < lines.length; i++) {
            string memory line = lines[i].trim();
            if (bytes(line).length == 0) continue;

            // Parse columns
            string[] memory columns = splitColumns(line);
            require(columns.length == 3, InvalidColumnCount());

            address who = vm.parseAddress(columns[0].trim());
            address asset = vm.parseAddress(columns[1].trim());
            uint256 amount = vm.parseUint(columns[2].trim());

            entries[index] = MerkleHelper.ACLEntry(who, asset, amount);
            index++;
        }

        return entries;
    }

    /**
     * @notice Split string by newlines
     */
    function splitLines(string memory str) internal pure returns (string[] memory) {
        bytes memory strBytes = bytes(str);

        // Count lines
        uint256 lineCount = 1;
        for (uint256 i = 0; i < strBytes.length; i++) {
            if (strBytes[i] == "\n") lineCount++;
        }

        string[] memory lines = new string[](lineCount);
        uint256 lineIndex = 0;
        uint256 start = 0;

        for (uint256 i = 0; i < strBytes.length; i++) {
            if (strBytes[i] == "\n") {
                lines[lineIndex] = str.substring(start, i);
                lineIndex++;
                start = i + 1;
            }
        }

        // Add last line
        if (start < strBytes.length) {
            lines[lineIndex] = str.substring(start, strBytes.length);
        }

        return lines;
    }

    /**
     * @notice Split CSV line into columns
     */
    function splitColumns(string memory line) internal pure returns (string[] memory) {
        bytes memory lineBytes = bytes(line);

        // Count columns
        uint256 columnCount = 1;
        for (uint256 i = 0; i < lineBytes.length; i++) {
            if (lineBytes[i] == ",") columnCount++;
        }

        string[] memory columns = new string[](columnCount);
        uint256 columnIndex = 0;
        uint256 start = 0;

        for (uint256 i = 0; i < lineBytes.length; i++) {
            if (lineBytes[i] == ",") {
                columns[columnIndex] = line.substring(start, i);
                columnIndex++;
                start = i + 1;
            }
        }

        // Add last column
        if (start < lineBytes.length) {
            columns[columnIndex] = line.substring(start, lineBytes.length);
        } else if (start == lineBytes.length) {
            // Handle trailing comma
            columns[columnIndex] = "";
        }

        return columns;
    }

    /**
     * @notice Extract first column from CSV line (everything before first comma)
     */
    function getFirstColumn(string memory line) internal pure returns (string memory) {
        bytes memory lineBytes = bytes(line);

        for (uint256 i = 0; i < lineBytes.length; i++) {
            if (lineBytes[i] == ",") {
                return line.substring(0, i);
            }
        }

        return line;
    }
}
