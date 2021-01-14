// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.12;

import './Vault.sol';

// BalancerPool mock; does not represent the actual BalancerPool design
contract BalancerPool {
    Vault _vault;
    bytes32 _poolId;

    mapping(address => uint256) private _balance;
    uint256 private _totalSupply;

    function init(
        Vault vault,
        bytes32 poolId,
        uint256[] calldata amounts
    ) external {
        _vault = vault;
        _poolId = poolId;
        _totalSupply = 100 ether;

        IERC20[] memory tokens = _vault.getPoolTokens(_poolId);
        _vault.addLiquidity(_poolId, msg.sender, tokens, amounts, false);
        _balance[msg.sender] = 100 ether;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address owner) public view returns (uint256){
        return _balance[owner];
    }

    function joinPool(
        uint256 poolAmountOut,
        uint256[] calldata maxAmountsIn,
        bool transferTokens,
        address beneficiary
    ) external {
        IERC20[] memory tokens = _vault.getPoolTokens(_poolId);

        uint256[] memory balances = _vault.getPoolTokenBalances(_poolId, tokens);

        uint256 poolTotal = totalSupply();
        uint256 ratio = uint256(poolAmountOut / poolTotal);
        require(ratio != 0, "ERR_MATH_APPROX");

        require(maxAmountsIn.length == tokens.length, "Tokens and amounts length mismatch");

        uint256[] memory amountsIn = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amountsIn[i] = uint256(balances[i] * ratio);
            require(amountsIn[i] <= maxAmountsIn[i], "ERR_LIMIT_IN");
        }

        _vault.addLiquidity(_poolId, msg.sender, tokens, amountsIn, !transferTokens);

        _mintPoolTokens(beneficiary, poolAmountOut);
    }

    function _mintPoolTokens(address recipient, uint256 amount) internal {
        _balance[address(this)] = _balance[address(this)] + amount;
        _totalSupply = _totalSupply + amount;

        _move(address(this), recipient, amount);
    }

    function _move(
        address sender,
        address recipient,
        uint256 amount
    ) internal {
        _balance[sender] = _balance[sender] - amount;
        _balance[recipient] = _balance[recipient] + amount;
    }
}
