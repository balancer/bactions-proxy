// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.12;

import './Vault.sol';
import './LogExpMath.sol';

// BalancerPool mock; does not represent the actual BalancerPool design
contract BalancerPool {
    Vault _vault;
    string _name;
    string _symbol;
    bytes32 _poolId;
    
    uint256 _swapFee;
    mapping(address => uint256) private _weight;
    uint256 private _totalWeight;

    mapping(address => uint256) private _balance;
    uint256 private _totalSupply;

    uint128 internal constant ONE = 10**18;

    function create(
        Vault vault,
        bytes32 poolId,
        string memory name,
        string memory symbol,
        IERC20[] memory tokens,
        uint256[] memory weights,
        uint256 swapFee
    ) external {
        _vault = vault;
        _poolId = poolId;

        _name = name;
        _symbol = symbol;
        _swapFee = swapFee;

        for (uint8 i = 0; i < weights.length; i++) {
            _totalWeight = _totalWeight + weights[i];
        }
    }

    enum JoinKind { INIT, EXACT_TOKENS_IN_FOR_BPT_OUT }

    function onJoinPool(
        bytes32 poolId,
        address, // sender - potential whitelisting
        address recipient,
        uint256[] memory currentBalances,
        uint256[] memory maxAmountsIn,
        uint256 protocolFeePercentage,
        bytes memory userData
    ) external returns (uint256[] memory, uint256[] memory) {
        require(msg.sender == address(_vault), "ERR_CALLER_NOT_VAULT");
        require(poolId == _poolId, "INVALID_POOL_ID");

        IERC20[] memory tokens = _vault.getPoolTokens(poolId);
        uint256[] memory normalizedWeights = new uint256[](tokens.length);
        for (uint8 i = 0; i < tokens.length; i++) {
            normalizedWeights[i] = _weight[address(tokens[i])] / _totalWeight;
        }

        // The Vault guarantees currentBalances and maxAmountsIn have the same length

        JoinKind kind = abi.decode(userData, (JoinKind));

        if (kind == JoinKind.INIT) {
            //Max amounts in are equal to amounts in.
            return _joinInitial(normalizedWeights, recipient, maxAmountsIn);
        } else {
            // JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT
            //Max amounts in are equal to exact amounts in.
            (, uint256 minimumBPT) = abi.decode(userData, (JoinKind, uint256));
            return
                _joinExactTokensInForBPTOut(
                    normalizedWeights,
                    currentBalances,
                    recipient,
                    maxAmountsIn,
                    minimumBPT,
                    protocolFeePercentage
                );
        }
    }

    function _joinInitial(
        uint256[] memory normalizedWeights,
        address recipient,
        uint256[] memory amountsIn
    ) private returns (uint256[] memory, uint256[] memory) {
        require(totalSupply() == 0, "ERR_ALREADY_INITIALIZED");

        // _lastInvariant should also be zero
        uint256 invariantAfterJoin = _invariant(normalizedWeights, amountsIn);

        _mintPoolTokens(recipient, invariantAfterJoin);

        IERC20[] memory tokens = _vault.getPoolTokens(_poolId);
        uint256[] memory dueProtocolFeeAmounts = new uint256[](tokens.length); // All zeroes
        return (amountsIn, dueProtocolFeeAmounts);
    }

    function _joinExactTokensInForBPTOut(
        uint256[] memory normalizedWeights,
        uint256[] memory currentBalances,
        address recipient,
        uint256[] memory amountsIn,
        uint256 minimumBPT,
        uint256 protocolFeePercentage
    ) private returns (uint256[] memory, uint256[] memory) {
        uint256 currentBPT = totalSupply();
        require(currentBPT > 0, "ERR_UNINITIALIZED");

        uint256 bptAmountOut = _exactTokensInForBPTOut(
            currentBalances,
            normalizedWeights,
            amountsIn,
            currentBPT,
            _swapFee
        );

        require(bptAmountOut >= minimumBPT, "ERR_BPT_OUT_MIN_AMOUNT");

        _mintPoolTokens(recipient, bptAmountOut);

        IERC20[] memory tokens = _vault.getPoolTokens(_poolId);
        for (uint8 i = 0; i < tokens.length; i++) {
            currentBalances[i] = currentBalances[i] + amountsIn[i];
        }

        uint256[] memory dueProtocolFeeAmounts = new uint256[](tokens.length); // All zeroes
        return (amountsIn, dueProtocolFeeAmounts);
    }

    // Computes the invariant given the current balances and normalized weights.
    function _invariant(uint256[] memory normalizedWeights, uint256[] memory balances)
        internal
        pure
        returns (uint256 invariant)
    {
        /**********************************************************************************************
        // invariant               _____                                                             //
        // wi = weight index i      | |      wi                                                      //
        // bi = balance index i     | |  bi ^   = i                                                  //
        // i = invariant                                                                             //
        **********************************************************************************************/
        require(normalizedWeights.length == balances.length, "ERR_BALANCES_LENGTH");

        invariant = ONE;
        for (uint8 i = 0; i < normalizedWeights.length; i++) {
            invariant = invariant * (LogExpMath.pow(balances[i], normalizedWeights[i]));
        }
    }

    function _exactTokensInForBPTOut(
        uint256[] memory balances,
        uint256[] memory normalizedWeights,
        uint256[] memory amountsIn,
        uint256 bptTotalSupply,
        uint256 swapFee
    ) internal pure returns (uint256) {
        // First loop to calculate the weighted balance ratio
        // The increment `amountIn` represents for each token, as a quotient of new and current balances,
        // not accounting swap fees
        uint256[] memory tokenBalanceRatiosWithoutFee = new uint256[](amountsIn.length);
        // The weighted sum of token balance rations sans fee
        uint256 weightedBalanceRatio = 0;
        for (uint256 i = 0; i < balances.length; i++) {
            tokenBalanceRatiosWithoutFee[i] = (balances[i] + amountsIn[i]) / balances[i];
            weightedBalanceRatio = weightedBalanceRatio + tokenBalanceRatiosWithoutFee[i] * normalizedWeights[i];
        }

        //Second loop to calculate new amounts in taking into account the fee on the % excess
        // The growth of the invariant caused by the join, as a quotient of the new value and the current one
        uint256 invariantRatio = ONE;
        for (uint256 i = 0; i < balances.length; i++) {
            // Percentage of the amount supplied that will be swapped for other tokens in the pool
            uint256 tokenBalancePercentageExcess;
            // Some tokens might have amounts supplied in excess of a 'balanced' join: these are identified if
            // the token's balance ratio sans fee is larger than the weighted balance ratio, and swap fees charged
            // on the amount to swap
            if (weightedBalanceRatio >= tokenBalanceRatiosWithoutFee[i]) {
                tokenBalancePercentageExcess = 0;
            } else {
                tokenBalancePercentageExcess = (tokenBalanceRatiosWithoutFee[i] - weightedBalanceRatio) / 
                    tokenBalanceRatiosWithoutFee[i] - ONE;
            }

            uint256 amountInAfterFee = amountsIn[i] * (ONE - swapFee * tokenBalancePercentageExcess);

            uint256 tokenBalanceRatio = ONE + amountInAfterFee / balances[i];

            invariantRatio = invariantRatio * LogExpMath.pow(tokenBalanceRatio, normalizedWeights[i]);
        }

        return bptTotalSupply * (invariantRatio - ONE);
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
