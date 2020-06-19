const truffleAssert = require('truffle-assertions');

const TToken = artifacts.require('TToken');
const TTokenFactory = artifacts.require('TTokenFactory');
const BFactory = artifacts.require('BFactory');
const BActions = artifacts.require('BActions');
const DSProxyFactory = artifacts.require('DSProxyFactory');
const DSProxy = artifacts.require('DSProxy');
const BPool = artifacts.require('BPool');

contract('BActions', async (accounts) => {
    const admin = accounts[0];
    const user1 = accounts[1];
    const { toHex } = web3.utils;
    const { toWei } = web3.utils;

    const MAX = web3.utils.toTwosComplement(-1);

    describe('Private pool controls', () => {
        let factory;
        let FACTORY;
        let proxyFactory;
        let bactions;
        let BACTIONS;
        let tokens;
        let USER_PROXY;
        let userProxy;
        let POOL;
        let dai; let mkr; let zrx; let weth;
        let DAI; let MKR; let ZRX; let WETH;

        before(async () => {
            proxyFactory = await DSProxyFactory.deployed();

            bactions = await BActions.deployed();
            BACTIONS = bactions.address;

            tokens = await TTokenFactory.deployed();
            factory = await BFactory.deployed();
            FACTORY = factory.address;

            await tokens.build(toHex('DAI'), toHex('DAI'), 18);
            await tokens.build(toHex('MKR'), toHex('MKR'), 18);
            await tokens.build(toHex('ZRX'), toHex('ZRX'), 18);
            await tokens.build(toHex('WETH'), toHex('WETH'), 18);

            DAI = await tokens.get.call(toHex('DAI'));
            MKR = await tokens.get.call(toHex('MKR'));
            ZRX = await tokens.get.call(toHex('ZRX'));
            WETH = await tokens.get.call(toHex('WETH'));

            dai = await TToken.at(DAI);
            mkr = await TToken.at(MKR);
            zrx = await TToken.at(ZRX);
            weth = await TToken.at(WETH);

            await dai.mint(admin, toWei('10000'));
            await mkr.mint(admin, toWei('20'));
            await zrx.mint(admin, toWei('100'));
            await weth.mint(admin, toWei('40'));

            await dai.mint(user1, toWei('10000'));
            await mkr.mint(user1, toWei('20'));

            USER_PROXY = await proxyFactory.build.call();
            await proxyFactory.build();
            userProxy = await DSProxy.at(USER_PROXY);

            await dai.approve(USER_PROXY, MAX);
            await mkr.approve(USER_PROXY, MAX);
            await zrx.approve(USER_PROXY, MAX);
            await weth.approve(USER_PROXY, MAX);

            const createTokens = [DAI, MKR, WETH];
            const createBalances = [toWei('400'), toWei('1'), toWei('2')];
            const createWeights = [toWei('5'), toWei('5'), toWei('5')];
            const swapFee = toWei('0.03');
            const finalize = false;

            const params = [
                FACTORY,
                createTokens,
                createBalances,
                createWeights,
                swapFee,
                finalize,
            ];

            const functionSig = web3.eth.abi.encodeFunctionSignature(
                'create(address,address[],uint256[],uint256[],uint256,bool)',
            );
            const functionData = web3.eth.abi.encodeParameters(
                ['address', 'address[]', 'uint256[]', 'uint256[]', 'uint256', 'bool'],
                params,
            );

            const argumentData = functionData.substring(2);
            const inputData = `${functionSig}${argumentData}`;

            const poolAddress = await userProxy.methods['execute(address,bytes)'].call(
                BACTIONS, inputData,
            );
            POOL = `0x${poolAddress.slice(-40)}`;

            await userProxy.methods['execute(address,bytes)'](BACTIONS, inputData);
        });

        it('rebind add new token', async () => {
            const rebindTokens = [DAI, MKR, WETH, ZRX];
            const rebindBalances = [toWei('400'), toWei('1'), toWei('2'), toWei('20')];
            const rebindWeights = [toWei('5'), toWei('5'), toWei('5'), toWei('5')];

            const params = [
                POOL,
                rebindTokens,
                rebindBalances,
                rebindWeights,
            ];

            const functionSig = web3.eth.abi.encodeFunctionSignature(
                'setTokens(address,address[],uint256[],uint256[])',
            );
            const functionData = web3.eth.abi.encodeParameters(
                ['address', 'address[]', 'uint256[]', 'uint256[]'],
                params,
            );

            const argumentData = functionData.substring(2);
            const inputData = `${functionSig}${argumentData}`;

            await userProxy.methods['execute(address,bytes)'](BACTIONS, inputData);

            const bpool = await BPool.at(POOL);
            const currentTokens = await bpool.getCurrentTokens();

            assert.sameMembers(rebindTokens, currentTokens);
        });

        it('rebind decrease balance token', async () => {
            const rebindTokens = [DAI, MKR, WETH, ZRX];
            const rebindBalances = [toWei('400'), toWei('1'), toWei('2'), toWei('10')];
            const rebindWeights = [toWei('5'), toWei('5'), toWei('5'), toWei('5')];

            const params = [
                POOL,
                rebindTokens,
                rebindBalances,
                rebindWeights,
            ];

            const initUserZrxBalance = await zrx.balanceOf(admin);

            const functionSig = web3.eth.abi.encodeFunctionSignature(
                'setTokens(address,address[],uint256[],uint256[])',
            );
            const functionData = web3.eth.abi.encodeParameters(
                ['address', 'address[]', 'uint256[]', 'uint256[]'],
                params,
            );

            const argumentData = functionData.substring(2);
            const inputData = `${functionSig}${argumentData}`;

            await userProxy.methods['execute(address,bytes)'](BACTIONS, inputData);

            const bpool = await BPool.at(POOL);
            const poolZrxBalance = await bpool.getBalance(ZRX);

            assert.equal(poolZrxBalance, toWei('10'));

            const newUserZrxBalance = await zrx.balanceOf(admin);
            const balanceDiff = newUserZrxBalance - initUserZrxBalance;

            assert.equal(balanceDiff, toWei('10'));
        });

        it('rebind increase balance token', async () => {
            const rebindTokens = [DAI, MKR, WETH, ZRX];
            const rebindBalances = [toWei('400'), toWei('1'), toWei('2'), toWei('25')];
            const rebindWeights = [toWei('5'), toWei('5'), toWei('5'), toWei('5')];

            const params = [
                POOL,
                rebindTokens,
                rebindBalances,
                rebindWeights,
            ];

            const functionSig = web3.eth.abi.encodeFunctionSignature(
                'setTokens(address,address[],uint256[],uint256[])',
            );
            const functionData = web3.eth.abi.encodeParameters(
                ['address', 'address[]', 'uint256[]', 'uint256[]'],
                params,
            );

            const argumentData = functionData.substring(2);
            const inputData = `${functionSig}${argumentData}`;

            await userProxy.methods['execute(address,bytes)'](BACTIONS, inputData);

            const bpool = await BPool.at(POOL);
            const poolZrxBalance = await bpool.getBalance(ZRX);

            assert.equal(poolZrxBalance, toWei('25'));
        });

        it('fails other user interaction', async () => {
            const rebindTokens = [DAI, MKR, WETH, ZRX];
            const rebindBalances = [toWei('400'), toWei('1'), toWei('2'), toWei('25')];
            const rebindWeights = [toWei('5'), toWei('5'), toWei('5'), toWei('5')];

            const params = [
                POOL,
                rebindTokens,
                rebindBalances,
                rebindWeights,
            ];

            const functionSig = web3.eth.abi.encodeFunctionSignature(
                'setTokens(address,address[],uint256[],uint256[])',
            );
            const functionData = web3.eth.abi.encodeParameters(
                ['address', 'address[]', 'uint256[]', 'uint256[]'],
                params,
            );

            const argumentData = functionData.substring(2);
            const inputData = `${functionSig}${argumentData}`;

            await truffleAssert.reverts(
                userProxy.methods['execute(address,bytes)'](BACTIONS, inputData, { from: user1 }),
                'ds-auth-unauthorized',
            );

            const bpool = await BPool.at(POOL);

            await truffleAssert.reverts(
                bpool.rebind(ZRX, toWei('5'), toWei('5')),
                'ERR_NOT_CONTROLLER',
            );

            await truffleAssert.reverts(
                bpool.rebind(ZRX, toWei('5'), toWei('5'), { from: user1 }),
                'ERR_NOT_CONTROLLER',
            );
        });

        it('unbind token', async () => {
            const rebindTokens = [DAI, MKR, WETH, ZRX];
            const rebindBalances = [toWei('400'), toWei('0'), toWei('2'), toWei('25')];
            const rebindWeights = [toWei('5'), toWei('0'), toWei('5'), toWei('5')];

            const params = [
                POOL,
                rebindTokens,
                rebindBalances,
                rebindWeights,
            ];

            const initUserMkrBalance = await mkr.balanceOf(admin);

            const functionSig = web3.eth.abi.encodeFunctionSignature(
                'setTokens(address,address[],uint256[],uint256[])',
            );
            const functionData = web3.eth.abi.encodeParameters(
                ['address', 'address[]', 'uint256[]', 'uint256[]'],
                params,
            );

            const argumentData = functionData.substring(2);
            const inputData = `${functionSig}${argumentData}`;

            await userProxy.methods['execute(address,bytes)'](BACTIONS, inputData);

            const bpool = await BPool.at(POOL);
            const currentTokens = await bpool.getCurrentTokens();

            assert.sameMembers(currentTokens, [DAI, WETH, ZRX]);

            const newUserMkrBalance = await mkr.balanceOf(admin);
            const balanceDiff = newUserMkrBalance - initUserMkrBalance;

            assert.equal(balanceDiff, toWei('1'));
        });
    });
});
