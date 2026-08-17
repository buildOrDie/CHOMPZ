import fs from 'node:fs';
import {
  createPublicClient, createWalletClient, encodeAbiParameters, getAddress, http, isAddress, zeroAddress
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { chain, contracts, NATIVE_ETH, rpcUrl } from '../lib/config.mjs';
import { chompzRouterAbi, erc20Abi } from '../lib/abis.mjs';

const key = process.env.PRIVATE_KEY?.trim();
const routePath = process.env.ROUTE_FILE?.trim() || './examples/route.example.json';
if (!key || !/^0x[0-9a-fA-F]{64}$/.test(key)) throw new Error('PRIVATE_KEY must be a 32-byte hex key');

const route = JSON.parse(fs.readFileSync(routePath, 'utf8'));
const account = privateKeyToAccount(key);
const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
const walletClient = createWalletClient({ account, chain, transport: http(rpcUrl) });

const asAddress = (value, label) => {
  if (!isAddress(value)) throw new Error(`Invalid ${label}: ${value}`);
  return getAddress(value);
};
const tokenIn = asAddress(route.tokenIn, 'tokenIn');
const tokenOut = asAddress(route.tokenOut, 'tokenOut');
const recipient = asAddress(route.recipient || account.address, 'recipient');
const amountIn = BigInt(route.amountInRaw);
const amountOutMin = BigInt(route.amountOutMinRaw);
if (amountIn <= 0n) throw new Error('amountInRaw must be greater than zero');
if (amountOutMin < 0n) throw new Error('amountOutMinRaw cannot be negative');

const venueAdapters = new Map();
for (const venueId of [...new Set(route.legs.map(x => Number(x.venueId)))]) {
  const adapter = await publicClient.readContract({
    address: contracts.router, abi: chompzRouterAbi, functionName: 'venueAdapter', args: [venueId]
  });
  if (adapter === zeroAddress) throw new Error(`Venue ${venueId} is not registered`);
  venueAdapters.set(venueId, getAddress(adapter));
}

function poolParams(leg) {
  const venueId = Number(leg.venueId);
  if (venueId === 2) return '0x';
  if (venueId === 3) {
    if (!Number.isInteger(Number(leg.fee))) throw new Error('V3 leg requires fee');
    return encodeAbiParameters([{ type: 'uint24' }], [Number(leg.fee)]);
  }
  if (venueId === 4) {
    const hooks = asAddress(leg.hooks || contracts.v4DefaultHooks, 'V4 hooks');
    return encodeAbiParameters(
      [{ type: 'uint24' }, { type: 'int24' }, { type: 'address' }],
      [Number(leg.fee), Number(leg.tickSpacing), hooks]
    );
  }
  if (!leg.poolParams || !/^0x[0-9a-fA-F]*$/.test(leg.poolParams)) {
    throw new Error(`Venue ${venueId} requires explicit hex poolParams`);
  }
  return leg.poolParams;
}

const legs = route.legs.map((leg, index) => {
  const venueId = Number(leg.venueId);
  const expectedAdapter = venueAdapters.get(venueId);
  if (leg.expectedAdapter && getAddress(leg.expectedAdapter) !== expectedAdapter) {
    throw new Error(`Leg ${index}: expectedAdapter does not match the live registered adapter`);
  }
  return {
    venueId,
    expectedAdapter,
    tokenIn: asAddress(leg.tokenIn, `legs[${index}].tokenIn`),
    tokenOut: asAddress(leg.tokenOut, `legs[${index}].tokenOut`),
    poolParams: poolParams(leg)
  };
});

const resolvedInput = tokenIn === NATIVE_ETH ? contracts.weth : tokenIn;
const resolvedOutput = tokenOut === NATIVE_ETH ? contracts.weth : tokenOut;
if (legs.length === 0) throw new Error('Route must contain at least one leg');
if (legs[0].tokenIn !== resolvedInput) throw new Error('First leg tokenIn does not match resolved route tokenIn');
if (legs.at(-1).tokenOut !== resolvedOutput) throw new Error('Last leg tokenOut does not match resolved route tokenOut');
for (let i = 0; i < legs.length - 1; i += 1) {
  if (legs[i].tokenOut !== legs[i + 1].tokenIn) throw new Error(`Route breaks between legs ${i} and ${i + 1}`);
}

const deadline = BigInt(Math.floor(Date.now() / 1000) + Number(route.deadlineSeconds ?? 180));
const value = tokenIn === NATIVE_ETH ? amountIn : 0n;

if (tokenIn !== NATIVE_ETH) {
  const allowance = await publicClient.readContract({
    address: tokenIn, abi: erc20Abi, functionName: 'allowance', args: [account.address, contracts.router]
  });
  if (allowance < amountIn) throw new Error(`Insufficient router allowance: ${allowance} < ${amountIn}. Run npm run approve first.`);
}

const { request, result } = await publicClient.simulateContract({
  account,
  address: contracts.router,
  abi: chompzRouterAbi,
  functionName: 'swapModular',
  args: [legs, tokenIn, tokenOut, amountIn, amountOutMin, recipient, deadline],
  value
});
console.log(`simulation amountOut: ${result}`);
const hash = await walletClient.writeContract(request);
console.log(`tx: ${hash}`);
