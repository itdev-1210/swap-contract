const hre = require("hardhat")
const { ethers, upgrades } = require("hardhat")
async function main() {
  
  const [deployer] = await ethers.getSigners()

  console.log(
    "Deploying contracts with the account:",
    deployer.address
  )
  
  console.log("Account balance:", (await deployer.getBalance()).toString())
  const network = (await ethers.provider.getNetwork()).name
  const TestPool = await ethers.getContractFactory("TestPool")
  const Testswap = await ethers.getContractFactory("Testswap")
  const VUSD = await ethers.getContractFactory('VUSD')
  let WETH
  switch (network) {
    // WETH address
    case 'mainnet':
      WETH = ''
      break
    default:
      throw new Error("unknown network");
  }
  const vusd = await VUSD.deploy()
  console.log("VUSD address:", vusd.address)
  const testPool = await TestPool.deploy(WETH)
  console.log("TestPool address:", testPool.address)
  const testswap = await upgrades.deployProxy(Testswap, [testPool.address, vusd.address])
  console.log("Testswap address:", testswap.address)
  await vusd.deployed()
  await testPool.deployed()
  await testswap.deployed()
  
  await vusd.transferOwnership(testswap.address)
  await testPool.transferOwnership(testswap.address)
  const devAddr = deployer.address
  await testswap.setFeeTo(devAddr)

}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });