module.exports = {
    port: 8555,
    skipFiles: [
      'Migrations.sol',
      'DSProxyFactory.sol',
      'test'
    ],
    testrpcOptions: "-p 8555 -d"
  };