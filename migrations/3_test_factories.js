const TTokenFactory = artifacts.require("TTokenFactory");
const DSProxyFactory = artifacts.require("DSProxyFactory");

module.exports = async function(deployer, network, accounts) {
    if (network == 'development' || network == 'soliditycoverage') {
        deployer.deploy(TTokenFactory);
        deployer.deploy(DSProxyFactory);
    }
}
