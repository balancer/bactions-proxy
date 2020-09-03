const TToken = artifacts.require('TToken');
const TTokenFactory = artifacts.require('TTokenFactory');
const BFactory = artifacts.require('BFactory');
const CRPFactory = artifacts.require('CRPFactory');
const BActions = artifacts.require('BActions');
const DSProxyFactory = artifacts.require('DSProxyFactory');
const DSProxy = artifacts.require('DSProxy');
const BPool = artifacts.require('BPool');
const ConfigurableRightsPool = artifacts.require('ConfigurableRightsPool');

contract('BActions', async (accounts) => {
    const creator = accounts[0];
    const user = accounts[1];
    const { toHex, toWei, fromWei } = web3.utils;

    const MAX = web3.utils.toTwosComplement(-1);

    describe('Smart pool', () => {
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

        before(async () => {
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
            const name = 'Test Pool';
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
                canChangeSwapFee: false,
                canChangeWeights: true,
                canAddRemoveTokens: true,
                canWhitelistLPs: false,
                canChangeCap: false,
            };

            const createSmartPoolInterface = BActions.abi
                .find((iface) => iface.name === 'createSmartPool');

            const params = [
                CRP_FACTORY,
                FACTORY,
                symbol,
                name,
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

        it('pulls correct amount of tokens from creator', async () => {
            const daiBalance = await dai.balanceOf(creator);
            const mkrBalance = await mkr.balanceOf(creator);
            const wethBalance = await weth.balanceOf(creator);

            assert.equal(daiBalance, toWei('100'));
            assert.equal(mkrBalance, toWei('1'));
            assert.equal(wethBalance, toWei('1'));
        });

        it('pushes correct amount of pool shares to creator', async () => {
            const crp = await ConfigurableRightsPool.at(POOL);
            const shareBalance = await crp.balanceOf(creator);

            assert.equal(shareBalance, toWei('200'));
        });

        it('is not finalized', async () => {
            const bpool = await BPool.at(UNDERLYING_POOL);
            const isFinalized = await bpool.isFinalized.call();

            assert.isFalse(isFinalized);
        });

        it('has correct tokens', async () => {
            const bpool = await BPool.at(UNDERLYING_POOL);
            const tokens = await bpool.getCurrentTokens.call();

            assert.sameMembers(tokens, [DAI, MKR, WETH]);
        });

        it('has correct amounts', async () => {
            const bpool = await BPool.at(UNDERLYING_POOL);

            const daiBalance = await bpool.getBalance(DAI);
            const mkrBalance = await bpool.getBalance(MKR);
            const wethBalance = await bpool.getBalance(WETH);

            assert.equal(daiBalance, toWei('400'));
            assert.equal(mkrBalance, toWei('1'));
            assert.equal(wethBalance, toWei('4'));
        });

        it('has correct weights', async () => {
            const bpool = await BPool.at(UNDERLYING_POOL);

            const daiWeight = await bpool.getDenormalizedWeight(DAI);
            const mkrWeight = await bpool.getDenormalizedWeight(MKR);
            const wethWeight = await bpool.getDenormalizedWeight(WETH);

            assert.equal(daiWeight, toWei('10'));
            assert.equal(mkrWeight, toWei('10'));
            assert.equal(wethWeight, toWei('20'));
        });

        it('has correct rights', async () => {
            const crp = await ConfigurableRightsPool.at(POOL);

            const canPauseSwapping = await crp.hasPermission(0);
            const canChangeSwapFee = await crp.hasPermission(1);
            const canChangeWeights = await crp.hasPermission(2);
            const canAddRemoveTokens = await crp.hasPermission(3);
            const canWhitelistLPs = await crp.hasPermission(4);
            const canChangeCap = await crp.hasPermission(5);

            assert.isTrue(canPauseSwapping);
            assert.isFalse(canChangeSwapFee);
            assert.isTrue(canChangeWeights);
            assert.isTrue(canAddRemoveTokens);
            assert.isFalse(canWhitelistLPs);
            assert.isFalse(canChangeCap);
        });

        it('allows joining from creator', async () => {
            const crp = await ConfigurableRightsPool.at(POOL);

            const joinInterface = BActions.abi.find((iface) => iface.name === 'joinSmartPool');
            const params = [
                POOL,
                toWei('40'),
                [toWei('80'), toWei('0.2'), toWei('0.8')],
            ];

            const initialDaiBalance = await dai.balanceOf(creator);
            const initialMkrBalance = await mkr.balanceOf(creator);
            const initialWethBalance = await weth.balanceOf(creator);
            const initialShareBalance = await crp.balanceOf(creator);

            const functionCall = web3.eth.abi.encodeFunctionCall(joinInterface, params);
            await creatorProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);

            const daiBalance = await dai.balanceOf(creator);
            const mkrBalance = await mkr.balanceOf(creator);
            const wethBalance = await weth.balanceOf(creator);
            const shareBalance = await crp.balanceOf(creator);

            assert.isAtMost(parseFloat(fromWei(initialDaiBalance.sub(daiBalance))), 80);
            assert.isAtMost(parseFloat(fromWei(initialMkrBalance.sub(mkrBalance))), 0.2);
            assert.isAtMost(parseFloat(fromWei(initialWethBalance.sub(wethBalance))), 0.8);
            assert.equal(parseInt(fromWei(shareBalance.sub(initialShareBalance)), 10), 40);
        });

        it('allows joining from user', async () => {
            const crp = await ConfigurableRightsPool.at(POOL);

            const joinInterface = BActions.abi.find((iface) => iface.name === 'joinSmartPool');
            const params = [
                POOL,
                toWei('80'),
                [toWei('200'), toWei('0.5'), toWei('2')],
            ];

            const initialDaiBalance = await dai.balanceOf(user);
            const initialMkrBalance = await mkr.balanceOf(user);
            const initialWethBalance = await weth.balanceOf(user);
            const initialShareBalance = await crp.balanceOf(user);

            const functionCall = web3.eth.abi.encodeFunctionCall(joinInterface, params);
            await userProxy.methods['execute(address,bytes)'](BACTIONS, functionCall, {
                from: user,
            });

            const daiBalance = await dai.balanceOf(user);
            const mkrBalance = await mkr.balanceOf(user);
            const wethBalance = await weth.balanceOf(user);
            const shareBalance = await crp.balanceOf(user);

            assert.isAtMost(parseFloat(fromWei(initialDaiBalance.sub(daiBalance))), 200);
            assert.isAtMost(parseFloat(fromWei(initialMkrBalance.sub(mkrBalance))), 0.5);
            assert.isAtMost(parseFloat(fromWei(initialWethBalance.sub(wethBalance))), 2);
            assert.equal(parseInt(fromWei(shareBalance.sub(initialShareBalance)), 10), 80);
        });

        it('allows joinswap from user', async () => {
            const crp = await ConfigurableRightsPool.at(POOL);

            const joinswapExternAmountInInterface = BActions.abi
                .find((iface) => iface.name === 'joinswapExternAmountIn');
            const params = [
                POOL,
                MKR,
                toWei('0.3'),
                toWei('14'),
            ];

            const initialDaiBalance = await dai.balanceOf(user);
            const initialMkrBalance = await mkr.balanceOf(user);
            const initialWethBalance = await weth.balanceOf(user);
            const initialShareBalance = await crp.balanceOf(user);

            const functionCall = web3.eth.abi
                .encodeFunctionCall(joinswapExternAmountInInterface, params);
            await userProxy.methods['execute(address,bytes)'](BACTIONS, functionCall, {
                from: user,
            });

            const daiBalance = await dai.balanceOf(user);
            const mkrBalance = await mkr.balanceOf(user);
            const wethBalance = await weth.balanceOf(user);
            const shareBalance = await crp.balanceOf(user);

            assert.equal(fromWei(daiBalance), fromWei(initialDaiBalance));
            assert.equal(parseFloat(fromWei(initialMkrBalance.sub(mkrBalance))), 0.3);
            assert.equal(fromWei(wethBalance), fromWei(initialWethBalance));
            assert.isAtLeast(parseFloat(fromWei(shareBalance.sub(initialShareBalance))), 14);
        });
    });
});
