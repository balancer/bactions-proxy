// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.12;

contract BBronze {
    function getColor()
        external view
        returns (bytes32) {
            return bytes32("BRONZE");
        }
}
