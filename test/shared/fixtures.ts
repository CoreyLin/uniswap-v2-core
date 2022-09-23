import { Contract, Wallet } from 'ethers'
import { Web3Provider } from 'ethers/providers'
import { deployContract } from 'ethereum-waffle'

import { expandTo18Decimals } from './utilities'

import ERC20 from '../../build/ERC20.json'
import UniswapV2Factory from '../../build/UniswapV2Factory.json'
import UniswapV2Pair from '../../build/UniswapV2Pair.json'

interface FactoryFixture {
  factory: Contract
}

const overrides = {
  gasLimit: 9999999 // 定义一次，用在每笔交易中
}

export async function factoryFixture(_: Web3Provider, [wallet]: Wallet[]): Promise<FactoryFixture> {
  const factory = await deployContract(wallet, UniswapV2Factory, [wallet.address], overrides) // 部署factory合约
  return { factory }
}

interface PairFixture extends FactoryFixture { // 继承
  token0: Contract
  token1: Contract
  pair: Contract
}

export async function pairFixture(provider: Web3Provider, [wallet]: Wallet[]): Promise<PairFixture> {
  const { factory } = await factoryFixture(provider, [wallet]) // 部署factory合约

  // 部署两个ERC20合约
  const tokenA = await deployContract(wallet, ERC20, [expandTo18Decimals(10000)], overrides)
  const tokenB = await deployContract(wallet, ERC20, [expandTo18Decimals(10000)], overrides)

  await factory.createPair(tokenA.address, tokenB.address, overrides) // 创建pair合约
  const pairAddress = await factory.getPair(tokenA.address, tokenB.address) // 获取pair合约的地址
  const pair = new Contract(pairAddress, JSON.stringify(UniswapV2Pair.abi), provider).connect(wallet) // 通过pair合约和pair abi创建pair对象

  const token0Address = (await pair.token0()).address // 获取token0地址
  const token0 = tokenA.address === token0Address ? tokenA : tokenB // 计算token0合约
  const token1 = tokenA.address === token0Address ? tokenB : tokenA // 计算token1合约

  return { factory, token0, token1, pair }
}
