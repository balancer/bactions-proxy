const Decimal = require('decimal.js');

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

    describe('Setup', () => {
        let factory;
        let FACTORY;
        let proxyFactory;
        let PROXY_FACTORY;
        let bactions;
        let BACTIONS;
        let tokens;
        let USER_PROXY;
        let userProxy;
        let dai; let mkr;
        let DAI; let MKR;

        before(async () => {

            proxyFactory = await DSProxyFactory.deployed();
            PROXY_FACTORY = proxyFactory.address;

            bactions = await BActions.deployed();
            BACTIONS = bactions.address;

            tokens = await TTokenFactory.deployed();
            factory = await BFactory.deployed();
            FACTORY = factory.address;

            await tokens.build(toHex('DAI'), toHex('DAI'), 18);
            await tokens.build(toHex('MKR'), toHex('MKR'), 18);

            DAI = await tokens.get.call(toHex('DAI'));
            MKR = await tokens.get.call(toHex('MKR'));

            dai = await TToken.at(DAI);
            mkr = await TToken.at(MKR);

            await dai.mint(admin, toWei('10000'));
            await mkr.mint(admin, toWei('20'));

            await dai.mint(user1, toWei('10000'));
            await mkr.mint(user1, toWei('20'));

            USER_PROXY = await proxyFactory.build.call();
            await proxyFactory.build();
            userProxy = await DSProxy.at(USER_PROXY);

            await dai.approve(USER_PROXY, MAX);
            await mkr.approve(USER_PROXY, MAX);

        });

        it('deploy pool through proxy', async () => {
            let createTokens = [DAI, MKR];
            let createBalances = [toWei('10'), toWei('1')];
            let createWeights = [toWei('5'), toWei('5')];
            let swapFee = toWei('0.03')
            let finalize = true;

            const params = [
                FACTORY,
                createTokens,
                createBalances,
                createWeights,
                swapFee,
                finalize,
            ];
 
            let functionSig = web3.eth.abi.encodeFunctionSignature('create(address,address[],uint256[],uint256[],uint256,bool)')
            let functionData = web3.eth.abi.encodeParameters(['address','address[]','uint256[]','uint256[]','uint256','bool'], params);
    
            const argumentData = functionData.substring(2);
            const inputData = `${functionSig}${argumentData}`;

            let poolAddress = await userProxy.methods['execute(address,bytes)'].call(BACTIONS, inputData);
            poolAddress = '0x' + poolAddress.slice(-40)

            await userProxy.methods['execute(address,bytes)'](BACTIONS, inputData);
            
            let bpool = await BPool.at(poolAddress)
            let controller = await bpool.getController();

            assert.equal(controller, USER_PROXY);


        });

        it('joinPool through proxy', async() => {
            let createTokens = [DAI, MKR];
            let createBalances = [toWei('10'), toWei('1')];
            let createWeights = [toWei('5'), toWei('5')];
            let swapFee = toWei('0.03')
            let finalize = true;

            let params = [
                FACTORY,
                createTokens,
                createBalances,
                createWeights,
                swapFee,
                finalize,
            ];
 
            let functionSig = web3.eth.abi.encodeFunctionSignature('create(address,address[],uint256[],uint256[],uint256,bool)')
            let functionData = web3.eth.abi.encodeParameters(['address','address[]','uint256[]','uint256[]','uint256','bool'], params);
    
            let argumentData = functionData.substring(2);
            let inputData = `${functionSig}${argumentData}`;

            let poolAddress = await userProxy.methods['execute(address,bytes)'].call(BACTIONS, inputData);
            poolAddress = '0x' + poolAddress.slice(-40)

            console.log(poolAddress)

            await userProxy.methods['execute(address,bytes)'](BACTIONS, inputData);

            params = [
                poolAddress,
                toWei('100'),
                [toWei('20'), toWei('2')]
            ];
            functionSig = web3.eth.abi.encodeFunctionSignature('joinPool(address,uint256,uint256[])')
            functionData = web3.eth.abi.encodeParameters(['address','uint256','uint256[]'], params);

            argumentData = functionData.substring(2);
            inputData = `${functionSig}${argumentData}`;

            let test = await userProxy.methods['execute(address,bytes)'](BACTIONS, inputData);
        });


    });
});
