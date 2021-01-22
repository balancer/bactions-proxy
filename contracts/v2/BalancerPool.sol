// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.12;

import './Vault.sol';
import './LogExpMath.sol';

// BalancerPool mock; does not represent the actual BalancerPool design
contract BalancerPool {
    Vault _vault;
    bytes32 _poolId;
    
    uint256 _swapFee;
    mapping(address => uint256) private _weight;
    uint256 private _totalWeight;

    mapping(address => uint256) private _balance;
    uint256 private _totalSupply;

    uint128 internal constant ONE = 10**18;

    function init(
        Vault vault,
        bytes32 poolId,
        uint256 swapFee,
        uint256[] calldata amounts,
        uint256[] calldata weights
    ) external {
        _vault = vault;
        _poolId = poolId;
        _totalSupply = 100 ether;

        IERC20[] memory tokens = _vault.getPoolTokens(_poolId);
        _vault.addLiquidity(_poolId, msg.sender, tokens, amounts, false);
        _balance[msg.sender] = 100 ether;

        _swapFee = swapFee;
        for (uint256 i = 0; i < weights.length; i++) {
            _weight[address(tokens[i])] = weights[i];
            _totalWeight += weights[i];
        }
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address owner) public view returns (uint256){
        return _balance[owner];
    }

    function getPoolId() external view returns (bytes32) {
        return _poolId;
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

    function joinPoolExactTokensInForBPTOut(
        uint256 minBPTAmountOut,
        uint256[] calldata amountsIn,
        bool transferTokens,
        address beneficiary
    ) external returns (uint256 bptAmountOut) {
        IERC20[] memory tokens = _vault.getPoolTokens(_poolId);

        uint256[] memory balances = _vault.getPoolTokenBalances(_poolId, tokens);

        uint256[] memory normalizedWeights = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            normalizedWeights[i] = _weight[address(tokens[i])] / _totalWeight;
        }

        bptAmountOut = _exactTokensInForBPTOut(balances, normalizedWeights, amountsIn, totalSupply(), _swapFee);
        require(bptAmountOut >= minBPTAmountOut, "ERR_BPT_OUT_MIN_AMOUNT");

        _vault.addLiquidity(_poolId, msg.sender, tokens, amountsIn, !transferTokens);

        _mintPoolTokens(beneficiary, bptAmountOut);
    }

    function _exactTokensInForBPTOut(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsIn,
        uint256 bptTotalSupply,
        uint256 swapFee
    ) internal pure returns (uint256) {
        uint256[] memory tokenBalanceRatiosWithoutFee = new uint256[](amountsIn.length);
        uint256 weightedBalanceRatio = 0;
        for (uint256 i = 0; i < balances.length; i++) {
            tokenBalanceRatiosWithoutFee[i] = (balances[i] + amountsIn[i]) / balances[i];
            weightedBalanceRatio = weightedBalanceRatio + (tokenBalanceRatiosWithoutFee[i] * normalizedWeights[i]);
        }
        uint256 invariantRatio = ONE;
        for (uint256 i = 0; i < balances.length; i++) {
            uint256 tokenBalancePercentageExcess;
            if (weightedBalanceRatio >= tokenBalanceRatiosWithoutFee[i]) {
                tokenBalancePercentageExcess = 0;
            } else {
                tokenBalancePercentageExcess = ((tokenBalanceRatiosWithoutFee[i] - weightedBalanceRatio)
                    / tokenBalanceRatiosWithoutFee[i]) - ONE;
            }

            uint256 amountInAfterFee = amountsIn[i] * (ONE - (swapFee * tokenBalancePercentageExcess));
            uint256 tokenBalanceRatio = ONE + (amountInAfterFee / balances[i]);
            invariantRatio = invariantRatio * LogExpMath.pow(tokenBalanceRatio, normalizedWeights[i]);
        }

        return bptTotalSupply * (invariantRatio - ONE);
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
