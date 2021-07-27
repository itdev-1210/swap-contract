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
  const Test = await ethers.getContractFactory("Test")

  const test = await upgrades.upgradeProxy(process.env.CORE_ADDRESS, Test)
  console.log("Test address:", test.address)
  await test.deployed()
  
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });