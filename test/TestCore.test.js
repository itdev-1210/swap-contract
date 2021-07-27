const { ethers, assert, upgrades } = require("hardhat");
const { expect } = require("chai");
const { expectRevert, time } = require('@openzeppelin/test-helpers');
const { deployContract, MockProvider, solidity } = require('ethereum-waffle');

const Web3 = require('web3');
const { BigNumber } = require("ethers");
const { utils } = Web3;

const e18 = 1 + '0'.repeat(18)
const e26 = 1 + '0'.repeat(26)
const e24 = 1 + '0'.repeat(24)

const bigNum = num=>(num + '0'.repeat(18))
const smallNum = num=>(parseInt(num)/bigNum(1))
const PoolStatus = {
    UNLISTED: 0,
    LISTED: 1,
    OFFICIAL: 2
}

const overrides = {
    gasLimit: 9500000
}
const DEFAULT_ETH_AMOUNT = 10000000000

describe('Test Core', function () {
});