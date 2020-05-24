const BActions = artifacts.require("BActions");
const BFactory = artifacts.require("BFactory");

module.exports = async function(deployer, network, accounts) {
    if (network == 'development' || network == 'coverage') {
        await deployer.deploy(BFactory);
        await deployer.deploy(BActions, BFactory.address);
    } else if (network == 'kovan-fork' || network == 'kovan') {
        deployer.deploy(BActions, '0x8f7F78080219d4066A8036ccD30D588B416a40DB');
    }
    
}
