# Security Policy

Report suspected vulnerabilities privately to the repository maintainers. Do not publish working exploit details in a public issue before maintainers have had a reasonable opportunity to investigate.

## Secret handling

Never commit private keys, seed phrases, `.env` files, authenticated RPC URLs, API tokens, deployment keys, or other credentials. Use a dedicated execution wallet with limited funds and rotate any credential that is accidentally exposed.

## Transaction safety

State-changing scripts simulate calls before broadcasting, but simulation is not a security guarantee. Before execution, independently verify the chain, target contracts, route tokens, venue adapters, pool parameters, recipient, deadline, input amount, allowance, and minimum output.

## Smart-contract scope

The Solidity router and reconstructed venue adapters should be independently audited and tested against a mainnet fork before meaningful production funds are used. The configured ERC-721 collection is not executed through the fungible-token `swapModular` route.
