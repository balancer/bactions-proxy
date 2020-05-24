const TTokenFactory = artifacts.require("TTokenFactory");
const DSProxyFactory = artifacts.require("DSProxyFactory");

module.exports = async function(deployer, network, accounts) {
    if (network == 'development' || network == 'coverage') {
        deployer.deploy(TTokenFactory);
        deployer.deploy(DSProxyFactory);
    }
}
