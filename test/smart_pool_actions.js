const truffleAssert = require('truffle-assertions');
const util = require('util');

const TToken = artifacts.require('TToken');
const TTokenFactory = artifacts.require('TTokenFactory');
const BFactory = artifacts.require('BFactory');
const CRPFactory = artifacts.require('CRPFactory');
const BActions = artifacts.require('BActions');
const DSProxyFactory = artifacts.require('DSProxyFactory');
const DSProxy = artifacts.require('DSProxy');
const BPool = artifacts.require('BPool');
const ConfigurableRightsPool = artifacts.require('ConfigurableRightsPool');

async function waitNBlocks(n) {
    const send = util.promisify(web3.currentProvider.send);
    await Promise.all(
        [...Array(n).keys()].map((i) => send({
            jsonrpc: '2.0',
            method: 'evm_mine',
            id: i,
        })),
    );
}

contract('BActions', async (accounts) => {
    const creator = accounts[0];
    const user = accounts[1];
    const { toHex, toWei, fromWei } = web3.utils;

    const MAX = web3.utils.toTwosComplement(-1);

    describe('Smart pool actions', () => {
        let bactions;
        let BACTIONS;
        let factory;
        let FACTORY;
        let crpFactory;
        let CRP_FACTORY;
        let tokenFactory;
        let proxyFactory;
        let creatorProxy;
        let CREATOR_PROXY;
        let userProxy;
        let USER_PROXY;
        let POOL;
        let UNDERLYING_POOL;
        let dai; let mkr; let weth;
        let DAI; let MKR; let WETH;

        beforeEach(async () => {
            bactions = await BActions.deployed();
            BACTIONS = bactions.address;

            factory = await BFactory.deployed();
            FACTORY = factory.address;

            crpFactory = await CRPFactory.deployed();
            CRP_FACTORY = crpFactory.address;

            tokenFactory = await TTokenFactory.deployed();
            proxyFactory = await DSProxyFactory.deployed();

            await tokenFactory.build(toHex('DAI'), toHex('DAI'), 18);
            await tokenFactory.build(toHex('MKR'), toHex('MKR'), 18);
            await tokenFactory.build(toHex('WETH'), toHex('WETH'), 18);

            DAI = await tokenFactory.get.call(toHex('DAI'));
            MKR = await tokenFactory.get.call(toHex('MKR'));
            WETH = await tokenFactory.get.call(toHex('WETH'));

            dai = await TToken.at(DAI);
            mkr = await TToken.at(MKR);
            weth = await TToken.at(WETH);

            await dai.mint(creator, toWei('500'));
            await mkr.mint(creator, toWei('2'));
            await weth.mint(creator, toWei('5'));

            await dai.mint(user, toWei('200'));
            await mkr.mint(user, toWei('5'));
            await weth.mint(user, toWei('5'));

            CREATOR_PROXY = await proxyFactory.build.call({ from: creator });
            await proxyFactory.build({ from: creator });
            creatorProxy = await DSProxy.at(CREATOR_PROXY);
            USER_PROXY = await proxyFactory.build.call({ from: user });
            await proxyFactory.build({ from: user });
            userProxy = await DSProxy.at(USER_PROXY);

            await dai.approve(CREATOR_PROXY, MAX);
            await mkr.approve(CREATOR_PROXY, MAX);
            await weth.approve(CREATOR_PROXY, MAX);

            await dai.approve(USER_PROXY, MAX, { from: user });
            await mkr.approve(USER_PROXY, MAX, { from: user });
            await weth.approve(USER_PROXY, MAX, { from: user });

            const symbol = 'TEST';
            const poolParams = {
                tokens: [DAI, MKR, WETH],
                balances: [toWei('400'), toWei('1'), toWei('4')],
                weights: [toWei('10'), toWei('10'), toWei('20')],
                swapFee: toWei('0.0015'),
            };
            const crpParams = {
                initialSupply: toWei('200'),
                minimumWeightChangeBlockPeriod: 10,
                addTokenTimeLockInBlocks: 10,
            };
            const rights = {
                canPauseSwapping: true,
                canChangeSwapFee: true,
                canChangeWeights: true,
                canAddRemoveTokens: true,
                canWhitelistLPs: true,
                canChangeCap: true,
            };

            const createSmartPoolInterface = BActions.abi
                .find((iface) => iface.name === 'createSmartPool');

            const params = [
                CRP_FACTORY,
                FACTORY,
                symbol,
                poolParams,
                crpParams,
                rights,
            ];

            const functionCall = web3.eth.abi
                .encodeFunctionCall(createSmartPoolInterface, params);

            const poolAddress = await creatorProxy.methods['execute(address,bytes)'].call(
                BACTIONS, functionCall,
            );
            POOL = `0x${poolAddress.slice(-40)}`;

            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            const crp = await ConfigurableRightsPool.at(POOL);
            UNDERLYING_POOL = await crp.bPool();
        });

        it('does not allow joining', async () => {
            const joinInterface = BActions.abi.find((iface) => iface.name === 'joinSmartPool');
            const params = [
                POOL,
                toWei('40'),
                [toWei('80'), toWei('0.2'), toWei('0.8')],
            ];

            const functionCall = web3.eth.abi.encodeFunctionCall(joinInterface, params);
            await truffleAssert.fails(
                creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall),
                truffleAssert.ErrorType.REVERT,
                'ERR_NOT_ON_WHITELIST',
            );
        });

        it('does not allow joinswap', async () => {
            const joinswapInterface = BActions.abi
                .find((iface) => iface.name === 'joinswapExternAmountIn');
            const params = [
                POOL,
                MKR,
                toWei('0.3'),
                toWei('7'),
            ];

            const functionCall = web3.eth.abi.encodeFunctionCall(joinswapInterface, params);
            await truffleAssert.fails(
                creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall),
                truffleAssert.ErrorType.REVERT,
                'ERR_NOT_ON_WHITELIST',
            );
        });

        it('does not allow changing params by user', async () => {
            const setPublicSwapInterface = BActions.abi
                .find((iface) => iface.name === 'setPublicSwap');
            let params = [
                POOL,
                false,
            ];

            let functionCall = web3.eth.abi
                .encodeFunctionCall(setPublicSwapInterface, params);
            await truffleAssert.fails(
                userProxy.methods['execute(address,bytes)'](BACTIONS, functionCall, { from: user }),
                truffleAssert.ErrorType.REVERT,
                'ERR_NOT_CONTROLLER',
            );

            const setSwapFeeInterface = BActions.abi
                .find((iface) => iface.name === 'setSwapFee');
            params = [
                POOL,
                toWei('0.01'),
            ];

            functionCall = web3.eth.abi
                .encodeFunctionCall(setSwapFeeInterface, params);
            await truffleAssert.fails(
                userProxy.methods['execute(address,bytes)'](BACTIONS, functionCall, { from: user }),
                truffleAssert.ErrorType.REVERT,
                'ERR_NOT_CONTROLLER',
            );

            const setControllerInterface = BActions.abi
                .find((iface) => iface.name === 'setController');
            params = [
                POOL,
                USER_PROXY,
            ];

            functionCall = web3.eth.abi
                .encodeFunctionCall(setControllerInterface, params);
            await truffleAssert.fails(
                userProxy.methods['execute(address,bytes)'](BACTIONS, functionCall, { from: user }),
                truffleAssert.ErrorType.REVERT,
                'ERR_NOT_CONTROLLER',
            );
        });

        it('allows toggling public swap', async () => {
            const bpool = await BPool.at(UNDERLYING_POOL);

            const initialPublicSwap = await bpool.isPublicSwap();
            assert.isTrue(initialPublicSwap, true);

            const setPublicSwapInterface = BActions.abi
                .find((iface) => iface.name === 'setPublicSwap');
            const params = [
                POOL,
                false,
            ];

            const functionCall = web3.eth.abi
                .encodeFunctionCall(setPublicSwapInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            const publicSwap = await bpool.isPublicSwap();
            assert.isFalse(publicSwap, false);
        });

        it('allows changing swap fee', async () => {
            const bpool = await BPool.at(UNDERLYING_POOL);

            const initialSwapFee = await bpool.getSwapFee();
            assert.equal(initialSwapFee, toWei('0.0015'));

            const setSwapFeeInterface = BActions.abi
                .find((iface) => iface.name === 'setSwapFee');
            const params = [
                POOL,
                toWei('0.01'),
            ];

            const functionCall = web3.eth.abi
                .encodeFunctionCall(setSwapFeeInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            const swapFee = await bpool.getSwapFee();
            assert.equal(swapFee.toString(), toWei('0.01'));
        });

        it('allows changing owner', async () => {
            const crp = await ConfigurableRightsPool.at(POOL);

            const initialController = await crp.getController();
            assert.equal(initialController, CREATOR_PROXY);

            const setControllerInterface = BActions.abi
                .find((iface) => iface.name === 'setController');
            const params = [
                POOL,
                USER_PROXY,
            ];

            const functionCall = web3.eth.abi
                .encodeFunctionCall(setControllerInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            const controller = await crp.getController();
            assert.equal(controller.toString(), USER_PROXY);
        });

        it('allows increasing token weight', async () => {
            const crp = await ConfigurableRightsPool.at(POOL);
            const bpool = await BPool.at(UNDERLYING_POOL);

            const setCapInterface = BActions.abi
                .find((iface) => iface.name === 'setCap');
            let params = [
                POOL,
                toWei('300'),
            ];

            let functionCall = web3.eth.abi
                .encodeFunctionCall(setCapInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            const increaseWeightInterface = BActions.abi
                .find((iface) => iface.name === 'increaseWeight');
            params = [
                POOL,
                MKR,
                toWei('20'),
                toWei('1'),
            ];

            const initialWeight = await bpool.getDenormalizedWeight(MKR);
            const initialMkrBalance = await mkr.balanceOf(creator);
            const initialShareBalance = await crp.balanceOf(creator);

            functionCall = web3.eth.abi
                .encodeFunctionCall(increaseWeightInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            const weight = await bpool.getDenormalizedWeight(MKR);
            const mkrBalance = await mkr.balanceOf(creator);
            const shareBalance = await crp.balanceOf(creator);

            assert.equal(initialWeight, toWei('10'));
            assert.equal(weight, toWei('20'));
            assert.equal(parseFloat(fromWei(initialMkrBalance.sub(mkrBalance))), 1);
            assert.equal(parseInt(fromWei(shareBalance.sub(initialShareBalance)), 10), 50);
        });

        it('allows decreasing token weight', async () => {
            const crp = await ConfigurableRightsPool.at(POOL);
            const bpool = await BPool.at(UNDERLYING_POOL);

            const decreaseWeightInterface = BActions.abi
                .find((iface) => iface.name === 'decreaseWeight');
            const params = [
                POOL,
                DAI,
                toWei('2'),
                toWei('40'),
            ];

            const initialWeight = await bpool.getDenormalizedWeight(DAI);
            const initialDaiBalance = await dai.balanceOf(creator);
            const initialShareBalance = await crp.balanceOf(creator);

            await crp.approve(CREATOR_PROXY, MAX);

            const functionCall = web3.eth.abi
                .encodeFunctionCall(decreaseWeightInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            const weight = await bpool.getDenormalizedWeight(DAI);
            const daiBalance = await dai.balanceOf(creator);
            const shareBalance = await crp.balanceOf(creator);

            assert.equal(initialWeight, toWei('10'));
            assert.equal(weight, toWei('2'));
            assert.equal(parseFloat(fromWei(daiBalance.sub(initialDaiBalance))), 320);
            assert.equal(parseInt(fromWei(initialShareBalance.sub(shareBalance)), 10), 40);
        });

        it('allows updating token weights gradually', async () => {
            const bpool = await BPool.at(UNDERLYING_POOL);
            const crp = await ConfigurableRightsPool.at(POOL);

            const initialDaiWeight = await bpool.getDenormalizedWeight(DAI);
            const initialMkrWeight = await bpool.getDenormalizedWeight(MKR);
            const initialWethWeight = await bpool.getDenormalizedWeight(WETH);

            assert.equal(initialDaiWeight, toWei('10'));
            assert.equal(initialMkrWeight, toWei('10'));
            assert.equal(initialWethWeight, toWei('20'));

            const newWeights = [toWei('15'), toWei('15'), toWei('10')];
            const currentBlock = await web3.eth.getBlockNumber();
            const startBlock = currentBlock + 10;
            const endBlock = startBlock + 10;

            const updateWeightsGraduallyInterface = BActions.abi
                .find((iface) => iface.name === 'updateWeightsGradually');
            const params = [
                POOL,
                newWeights,
                startBlock,
                endBlock,
            ];
            const functionCall = web3.eth.abi
                .encodeFunctionCall(updateWeightsGraduallyInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            // Wait until update complete
            await waitNBlocks(20);

            await crp.pokeWeights({ from: user });

            const daiWeight = await bpool.getDenormalizedWeight(DAI);
            const mkrWeight = await bpool.getDenormalizedWeight(MKR);
            const wethWeight = await bpool.getDenormalizedWeight(WETH);

            assert.equal(daiWeight, toWei('15'));
            assert.equal(mkrWeight, toWei('15'));
            assert.equal(wethWeight, toWei('10'));
        });

        it('allows changing cap', async () => {
            const crp = await ConfigurableRightsPool.at(POOL);

            const initialCap = await crp.getCap.call();
            assert.equal(initialCap, toWei('200'));

            const setCapInterface = BActions.abi
                .find((iface) => iface.name === 'setCap');
            const params = [
                POOL,
                toWei('500'),
            ];

            const functionCall = web3.eth.abi
                .encodeFunctionCall(setCapInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            const cap = await crp.getCap.call();
            assert.equal(cap, toWei('500'));
        });

        it('allows adding token to the pool', async () => {
            const bpool = await BPool.at(UNDERLYING_POOL);
            const crp = await ConfigurableRightsPool.at(POOL);

            await tokenFactory.build(toHex('BAL'), toHex('BAL'), 18);
            const BAL = await tokenFactory.get.call(toHex('BAL'));
            const bal = await TToken.at(BAL);
            await bal.mint(creator, toWei('5'));
            await bal.approve(CREATOR_PROXY, MAX);

            const initialTokens = await bpool.getCurrentTokens();
            const initialBalBalance = await bal.balanceOf(creator);
            const initialShareBalance = await crp.balanceOf(creator);

            // Increase cap
            const setCapInterface = BActions.abi
                .find((iface) => iface.name === 'setCap');
            let params = [
                POOL,
                toWei('500'),
            ];
            let functionCall = web3.eth.abi
                .encodeFunctionCall(setCapInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            // Commit
            const commitAddTokenInterface = BActions.abi
                .find((iface) => iface.name === 'commitAddToken');
            params = [
                POOL,
                BAL,
                toWei('5'),
                toWei('10'),
            ];
            functionCall = web3.eth.abi
                .encodeFunctionCall(commitAddTokenInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            // Wait to pass timelock
            await waitNBlocks(10);

            // Apply
            const applyAddTokenInterface = BActions.abi
                .find((iface) => iface.name === 'applyAddToken');
            params = [
                POOL,
                BAL,
                toWei('5'),
            ];
            functionCall = web3.eth.abi
                .encodeFunctionCall(applyAddTokenInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            const tokens = await bpool.getCurrentTokens();
            const balBalance = await bal.balanceOf(creator);
            const shareBalance = await crp.balanceOf(creator);

            assert.notInclude(initialTokens, BAL);
            assert.include(tokens, BAL);
            assert.equal(parseFloat(fromWei(initialBalBalance.sub(balBalance))), 5);
            assert.equal(parseInt(fromWei(shareBalance.sub(initialShareBalance)), 10), 50);
        });

        it('allows removing token from the pool', async () => {
            const bpool = await BPool.at(UNDERLYING_POOL);
            const crp = await ConfigurableRightsPool.at(POOL);

            const initialTokens = await bpool.getCurrentTokens();
            const initialDaiBalance = await dai.balanceOf(creator);
            const initialShareBalance = await crp.balanceOf(creator);

            const removeTokenInterface = BActions.abi
                .find((iface) => iface.name === 'removeToken');
            const params = [
                POOL,
                DAI,
                toWei('50'),
            ];

            await crp.approve(CREATOR_PROXY, MAX);

            const functionCall = web3.eth.abi
                .encodeFunctionCall(removeTokenInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            const tokens = await bpool.getCurrentTokens();
            const daiBalance = await dai.balanceOf(creator);
            const shareBalance = await crp.balanceOf(creator);

            assert.include(initialTokens, DAI);
            assert.notInclude(tokens, DAI);
            assert.equal(parseFloat(fromWei(daiBalance.sub(initialDaiBalance))), 400);
            assert.equal(parseInt(fromWei(initialShareBalance.sub(shareBalance)), 10), 50);
        });

        it('allows adding provider to the list', async () => {
            const crp = await ConfigurableRightsPool.at(POOL);

            const initialIsCreatorListed = await crp.canProvideLiquidity(CREATOR_PROXY);
            const initialIsUserListed = await crp.canProvideLiquidity(USER_PROXY);
            assert.equal(initialIsCreatorListed, false);
            assert.equal(initialIsUserListed, false);

            const whitelistLPInterface = BActions.abi
                .find((iface) => iface.name === 'whitelistLiquidityProvider');
            let params = [
                POOL,
                CREATOR_PROXY,
            ];
            let functionCall = web3.eth.abi
                .encodeFunctionCall(whitelistLPInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            params = [
                POOL,
                USER_PROXY,
            ];
            functionCall = web3.eth.abi
                .encodeFunctionCall(whitelistLPInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            const isCreatorListed = await crp.canProvideLiquidity(CREATOR_PROXY);
            const isUserListed = await crp.canProvideLiquidity(USER_PROXY);
            assert.equal(isCreatorListed, true);
            assert.equal(isUserListed, true);
        });

        it('allows removing provider from the list', async () => {
            const crp = await ConfigurableRightsPool.at(POOL);

            const whitelistLPInterface = BActions.abi
                .find((iface) => iface.name === 'whitelistLiquidityProvider');
            const params = [
                POOL,
                CREATOR_PROXY,
            ];
            let functionCall = web3.eth.abi
                .encodeFunctionCall(whitelistLPInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            const initialIsListed = await crp.canProvideLiquidity(CREATOR_PROXY);
            assert.equal(initialIsListed, true);

            const removeWhitelistedLPInterface = BActions.abi
                .find((iface) => iface.name === 'removeWhitelistedLiquidityProvider');
            functionCall = web3.eth.abi
                .encodeFunctionCall(removeWhitelistedLPInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            const isListed = await crp.canProvideLiquidity(CREATOR_PROXY);
            assert.equal(isListed, false);
        });
    });
});
