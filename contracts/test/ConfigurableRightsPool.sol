// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.6;

// Needed to handle structures externally
pragma experimental ABIEncoderV2;

// Imports

import "./IBFactory.sol";
import "./PCToken.sol";
import "./BalancerReentrancyGuard.sol";
import "./BalancerOwnable.sol";

// Interfaces

// Libraries
import { RightsManager } from "./RightsManager.sol";
import "./SmartPoolManager.sol";

// Contracts

/**
 * @author Balancer Labs
 * @title Smart Pool with customizable features
 * @notice PCToken is the "Balancer Smart Pool" token (transferred upon finalization)
 * @dev Rights are defined as follows (index values into the array)
 *      0: canPauseSwapping - can setPublicSwap back to false after turning it on
 *                            by default, it is off on initialization and can only be turned on
 *      1: canChangeSwapFee - can setSwapFee after initialization (by default, it is fixed at create time)
 *      2: canChangeWeights - can bind new token weights (allowed by default in base pool)
 *      3: canAddRemoveTokens - can bind/unbind tokens (allowed by default in base pool)
 *      4: canWhitelistLPs - can restrict LPs to a whitelist
 *      5: canChangeCap - can change the BSP cap (max # of pool tokens)
 *
 * Note that functions called on bPool and bFactory may look like internal calls,
 *   but since they are contracts accessed through an interface, they are really external.
 * To make this explicit, we could write "IBPool(address(bPool)).function()" everywhere,
 *   instead of "bPool.function()".
 */
