// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.12;

pragma experimental ABIEncoderV2;

import '../common/IERC20.sol';
import './BalancerPool.sol';

// Vault mock; does not represent the actual Vault design
contract Vault {
    struct JoinPoolRequest {
        IERC20[] assets;
        uint256[] maxAmountsIn;
        bytes userData;
        bool fromInternalBalance;
    }

    uint256 _poolCount;
    mapping(bytes32 => address) internal _poolAddresses;
    mapping(bytes32 => IERC20[]) internal _poolTokens;
    mapping(bytes32 => mapping(IERC20 => uint256)) internal _poolTokenBalance;

    function newPool(IERC20[] memory tokens, address poolAddress) external returns (bytes32) {
        bytes32 poolId = bytes32(_poolCount);
        _poolTokens[poolId] = tokens;
        _poolAddresses[poolId] = poolAddress;
        _poolCount = _poolCount + 1;
        return poolId;
    }

    function getPoolTokens(bytes32 poolId) external returns (IERC20[] memory) {
        return _poolTokens[poolId];
    }

    function getPoolTokenBalances(bytes32 poolId, IERC20[] memory tokens)
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory balances = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            balances[i] = _poolTokenBalance[poolId][tokens[i]];
        }

        return balances;
    }

    function joinPool(
        bytes32 poolId,
        address sender,
        address recipient,
        JoinPoolRequest memory request
    ) external {
        require(request.assets.length == request.maxAmountsIn.length, "ERR_TOKENS_AMOUNTS_LENGTH_MISMATCH");

        uint256[] memory currentBalances = getPoolTokenBalances(poolId, request.assets);

        address pool = _poolAddresses[poolId];
        (uint256[] memory amountsIn,) = BalancerPool(pool).onJoinPool(
            poolId,
            sender,
            recipient,
            currentBalances,
            request.maxAmountsIn,
            0,
            request.userData
        );

        for (uint256 i = 0; i < request.assets.length; ++i) {
            if (amountsIn[i] > 0) {
                _increasePoolCash(poolId, request.assets[i], amountsIn[i]);
            }
        }
    }

    function _pullTokens(
        IERC20 token,
        address from,
        uint256 amount
    ) internal returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        uint256 currentBalance = token.balanceOf(address(this));
        token.transferFrom(from, address(this), amount);
        uint256 newBalance = token.balanceOf(address(this));
        return newBalance - currentBalance;
    }

    function _increasePoolCash(
        bytes32 poolId,
        IERC20 token,
        uint256 amount
    ) internal {
        uint256 currentBalance = _poolTokenBalance[poolId][token];
        _poolTokenBalance[poolId][token] = currentBalance + amount;
    }
}
