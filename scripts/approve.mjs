import { createPublicClient, createWalletClient, getAddress, http, isAddress, parseUnits } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { chain, contracts, rpcUrl } from '../lib/config.mjs';
import { erc20Abi } from '../lib/abis.mjs';

const key = process.env.PRIVATE_KEY?.trim();
const token = process.env.TOKEN?.trim();
const amount = process.env.AMOUNT?.trim();
if (!key || !/^0x[0-9a-fA-F]{64}$/.test(key)) throw new Error('PRIVATE_KEY must be a 32-byte hex key');
if (!token || !isAddress(token)) throw new Error('TOKEN must be a valid ERC-20 address');
if (!amount || Number(amount) <= 0) throw new Error('AMOUNT must be a positive human-readable token amount');

const account = privateKeyToAccount(key);
const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
const walletClient = createWalletClient({ account, chain, transport: http(rpcUrl) });
const tokenAddress = getAddress(token);
const [decimals, symbol] = await Promise.all([
  publicClient.readContract({ address: tokenAddress, abi: erc20Abi, functionName: 'decimals' }),
  publicClient.readContract({ address: tokenAddress, abi: erc20Abi, functionName: 'symbol' }).catch(() => 'TOKEN')
]);
const value = parseUnits(amount, decimals);

const { request } = await publicClient.simulateContract({
  account,
  address: tokenAddress,
  abi: erc20Abi,
  functionName: 'approve',
  args: [contracts.router, value]
});
const hash = await walletClient.writeContract(request);
console.log(`Approved ${amount} ${symbol} for CHOMPZ router`);
console.log(`tx: ${hash}`);
