// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.12;

import "./TToken.sol";

contract TTokenFactory {
    mapping(bytes32=>TToken) tokens;
    function get(bytes32 name) external view returns (TToken) {
        return tokens[name];
    }
    function build(bytes32 name, bytes32 symbol, uint8 decimals) external returns (TToken) {
        tokens[name] = new TToken(name, symbol, decimals);
        return tokens[name];
    }
}