contract ConfigurableRightsPool is PCToken, BalancerOwnable, BalancerReentrancyGuard {
    using BalancerSafeMath for uint;

    // State variables

    IBFactory public bFactory;
    IBPool public bPool;

    // Struct holding the rights configuration
    RightsManager.Rights private _rights;

    // This is for adding a new (currently unbound) token to the pool
    // It's a two-step process: commitAddToken(), then applyAddToken()
    SmartPoolManager.NewToken private _newToken;

    // Fee is initialized on creation, and can be changed if permission is set
    // Only needed for temporary storage between construction and createPool
    // Thereafter, the swap fee should always be read from the underlying pool
    uint private _swapFee;

    // Store the list of tokens in the pool, and balances
    // NOTE that the token list is *only* used to store the pool tokens between
    //   construction and createPool - thereafter, use the underlying BPool's list
    //   (avoids synchronization issues)
    address[] private _tokens;
    uint[] private _startBalances;

    // For blockwise, automated weight updates
    // Move weights linearly from _startWeights to _newWeights,
    // between _startBlock and _endBlock
    uint private _startBlock;
    uint private _endBlock;
    uint[] private _startWeights;
    uint[] private _newWeights;

    // Enforce a minimum time between the start and end blocks
    uint private _minimumWeightChangeBlockPeriod;
    // Enforce a mandatory wait time between updates
    // This is also the wait time between committing and applying a new token
    uint private _addTokenTimeLockInBlocks;

    // Whitelist of LPs (if configured)
    mapping(address => bool) private _liquidityProviderWhitelist;

    // Cap on the pool size (i.e., # of tokens minted when joining)
    // Limits the risk of experimental pools; failsafe/backup for fixed-size pools
    uint private _bspCap;

    // Event declarations

    // Anonymous logger event - can only be filtered by contract address

    event LogCall(
        bytes4  indexed sig,
        address indexed caller,
        bytes data
    ) anonymous;

    event LogJoin(
        address indexed caller,
        address indexed tokenIn,
        uint tokenAmountIn
    );

    event LogExit(
        address indexed caller,
        address indexed tokenOut,
        uint tokenAmountOut
    );

    event CapChanged(
        address indexed caller,
        uint oldCap,
        uint newCap
    );

    // Modifiers

    modifier logs() {
        emit LogCall(msg.sig, msg.sender, msg.data);
        _;
    }

    // Mark functions that require delegation to the underlying Pool
    modifier needsBPool() {
        require(address(bPool) != address(0), "ERR_NOT_CREATED");
        _;
    }

    // Mark functions that mint pool tokens
    // (If right is not enabled, cap will be MAX_UINT, so check will always pass)
    modifier withinCap() {
        _;
        // Check after the function body runs
        require(this.totalSupply() <= _bspCap, "ERR_CAP_LIMIT_REACHED");
    }

    // Default values for these variables (used only in updateWeightsGradually), set in the constructor
    // Pools without permission to update weights cannot use them anyway, and should call
    //   the default createPool() function.
    // To override these defaults, pass them into the overloaded createPool()
    uint public constant DEFAULT_MIN_WEIGHT_CHANGE_BLOCK_PERIOD = 10;
    uint public constant DEFAULT_ADD_TOKEN_TIME_LOCK_IN_BLOCKS = 10;

    // Function declarations

    /**
     * @notice Construct a new Configurable Rights Pool (wrapper around BPool)
     * @dev _tokens and _swapFee are only used for temporary storage between construction
     *      and create pool, and should not be used thereafter! _tokens is destroyed in
     *      createPool to prevent this, and _swapFee is kept in sync (defensively), but
     *      should never be used except in this constructor and createPool()
     * @param factoryAddress - the BPoolFactory used to create the underlying pool
     * @param tokenSymbolString - Token symbol (named thus to avoid shadowing)
     * @param tokens - list of tokens to include
     * @param startBalances - initial token balances
     * @param startWeights - initial token weights
     * @param swapFee - initial swap fee (will set on the core pool after pool creation)
     * @param rights - Set of permissions we are assigning to this smart pool
     */
    constructor(
        address factoryAddress,
        string memory tokenSymbolString,
        address[] memory tokens,
        uint[] memory startBalances,
        uint[] memory startWeights,
        uint swapFee,
        RightsManager.Rights memory rights
    )
        public
        PCToken(tokenSymbolString)
    {
        // We don't have a pool yet; check now or it will fail later (in order of likelihood to fail)
        // (and be unrecoverable if they don't have permission set to change it)
        // Most likely to fail, so check first
        require(swapFee >= BalancerConstants.MIN_FEE, "ERR_INVALID_SWAP_FEE");
        require(swapFee <= BalancerConstants.MAX_FEE, "ERR_INVALID_SWAP_FEE");

        // Arrays must be parallel
        require(startBalances.length == tokens.length, "ERR_START_BALANCES_MISMATCH");
        require(startWeights.length == tokens.length, "ERR_START_WEIGHTS_MISMATCH");
        // Cannot have too many or too few - technically redundant, since BPool.bind() would fail later
        // But if we don't check now, we could have a useless contract with no way to create a pool

        require(tokens.length >= BalancerConstants.MIN_ASSET_LIMIT, "ERR_TOO_FEW_TOKENS");
        require(tokens.length <= BalancerConstants.MAX_ASSET_LIMIT, "ERR_TOO_MANY_TOKENS");
        // There are further possible checks (e.g., if they use the same token twice), but
        // we can let bind() catch things like that (i.e., not things that might reasonably work)

        bFactory = IBFactory(factoryAddress);
        _tokens = tokens;
        _startBalances = startBalances;
        _startWeights = startWeights;
        _swapFee = swapFee;
        _minimumWeightChangeBlockPeriod = DEFAULT_MIN_WEIGHT_CHANGE_BLOCK_PERIOD;
        _addTokenTimeLockInBlocks = DEFAULT_ADD_TOKEN_TIME_LOCK_IN_BLOCKS;
        // Initializing (unnecessarily) for documentation - 0 means no gradual weight change has been initiated
        _startBlock = 0;
        // By default, there is no cap (unlimited pool token minting)
        _bspCap = BalancerConstants.MAX_UINT;
        _rights = rights;
    }

    // External functions

    /**
     * @notice Set the swap fee on the underlying pool
     * @dev Keep the local version and core in sync (see below)
     *      bPool is a contract interface; function calls on it are external
     * @param swapFee in Wei
     */
    function setSwapFee(uint swapFee)
        external
        logs
        lock
        onlyOwner
        needsBPool
        virtual
    {
        require(_rights.canChangeSwapFee, "ERR_NOT_CONFIGURABLE_SWAP_FEE");

        // Like the _token list, this is only needed between construction and createPool
        // The _token list is destroyed in createPool to prevent later use, but _swapFee
        // is just a uint, so keep it in sync defensively, but always read from the
        // underlying pool after it's created
        _swapFee = swapFee;

        // Underlying pool will check against min/max fee
        bPool.setSwapFee(swapFee);
    }

    /**
     * @notice Getter for the publicSwap field on the underlying pool
     * @dev nonReentrantView, because setPublicSwap is nonReentrant
     *      bPool is a contract interface; function calls on it are external
     * @return Current value of isPublicSwap
     */
    function isPublicSwap()
        external
        logs
        lock
        needsBPool
        virtual
        returns (bool)
    {
        return bPool.isPublicSwap();
    }

    /**
     * @notice Getter for the cap
     * @return current value of the cap
     */
    function getCap()
        external
        lock
        returns (uint)
    {
        return _bspCap;
    }

    /**
     * @notice Set the cap (max # of pool tokens)
     * @dev _bspCap defaults in the constructor to unlimited
     *      Can set to 0 (or anywhere below the current supply), to halt new investment
     *      Prevent setting it before creating a pool, since createPool sets to intialSupply
     *      (it does this to avoid an unlimited cap window between construction and createPool)
     *      Therefore setting it before then has no effect, so should not be allowed
     * @param newCap - new value of the cap
     */
    function setCap(uint newCap)
        external
        logs
        lock
        needsBPool
        onlyOwner
    {
        require(_rights.canChangeCap, "ERR_CANNOT_CHANGE_CAP");

        emit CapChanged(msg.sender, _bspCap, newCap);

        _bspCap = newCap;
    }

    /**
     * @notice Set the public swap flag on the underlying pool
     * @dev If this smart pool has canPauseSwapping enabled, we can turn publicSwap off if it's already on
     *      Note that if they turn swapping off - but then finalize the pool - finalizing will turn the
     *      swapping back on. They're not supposed to finalize the underlying pool... would defeat the
     *      smart pool functions. (Only the owner can finalize the pool - which is this contract -
     *      so there is no risk from outside.)
     *
     *      bPool is a contract interface; function calls on it are external
     * @param publicSwap new value of the swap
     */
    function setPublicSwap(bool publicSwap)
        external
        logs
        lock
        onlyOwner
        needsBPool
        virtual
    {
        require(_rights.canPauseSwapping, "ERR_NOT_PAUSABLE_SWAP");

        bPool.setPublicSwap(publicSwap);
    }

    // createPools functions exceed max lines, but many are requires; unavoidable
    /* solhint-disable function-max-lines */

    /**
     * @notice Create a new Smart Pool - and set the block period time parameters
     * @dev Initialize the swap fee to the value provided in the CRP constructor
     *      Can be changed if the canChangeSwapFee permission is enabled
     *      Time parameters will be fixed at these values
     *
     *      If this contract doesn't have canChangeWeights permission - or you want to use the default
     *      values, the block time arguments
     *      are not needed, and you can just call the single-argument createPool()
     *
     *      Code is duplicated in the overloaded createPool! If you change one, change the other!
     *      Unfortunately I cannot call this.createPool(initialSupply) from the overloaded one,
     *      because msg.sender will be different (contract address vs external account), and the
     *      token transfers would fail
     * @param initialSupply starting token balance
     * @param minimumWeightChangeBlockPeriod - Enforce a minimum time between the start and end blocks
     * @param addTokenTimeLockInBlocks - Enforce a mandatory wait time between updates
     *                                   This is also the wait time between committing and applying a new token
     */
    function createPool(
        uint initialSupply,
        uint minimumWeightChangeBlockPeriod,
        uint addTokenTimeLockInBlocks
    )
        external
        logs
        lock
        virtual
    {
        require(address(bPool) == address(0), "ERR_IS_CREATED");
        require(initialSupply > 0, "ERR_INIT_SUPPLY");

        require(minimumWeightChangeBlockPeriod >= BalancerConstants.MIN_WEIGHT_CHANGE_BLOCK_PERIOD,
                "ERR_INVALID_BLOCK_PERIOD");
        require(addTokenTimeLockInBlocks <= minimumWeightChangeBlockPeriod,
                "ERR_INCONSISTENT_TOKEN_TIME_LOCK");
        require(addTokenTimeLockInBlocks >= BalancerConstants.MIN_TOKEN_TIME_LOCK_PERIOD,
                "ERR_INVALID_TOKEN_TIME_LOCK");

        _minimumWeightChangeBlockPeriod = minimumWeightChangeBlockPeriod;
        _addTokenTimeLockInBlocks = addTokenTimeLockInBlocks;

        // There is technically reentrancy here, since we're making external calls and
        //   then transferring tokens. However, the external calls are all to the underlying BPool

        // Deploy new BPool (bFactory and bPool are interfaces; all calls are external)
        bPool = bFactory.newBPool();

        // EXIT_FEE must always be zero, or ConfigurableRightsPool._pushUnderlying will fail
        require(bPool.EXIT_FEE() == 0, "ERR_NONZERO_EXIT_FEE");
        require(BalancerConstants.EXIT_FEE == 0, "ERR_NONZERO_EXIT_FEE");

        // Set fee to the initial value set in the constructor
        // Hereafter, read the swapFee from the underlying pool, not the local state variable
        bPool.setSwapFee(_swapFee);

        // If the controller can change the cap, initialize it to the initial supply
        // Defensive programming, so that there is no gap between creating the pool
        // (initialized to unlimited in the constructor), and setting the cap,
        // which they will presumably do if they have this right.
        if (_rights.canChangeCap) {
            _bspCap = initialSupply;
        }

        for (uint i = 0; i < _tokens.length; i++) {
            address t = _tokens[i];
            uint bal = _startBalances[i];
            uint denorm = _startWeights[i];

            bool returnValue = IERC20(t).transferFrom(msg.sender, address(this), bal);
            require(returnValue, "ERR_ERC20_FALSE");

            returnValue = IERC20(t).approve(address(bPool), BalancerConstants.MAX_UINT);
            require(returnValue, "ERR_ERC20_FALSE");

            // Binding pushes a token to the end of the underlying pool's array
            // After binding, we discard the local _tokens array
            bPool.bind(t, bal, denorm);
        }

        // Destroy local storage token list to prevent use of it after createPool
        // Hereafter, the token list is maintained by the underlying pool
        while (_tokens.length > 0) {
            _tokens.pop();
        }

        bPool.setPublicSwap(true);

        _mintPoolShare(initialSupply);
        _pushPoolShare(msg.sender, initialSupply);
    }

    /**
     * @notice Create a new Smart Pool
     * @dev Initialize the swap fee to the value provided in the CRP constructor
     *      Can be changed if the canChangeSwapFee permission is enabled
     *      NB:
     *      Code is duplicated in the overloaded createPool! If you change one, change the other!
     *      Unfortunately I cannot call this.createPool(initialSupply) from the overloaded one,
     *      because msg.sender will be different (contract address vs external account), and the
     *      token transfers would fail. Overloading is tricky with external functions.
     * @param initialSupply starting token balance
     */
    function createPool(uint initialSupply)
        external
        logs
        lock
        virtual
    {
        require(address(bPool) == address(0), "ERR_IS_CREATED");
        require(initialSupply > 0, "ERR_INIT_SUPPLY");

        // There is technically reentrancy here, since we're making external calls and
        // then transferring tokens. However, the external calls are all to the underlying BPool

        // Deploy new BPool (bFactory and bPool are interfaces; all calls are external)
        bPool = bFactory.newBPool();

        // EXIT_FEE must always be zero, or ConfigurableRightsPool._pushUnderlying will fail
        require(bPool.EXIT_FEE() == 0, "ERR_NONZERO_EXIT_FEE");
        require(BalancerConstants.EXIT_FEE == 0, "ERR_NONZERO_EXIT_FEE");

        // Set fee to the initial value set in the constructor
        // Hereafter, read the swapFee from the underlying pool, not the local state variable
        bPool.setSwapFee(_swapFee);

        // If the controller can change the cap, initialize it to the initial supply
        // Defensive programming, so that there is no gap between creating the pool
        // (initialized to unlimited in the constructor), and setting the cap,
        // which they will presumably do if they have this right.
        if (_rights.canChangeCap) {
            _bspCap = initialSupply;
        }

        for (uint i = 0; i < _tokens.length; i++) {
            address t = _tokens[i];
            uint bal = _startBalances[i];
            uint denorm = _startWeights[i];

            bool returnValue = IERC20(t).transferFrom(msg.sender, address(this), bal);
            require(returnValue, "ERR_ERC20_FALSE");

            returnValue = IERC20(t).approve(address(bPool), BalancerConstants.MAX_UINT);
            require(returnValue, "ERR_ERC20_FALSE");

            bPool.bind(t, bal, denorm);
        }

        // Clear local storage to prevent use of it after createPool
        while (_tokens.length > 0) {
            _tokens.pop();
        }

        // Do "finalize" things, but can't call bPool.finalize(), or it wouldn't let us rebind or do any
        // adjustments. The underlying pool has to remain unfinalized, but we want to mint the tokens
        // immediately. This is how a CRP differs from base Pool. Base Pool tokens are issued on finalize;
        // CRP pool tokens are issued on create.
        //
        // We really don't need a "CRP level" finalize. It is considered "finalized" on creation.
        // Since the underlying pool is never finalized, it is sufficient just to check that the pool exists,
        // and you can join it.
        bPool.setPublicSwap(true);

        _mintPoolShare(initialSupply);
        _pushPoolShare(msg.sender, initialSupply);
    }

    /* solhint-enable function-max-lines */

    /**
     * @notice Update the weight of an existing token
     * @dev Notice Balance is not an input (like with rebind on BPool) since we will require prices not to change
     *      This is achieved by forcing balances to change proportionally to weights, so that prices don't change
     *      If prices could be changed, this would allow the controller to drain the pool by arbing price changes
     * @param token - token to be reweighted
     * @param newWeight - new weight of the token
    */
    function updateWeight(address token, uint newWeight)
        external
        logs
        lock
        onlyOwner
        needsBPool
        virtual
    {
        require(_rights.canChangeWeights, "ERR_NOT_CONFIGURABLE_WEIGHTS");

        // We don't want people to set weights manually if there's a block-based update in progress
        require(_startBlock == 0, "ERR_NO_UPDATE_DURING_GRADUAL");

        // Delegate to library to save space
        SmartPoolManager.updateWeight(this, bPool, token, newWeight);
    }

    /**
     * @notice Update weights in a predetermined way, between startBlock and endBlock,
     *         through external calls to pokeWeights
     * @dev Must call pokeWeights at least once past the end for it to do the final update
     *      and enable calling this again.
     *      It is possible to call updateWeightsGradually during an update in some use cases
     *      For instance, setting newWeights to currentWeights to stop the update where it is
     * @param newWeights - final weights we want to get to
     * @param startBlock - when weights should start to change
     * @param endBlock - when weights will be at their final values
    */
    function updateWeightsGradually(
        uint[] calldata newWeights,
        uint startBlock,
        uint endBlock
    )
        external
        logs
        lock
        onlyOwner
        needsBPool
        virtual
    {
        require(_rights.canChangeWeights, "ERR_NOT_CONFIGURABLE_WEIGHTS");
        // After createPool, token list is maintained in the underlying BPool
        address[] memory poolTokens = bPool.getCurrentTokens();

        // Must specify weights for all tokens
        require(newWeights.length == poolTokens.length, "ERR_START_WEIGHTS_MISMATCH");

        // Delegate to library to save space

        // Library computes the startBlock, computes startWeights as the current
        // denormalized weights of the core pool tokens.
        (uint actualStartBlock,
         uint[] memory startWeights) = SmartPoolManager.updateWeightsGradually(
                                           bPool,
                                           _newToken,
                                           newWeights,
                                           startBlock,
                                           endBlock,
                                           _minimumWeightChangeBlockPeriod
                                       );
        _startBlock = actualStartBlock;
        _endBlock = endBlock;
        _newWeights = newWeights;

        for (uint i = 0; i < poolTokens.length; i++) {
            _startWeights[i] = startWeights[i];
        }
    }

    /**
     * @notice External function called to make the contract update weights according to plan
     * @dev Still works if we poke after the end of the period; also works if the weights don't change
     *      Resets if we are poking beyond the end, so that we can do it again
    */
    function pokeWeights()
        external
        logs
        lock
        needsBPool
        virtual
    {
        require(_rights.canChangeWeights, "ERR_NOT_CONFIGURABLE_WEIGHTS");

        // Don't modify state after external call (re-entrancy protection)
        uint currentStartBlock = _startBlock;
        // Reset to allow add/remove tokens, or manual weight updates
        if (block.number >= _endBlock) {
            _startBlock = 0;
        }

        // Delegate to library to save space
        SmartPoolManager.pokeWeights(
            bPool,
            currentStartBlock,
            _endBlock,
            _startWeights,
            _newWeights
        );
    }

    /**
     * @notice Schedule (commit) a token to be added; must call applyAddToken after a fixed
     *         number of blocks to actually add the token
     * @dev Not sure about the naming here. Kind of reversed; I would think you would "Apply" to add
     *      a token, then "Commit" it to actually do the binding.
     * @param token - the token to be added
     * @param balance - how much to be added
     * @param denormalizedWeight - the desired token weight
     */
    function commitAddToken(
        address token,
        uint balance,
        uint denormalizedWeight
    )
        external
        logs
        lock
        onlyOwner
        needsBPool
        virtual
    {
        require(_rights.canAddRemoveTokens, "ERR_CANNOT_ADD_REMOVE_TOKENS");

        // Can't do this while a progressive update is happening
        require(_startBlock == 0, "ERR_NO_UPDATE_DURING_GRADUAL");

        // Delegate to library to save space
        SmartPoolManager.commitAddToken(
            bPool,
            token,
            balance,
            denormalizedWeight,
            _newToken
        );
    }

    /**
     * @notice Add the token previously committed (in commitAddToken) to the pool
     */
    function applyAddToken()
        external
        logs
        lock
        onlyOwner
        needsBPool
        virtual
    {
        require(_rights.canAddRemoveTokens, "ERR_CANNOT_ADD_REMOVE_TOKENS");

        // Delegate to library to save space
        SmartPoolManager.applyAddToken(
            this,
            bPool,
            _addTokenTimeLockInBlocks,
            _newToken
        );
    }

     /**
     * @notice Remove a token from the pool
     * @dev bPool is a contract interface; function calls on it are external
     * @param token - token to remove
     */
    function removeToken(address token)
        external
        logs
        lock
        onlyOwner
        needsBPool
    {
        require(_rights.canAddRemoveTokens, "ERR_CANNOT_ADD_REMOVE_TOKENS");
        // After createPool, token list is maintained in the underlying BPool
        address[] memory poolTokens = bPool.getCurrentTokens();

        require(poolTokens.length > BalancerConstants.MIN_ASSET_LIMIT, "ERR_TOO_FEW_TOKENS");
        require(!_newToken.isCommitted, "ERR_REMOVE_WITH_ADD_PENDING");

        // Delegate to library to save space
        SmartPoolManager.removeToken(
            this,
            bPool,
            token
        );
   }

    /**
     * @notice Join a pool
     * @dev Emits a LogJoin event (for each token)
     *      bPool is a contract interface; function calls on it are external
     * @param poolAmountOut - number of pool tokens to receive
     * @param maxAmountsIn - Max amount of asset tokens to spend
     */
    function joinPool(uint poolAmountOut, uint[] calldata maxAmountsIn)
         external
        logs
        lock
        needsBPool
        withinCap
    {
        require(!_rights.canWhitelistLPs || _liquidityProviderWhitelist[msg.sender],
                "ERR_NOT_ON_WHITELIST");

        // Delegate to library to save space

        // Library computes actualAmountsIn, and does many validations
        // Cannot call the push/pull/min from an external library for
        // any of these pool functions. Since msg.sender can be anybody,
        // they must be internal
        uint[] memory actualAmountsIn = SmartPoolManager.joinPool(
                                            this,
                                            bPool,
                                            poolAmountOut,
                                            maxAmountsIn
                                        );

        // After createPool, token list is maintained in the underlying BPool
        address[] memory poolTokens = bPool.getCurrentTokens();

        for (uint i = 0; i < poolTokens.length; i++) {
            address t = poolTokens[i];
            uint tokenAmountIn = actualAmountsIn[i];

            emit LogJoin(msg.sender, t, tokenAmountIn);

            _pullUnderlying(t, msg.sender, tokenAmountIn);
        }

        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);
    }

    /**
     * @notice Exit a pool - redeem pool tokens for underlying assets
     * @dev Emits a LogExit event for each token
     *      bPool is a contract interface; function calls on it are external
     * @param poolAmountIn - amount of pool tokens to redeem
     * @param minAmountsOut - minimum amount of asset tokens to receive
     */
    function exitPool(uint poolAmountIn, uint[] calldata minAmountsOut)
        external
        logs
        lock
        needsBPool
    {
        // Delegate to library to save space

        // Library computes actualAmountsOut, and does many validations
        // Also computes the exitFee and pAiAfterExitFee
        (uint exitFee,
         uint pAiAfterExitFee,
         uint[] memory actualAmountsOut) = SmartPoolManager.exitPool(
                                               this,
                                               bPool,
                                               poolAmountIn,
                                               minAmountsOut
                                           );

        _pullPoolShare(msg.sender, poolAmountIn);
        _pushPoolShare(address(bFactory), exitFee);
        _burnPoolShare(pAiAfterExitFee);

        // After createPool, token list is maintained in the underlying BPool
        address[] memory poolTokens = bPool.getCurrentTokens();

        for (uint i = 0; i < poolTokens.length; i++) {
            address t = poolTokens[i];
            uint tokenAmountOut = actualAmountsOut[i];

            emit LogExit(msg.sender, t, tokenAmountOut);

            _pushUnderlying(t, msg.sender, tokenAmountOut);
        }
    }

    /**
     * @notice Join by swapping a fixed amount of an external token in (must be present in the pool)
     *         System calculates the pool token amount
     * @dev emits a LogJoin event
     * @param tokenIn - which token we're transferring in
     * @param tokenAmountIn - amount of deposit
     * @param minPoolAmountOut - minimum of pool tokens to receive
     * @return poolAmountOut - amount of pool tokens minted and transferred
     */
    function joinswapExternAmountIn(
        address tokenIn,
        uint tokenAmountIn,
        uint minPoolAmountOut
    )
        external
        logs
        lock
        needsBPool
        withinCap
        returns (uint poolAmountOut)
    {
        require(!_rights.canWhitelistLPs || _liquidityProviderWhitelist[msg.sender],
                "ERR_NOT_ON_WHITELIST");

        // Delegate to library to save space
        poolAmountOut = SmartPoolManager.joinswapExternAmountIn(
                            this,
                            bPool,
                            tokenIn,
                            tokenAmountIn,
                            minPoolAmountOut
                        );

        emit LogJoin(msg.sender, tokenIn, tokenAmountIn);

        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);
        _pullUnderlying(tokenIn, msg.sender, tokenAmountIn);

        return poolAmountOut;
    }

    /**
     * @notice Join by swapping an external token in (must be present in the pool)
     *         To receive an exact amount of pool tokens out. System calculates the deposit amount
     * @dev emits a LogJoin event
     * @param tokenIn - which token we're transferring in (system calculates amount required)
     * @param poolAmountOut - amount of pool tokens to be received
     * @param maxAmountIn - Maximum asset tokens that can be pulled to pay for the pool tokens
     * @return tokenAmountIn - amount of asset tokens transferred in to purchase the pool tokens
     */
    function joinswapPoolAmountOut(
        address tokenIn,
        uint poolAmountOut,
        uint maxAmountIn
    )
        external
        logs
        lock
        needsBPool
        withinCap
        returns (uint tokenAmountIn)
    {
        require(!_rights.canWhitelistLPs || _liquidityProviderWhitelist[msg.sender],
                "ERR_NOT_ON_WHITELIST");

        // Delegate to library to save space
        tokenAmountIn = SmartPoolManager.joinswapPoolAmountOut(
                            this,
                            bPool,
                            tokenIn,
                            poolAmountOut,
                            maxAmountIn
                        );

        emit LogJoin(msg.sender, tokenIn, tokenAmountIn);

        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);
        _pullUnderlying(tokenIn, msg.sender, tokenAmountIn);

        return tokenAmountIn;
    }

    /**
     * @notice Exit a pool - redeem a specific number of pool tokens for an underlying asset
     *         Asset must be present in the pool, and will incur an EXIT_FEE (if set to non-zero)
     * @dev Emits a LogExit event for the token
     * @param tokenOut - which token the caller wants to receive
     * @param poolAmountIn - amount of pool tokens to redeem
     * @param minAmountOut - minimum asset tokens to receive
     * @return tokenAmountOut - amount of asset tokens returned
     */
    function exitswapPoolAmountIn(
        address tokenOut,
        uint poolAmountIn,
        uint minAmountOut
    )
        external
        logs
        lock
        needsBPool
        returns (uint tokenAmountOut)
    {
        // Delegate to library to save space

        // Calculates final amountOut, and the fee and final amount in
        (uint exitFee,
         uint amountOut) = SmartPoolManager.exitswapPoolAmountIn(
                               this,
                               bPool,
                               tokenOut,
                               poolAmountIn,
                               minAmountOut
                           );

        tokenAmountOut = amountOut;
        uint pAiAfterExitFee = BalancerSafeMath.bsub(poolAmountIn, exitFee);

        emit LogExit(msg.sender, tokenOut, tokenAmountOut);

        _pullPoolShare(msg.sender, poolAmountIn);
        _burnPoolShare(pAiAfterExitFee);
        _pushPoolShare(address(bFactory), exitFee);
        _pushUnderlying(tokenOut, msg.sender, tokenAmountOut);

        return tokenAmountOut;
    }

    /**
     * @notice Exit a pool - redeem pool tokens for a specific amount of underlying assets
     *         Asset must be present in the pool
     * @dev Emits a LogExit event for the token
     * @param tokenOut - which token the caller wants to receive
     * @param tokenAmountOut - amount of underlying asset tokens to receive
     * @param maxPoolAmountIn - maximum pool tokens to be redeemed
     * @return poolAmountIn - amount of pool tokens redeemed
     */
    function exitswapExternAmountOut(
        address tokenOut,
        uint tokenAmountOut,
        uint maxPoolAmountIn
    )
        external
        logs
        lock
        needsBPool
        returns (uint poolAmountIn)
    {
        // Delegate to library to save space

        // Calculates final amounts in, accounting for the exit fee
        (uint exitFee,
         uint amountIn) = SmartPoolManager.exitswapExternAmountOut(
                              this,
                              bPool,
                              tokenOut,
                              tokenAmountOut,
                              maxPoolAmountIn
                          );

        poolAmountIn = amountIn;
        uint pAiAfterExitFee = BalancerSafeMath.bsub(poolAmountIn, exitFee);

        emit LogExit(msg.sender, tokenOut, tokenAmountOut);

        _pullPoolShare(msg.sender, poolAmountIn);
        _burnPoolShare(pAiAfterExitFee);
        _pushPoolShare(address(bFactory), exitFee);
        _pushUnderlying(tokenOut, msg.sender, tokenAmountOut);

        return poolAmountIn;
    }

    /**
     * @notice Add to the whitelist of liquidity providers (if enabled)
     * @param provider - address of the liquidity provider
     */
    function whitelistLiquidityProvider(address provider)
        external
        onlyOwner
        lock
        logs
    {
        require(_rights.canWhitelistLPs, "ERR_CANNOT_WHITELIST_LPS");
        require(provider != address(0), "ERR_INVALID_ADDRESS");

        _liquidityProviderWhitelist[provider] = true;
    }

    /**
     * @notice Remove from the whitelist of liquidity providers (if enabled)
     * @param provider - address of the liquidity provider
     */
    function removeWhitelistedLiquidityProvider(address provider)
        external
        onlyOwner
        lock
        logs
    {
        require(_rights.canWhitelistLPs, "ERR_CANNOT_WHITELIST_LPS");
        require(_liquidityProviderWhitelist[provider], "ERR_LP_NOT_WHITELISTED");
        require(provider != address(0), "ERR_INVALID_ADDRESS");

        _liquidityProviderWhitelist[provider] = false;
    }

    /**
     * @notice Check if an address is a liquidity provider
     * @dev If the whitelist feature is not enabled, anyone can provide liquidity (assuming finalized)
     * @return boolean value indicating whether the address can join a pool
     */
    function canProvideLiquidity(address provider)
        external
        view
        returns(bool)
    {
        if (_rights.canWhitelistLPs) {
            return _liquidityProviderWhitelist[provider];
        }
        else {
            // Probably don't strictly need this (could just return true)
            // But the null address can't provide funds
            return provider != address(0);
        }
    }

    /**
     * @notice Getter for specific permissions
     * @dev value of the enum is just the 0-based index in the enumeration
     *      For instance canPauseSwapping is 0; canChangeWeights is 2
     * @return token boolean true if we have the given permission
    */
    function hasPermission(RightsManager.Permissions permission)
        external
        view
        virtual
        returns(bool)
    {
        return RightsManager.hasPermission(_rights, permission);
    }

    /**
     * @notice Get the denormalized weight of a token
     * @dev viewlock to prevent calling if it's being updated
     * @return token weight
     */
    function getDenormalizedWeight(address token)
        external
        view
        viewlock
        needsBPool
        returns (uint)
    {
        return bPool.getDenormalizedWeight(token);
    }

    /**
     * @notice Getter for the RightsManager contract
     * @dev Convenience function to get the address of the RightsManager library (so clients can check version)
     * @return address of the RightsManager library
    */
    function getRightsManagerVersion() external pure returns (address) {
        return address(RightsManager);
    }

    /**
     * @notice Getter for the BalancerSafeMath contract
     * @dev Convenience function to get the address of the BalancerSafeMath library (so clients can check version)
     * @return address of the BalancerSafeMath library
    */
    function getBalancerSafeMathVersion() external pure returns (address) {
        return address(BalancerSafeMath);
    }

    /**
     * @notice Getter for the SmartPoolManager contract
     * @dev Convenience function to get the address of the SmartPoolManager library (so clients can check version)
     * @return address of the SmartPoolManager library
    */
    function getSmartPoolManagerVersion() external pure returns (address) {
        return address(SmartPoolManager);
    }

    // Public functions

    // "Public" versions that can safely be called from SmartPoolManager
    // Allows only the contract itself to call them (not the controller or any external account)

    // withinCap is overkill here (will get called twice in normal operation)
    // Just defensive in case it somehow gets called from somewhere else
    function mintPoolShareFromLib(uint amount) public withinCap {
        require (msg.sender == address(this), "ERR_NOT_CONTROLLER");

        _mint(amount);
    }

    function pushPoolShareFromLib(address to, uint amount) public {
        require (msg.sender == address(this), "ERR_NOT_CONTROLLER");

        _push(to, amount);
    }

    function pullPoolShareFromLib(address from, uint amount) public  {
        require (msg.sender == address(this), "ERR_NOT_CONTROLLER");

        _pull(from, amount);
    }

    function burnPoolShareFromLib(uint amount) public  {
        require (msg.sender == address(this), "ERR_NOT_CONTROLLER");

        _burn(amount);
    }

    // Internal functions

    // Lint wants the function to have a leading underscore too
    /* solhint-disable private-vars-leading-underscore */

    // Accessor to allow subclasses to check the start block
    function getStartBlock() internal view returns (uint) {
        return _startBlock;
    }

    /* solhint-enable private-vars-leading-underscore */

    // Rebind BPool and pull tokens from address
    // bPool is a contract interface; function calls on it are external
    function _pullUnderlying(address erc20, address from, uint amount) internal needsBPool {
        // Gets current Balance of token i, Bi, and weight of token i, Wi, from BPool.
        uint tokenBalance = bPool.getBalance(erc20);
        uint tokenWeight = bPool.getDenormalizedWeight(erc20);

        bool xfer = IERC20(erc20).transferFrom(from, address(this), amount);
        require(xfer, "ERR_ERC20_FALSE");
        bPool.rebind(erc20, BalancerSafeMath.badd(tokenBalance, amount), tokenWeight);
    }

    // Rebind BPool and push tokens to address
    // bPool is a contract interface; function calls on it are external
    function _pushUnderlying(address erc20, address to, uint amount) internal needsBPool {
        // Gets current Balance of token i, Bi, and weight of token i, Wi, from BPool.
        uint tokenBalance = bPool.getBalance(erc20);
        uint tokenWeight = bPool.getDenormalizedWeight(erc20);
        bPool.rebind(erc20, BalancerSafeMath.bsub(tokenBalance, amount), tokenWeight);

        bool xfer = IERC20(erc20).transfer(to, amount);
        require(xfer, "ERR_ERC20_FALSE");
    }

    // Wrappers around corresponding core functions

    // withinCap is overkill here (will get called twice in normal operation)
    // Just defensive in case it somehow gets called from somewhere else
    function _mintPoolShare(uint amount) internal withinCap {
        _mint(amount);
    }

    function _pushPoolShare(address to, uint amount) internal {
        _push(to, amount);
    }

    function _pullPoolShare(address from, uint amount) internal  {
        _pull(from, amount);
    }

    function _burnPoolShare(uint amount) internal  {
        _burn(amount);
    }
}