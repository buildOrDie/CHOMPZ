import { createPublicClient, http } from 'viem';
import { chain, contracts, rpcUrl } from '../lib/config.mjs';
import { erc721Abi } from '../lib/abis.mjs';

const client = createPublicClient({ chain, transport: http(rpcUrl) });
const [name, symbol, code] = await Promise.all([
  client.readContract({ address: contracts.nft, abi: erc721Abi, functionName: 'name' }).catch(() => 'unknown'),
  client.readContract({ address: contracts.nft, abi: erc721Abi, functionName: 'symbol' }).catch(() => 'unknown'),
  client.getCode({ address: contracts.nft })
]);
if (!code || code === '0x') throw new Error('Configured NFT contract has no deployed bytecode');

const output = { address: contracts.nft, name, symbol };
if (process.env.TOKEN_ID?.trim()) {
  const tokenId = BigInt(process.env.TOKEN_ID.trim());
  output.tokenId = tokenId.toString();
  output.owner = await client.readContract({ address: contracts.nft, abi: erc721Abi, functionName: 'ownerOf', args: [tokenId] });
  output.tokenURI = await client.readContract({ address: contracts.nft, abi: erc721Abi, functionName: 'tokenURI', args: [tokenId] }).catch(() => null);
}
console.log(JSON.stringify(output, null, 2));
