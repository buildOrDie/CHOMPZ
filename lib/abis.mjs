import { parseAbi } from 'viem';

export const erc20Abi = parseAbi([
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
  'function balanceOf(address owner) view returns (uint256)',
  'function allowance(address owner,address spender) view returns (uint256)',
  'function approve(address spender,uint256 amount) returns (bool)'
]);

export const erc721Abi = parseAbi([
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function ownerOf(uint256 tokenId) view returns (address)',
  'function tokenURI(uint256 tokenId) view returns (string)',
  'function isApprovedForAll(address owner,address operator) view returns (bool)',
  'function getApproved(uint256 tokenId) view returns (address)'
]);

export const chompzRouterAbi = parseAbi([
  'function WETH() view returns (address)',
  'function feeBps() view returns (uint256)',
  'function paused() view returns (bool)',
  'function venueAdapter(uint8 venueId) view returns (address)',
  'struct Leg { uint8 venueId; address expectedAdapter; address tokenIn; address tokenOut; bytes poolParams; }',
  'function swapModular(Leg[] legs,address tokenIn,address tokenOut,uint256 amountIn,uint256 amountOutMin,address to,uint256 deadline) payable returns (uint256 amountOut)'
]);
