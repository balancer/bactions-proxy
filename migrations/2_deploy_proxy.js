const RightsManager = artifacts.require('RightsManager');
const SmartPoolManager = artifacts.require('SmartPoolManager');
const CRPFactory = artifacts.require('CRPFactory');
const BalancerSafeMath = artifacts.require('BalancerSafeMath');
const BActions = artifacts.require('BActions');
const BFactory = artifacts.require('BFactory');

module.exports = async function(deployer, network, accounts) {
    if (network == 'development' || network == 'coverage') {
        await deployer.deploy(RightsManager);
        await deployer.deploy(SmartPoolManager);
        await deployer.deploy(BFactory);
        await deployer.deploy(BalancerSafeMath);

        deployer.link(BalancerSafeMath, CRPFactory);
        deployer.link(RightsManager, CRPFactory);
        deployer.link(SmartPoolManager, CRPFactory);

        await deployer.deploy(CRPFactory);

        await deployer.deploy(BActions, BFactory.address);
    } else if (network == 'kovan-fork' || network == 'kovan') {
        deployer.deploy(BActions, '0x8f7F78080219d4066A8036ccD30D588B416a40DB');
    }
}
