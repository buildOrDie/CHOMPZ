import 'dotenv/config';
import fs from 'node:fs';
import { defineChain, getAddress, isAddress } from 'viem';

const raw = JSON.parse(fs.readFileSync(new URL('../config/contracts.json', import.meta.url), 'utf8'));

function address(value, label) {
  if (!isAddress(value)) throw new Error(`Invalid ${label}: ${value}`);
  return getAddress(value);
}

export const contracts = {
  router: address(raw.contracts.router, 'router'),
  nft: address(raw.contracts.nft, 'NFT'),
  weth: address(raw.contracts.weth, 'WETH'),
  v2Router: address(raw.contracts.v2Router, 'V2 router'),
  v3Router: address(raw.contracts.v3Router, 'V3 router'),
  v3Quoter: address(raw.contracts.v3Quoter, 'V3 quoter'),
  v4Quoter: address(raw.contracts.v4Quoter, 'V4 quoter'),
  v4DefaultHooks: address(raw.contracts.v4DefaultHooks, 'V4 hooks')
};

export const rpcUrl = process.env.RPC_URL?.trim() || raw.network.rpcUrl;
export const chain = defineChain({
  id: raw.network.chainId,
  name: raw.network.name,
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [rpcUrl] } },
  blockExplorers: { default: { name: 'Blockscout', url: raw.network.explorer } }
});

export const NATIVE_ETH = '0x0000000000000000000000000000000000000000';
