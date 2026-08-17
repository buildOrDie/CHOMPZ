import { createPublicClient, getAddress, http } from 'viem';
import { chain, contracts, rpcUrl } from '../lib/config.mjs';
import { chompzRouterAbi, erc721Abi } from '../lib/abis.mjs';

const client = createPublicClient({ chain, transport: http(rpcUrl) });
const chainId = await client.getChainId();
if (chainId !== chain.id) throw new Error(`RPC chain mismatch: expected ${chain.id}, received ${chainId}`);

const [routerCode, nftCode] = await Promise.all([
  client.getCode({ address: contracts.router }),
  client.getCode({ address: contracts.nft })
]);
if (!routerCode || routerCode === '0x') throw new Error('CHOMPZ router has no deployed bytecode');
if (!nftCode || nftCode === '0x') throw new Error('CHOMPZ NFT contract has no deployed bytecode');

const [weth, feeBps, paused, v2, v3, v4, nftName, nftSymbol] = await Promise.all([
  client.readContract({ address: contracts.router, abi: chompzRouterAbi, functionName: 'WETH' }),
  client.readContract({ address: contracts.router, abi: chompzRouterAbi, functionName: 'feeBps' }),
  client.readContract({ address: contracts.router, abi: chompzRouterAbi, functionName: 'paused' }),
  client.readContract({ address: contracts.router, abi: chompzRouterAbi, functionName: 'venueAdapter', args: [2] }),
  client.readContract({ address: contracts.router, abi: chompzRouterAbi, functionName: 'venueAdapter', args: [3] }),
  client.readContract({ address: contracts.router, abi: chompzRouterAbi, functionName: 'venueAdapter', args: [4] }),
  client.readContract({ address: contracts.nft, abi: erc721Abi, functionName: 'name' }).catch(() => 'unknown'),
  client.readContract({ address: contracts.nft, abi: erc721Abi, functionName: 'symbol' }).catch(() => 'unknown')
]);

console.log(JSON.stringify({
  network: { name: chain.name, chainId },
  router: {
    address: contracts.router,
    paused,
    feeBps: feeBps.toString(),
    weth: getAddress(weth),
    adapters: { v2: getAddress(v2), v3: getAddress(v3), v4: getAddress(v4) }
  },
  nft: { address: contracts.nft, name: nftName, symbol: nftSymbol }
}, null, 2));
