const truffleAssert = require('truffle-assertions');

const TToken = artifacts.require('TToken');
const TTokenFactory = artifacts.require('TTokenFactory');
const BFactory = artifacts.require('BFactory');
const BActions = artifacts.require('BActions');
const DSProxyFactory = artifacts.require('DSProxyFactory');
const DSProxy = artifacts.require('DSProxy');
const BPool = artifacts.require('BPool');
const Vault = artifacts.require('Vault');
const BalancerPool = artifacts.require('BalancerPool');

contract('BActions', async (accounts) => {
    const admin = accounts[0];
    const user1 = accounts[1];
    const { toHex, toWei, fromWei } = web3.utils;

    const MAX = web3.utils.toTwosComplement(-1);

    describe('Liquidity migration', () => {
        let factory;
        let FACTORY;
        let proxyFactory;
        let bactions;
        let BACTIONS;
        let tokens;
        let USER_PROXY;
        let userProxy;
        let POOL_V1;
        let VAULT;
        let POOL_V2;
        let dai; let mkr; let zrx; let weth;
        let DAI; let MKR; let ZRX; let WETH;

        before(async () => {
            proxyFactory = await DSProxyFactory.deployed();

            bactions = await BActions.deployed();
            BACTIONS = bactions.address;

            await mintTokens();
            await setupProxy();
            await createV1Pool();
            await setupV2();
        });

        async function mintTokens() {
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
        }

        async function setupProxy() {
            USER_PROXY = await proxyFactory.build.call();
            await proxyFactory.build();
            userProxy = await DSProxy.at(USER_PROXY);

            await dai.approve(USER_PROXY, MAX);
            await mkr.approve(USER_PROXY, MAX);
            await zrx.approve(USER_PROXY, MAX);
            await weth.approve(USER_PROXY, MAX);
        }

        async function createV1Pool() {
            const createTokens = [DAI, MKR, WETH];
            const createBalances = [toWei('400'), toWei('1'), toWei('2')];
            const createWeights = [toWei('5'), toWei('5'), toWei('5')];
            const swapFee = toWei('0.03');
            const finalize = true;

            const createInterface = BActions.abi.find((iface) => iface.name === 'create');

            const params = [
                FACTORY,
                createTokens,
                createBalances,
                createWeights,
                swapFee,
                finalize,
            ];

            const functionCall = web3.eth.abi.encodeFunctionCall(createInterface, params);

            const poolAddress = await userProxy.methods['execute(address,bytes)'].call(
                BACTIONS, functionCall,
            );
            POOL_V1 = `0x${poolAddress.slice(-40)}`;

            await userProxy.methods['execute(address,bytes)'](BACTIONS, functionCall);
        }

        async function setupV2() {
            const balancerPool = await BalancerPool.deployed();
            POOL_V2 = balancerPool.address;

            const vault = await Vault.deployed();
            VAULT = vault.address;

            await dai.approve(VAULT, MAX);
            await mkr.approve(VAULT, MAX);
            await zrx.approve(VAULT, MAX);
            await weth.approve(VAULT, MAX);

            const id = '0x0';
            const name = 'Balancer Pool';
            const symbol = 'BPT';
            const tokens = [DAI, MKR, WETH];
            const balances = [toWei('200'), toWei('0.5'), toWei('1')];
            const weights = [toWei('5'), toWei('5'), toWei('5')];
            const swapFee = toWei('0.03');
            const initJoinData = '0x0000000000000000000000000000000000000000000000000000000000000000';
            vault.newPool(tokens, POOL_V2);
            balancerPool.create(VAULT, id, name, symbol, tokens, weights, swapFee);
            vault.joinPool(id, admin, tokens, balances, false, initJoinData);
        }

        it('Simple migration', async () => {
            // Approve v1 BPT to proxy
            const bpt = await BPool.at(POOL_V1);
            await bpt.approve(USER_PROXY, MAX);

            const params = [
                VAULT,
                POOL_V1,
                toWei('10'),
                [0, 0, 0],
                POOL_V2,
                0,
            ];

            const startV1Balance = await bpt.balanceOf(admin); // should go 100 -> 0
            // const v2Pool = await BalancerPool.at(POOL_V2);
            // const startV2Balance = await v2Pool.balanceOf(admin); // should go 100 -> 300

            const functionSig = web3.eth.abi.encodeFunctionSignature(
                'migrate(address,address,uint256,uint256[],address,uint256)',
            );
            const functionData = web3.eth.abi.encodeParameters(
                ['address', 'address', 'uint256', 'uint256[]', 'address', 'uint256'],
                params,
            );

            const argumentData = functionData.substring(2);
            const inputData = `${functionSig}${argumentData}`;

            await userProxy.methods['execute(address,bytes)'](BACTIONS, inputData);

            const endV1Balance = await bpt.balanceOf(admin);
            // const endV2Balance = await v2Pool.balanceOf(admin);

            assert.equal(fromWei(startV1Balance.sub(endV1Balance)), '10');
            // assert.equal(fromWei(endV2Balance.sub(startV2Balance)), '200');
        });
    });
});
