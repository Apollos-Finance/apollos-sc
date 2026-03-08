# Apollos Finance Smart Contracts

Apollos Finance is a cross-chain leveraged yield system on Arbitrum Sepolia and Base Sepolia.

This repository contains the protocol contracts, mock infrastructure, deployment scripts, and test suite used by the frontend, backend workers, and CRE workflows.

## Key Components

### 1. Vault and Strategy Layer
- `ApollosVault.sol`: ERC4626 vault with leverage management and rebalance hooks.
- `ApollosFactory.sol`: Deploys and registers vault markets.
- `ApollosRouter.sol`: User-facing local deposit/withdraw entry point.

### 2. Market and Risk Layer
- `LVRHook.sol`: Dynamic fee hook for Uniswap V4-style swap protection.
- `DataFeedsCache.sol`: Onchain cache for NAV and VaR updates published by workflows.
- `GenericWorkflowReceiver.sol`: Generic receiver for CRE reports with target/selector allowlists.

### 3. Cross-Chain Layer
- `ApollosCCIPReceiver.sol`: Destination-chain receiver for bridge and zap flow.
- `SourceChainRouter.sol`: Source-chain bridge router.

### 4. Simulation Mocks
- `MockAavePool.sol`
- `MockUniswapPool.sol`
- `MockToken.sol`

## Contract Architecture (`src/core`)

- `ApollosVault.sol`
- `ApollosFactory.sol`
- `ApollosRouter.sol`
- `ApollosCCIPReceiver.sol`
- `SourceChainRouter.sol`
- `LVRHook.sol`
- `DataFeedsCache.sol`
- `GenericWorkflowReceiver.sol`

## Deployment

### 1. Deploy Arbitrum Hub
```bash
forge script script/DeployAll.s.sol:DeployAll --rpc-url <ARB_RPC> --private-key <PK> --broadcast
```

### 2. Deploy Base Source Router
```bash
forge script script/DeploySourceChain.s.sol:DeploySourceChain --rpc-url <BASE_RPC> --private-key <PK> --broadcast
```

### 3. Workflow Permission Setup (Generic Receiver)

`DeployAll.s.sol` configures vault/datafeed keepers and rebalancer permissions, but it does not fully configure GenericWorkflowReceiver routes.

After deploying `GenericWorkflowReceiver`, run owner-level permission setup for:
- Allowed targets (`setAllowedTarget`)
- Allowed selectors (`setAllowedRoute`)
- Target-side authorization (`setKeeper`, `setRebalancer`, `setWorkflowAuthorizer`)

This step is required for CRE writeReport execution through GenericWorkflowReceiver.

## Contract Addresses

### Arbitrum Sepolia (Testnet)

- WETH Token: [0x7a6B5c04778f8cF3f9546EbDA08b0901A5e619EB](https://sepolia.arbiscan.io/address/0x7a6B5c04778f8cF3f9546EbDA08b0901A5e619EB#code)
- WBTC Token: [0xB8057055bb7B1808A6AdB906ad4e0Be0A474E425](https://sepolia.arbiscan.io/address/0xB8057055bb7B1808A6AdB906ad4e0Be0A474E425#code)
- LINK Token: [0x6a7F28948F7da76949aF5fBB5fa1E25455649560](https://sepolia.arbiscan.io/address/0x6a7F28948F7da76949aF5fBB5fa1E25455649560#code)
- USDC Token: [0x09AbFa23367A563E98F03043856b762D826615B6](https://sepolia.arbiscan.io/address/0x09AbFa23367A563E98F03043856b762D826615B6#code)
- Factory: [0x8176D8C80bF350290aE841692CCfD5061D032ec2](https://sepolia.arbiscan.io/address/0x8176D8C80bF350290aE841692CCfD5061D032ec2#code)
- WETH Vault: [0xc34d9cC53D7311a32FdF78b199b2735819907B56](https://sepolia.arbiscan.io/address/0xc34d9cC53D7311a32FdF78b199b2735819907B56#code)
- Generic Workflow Receiver: [0x0ec786c976a35c6cc39984ace4c1046eb4ef0713](https://sepolia.arbiscan.io/address/0x0ec786c976a35c6cc39984ace4c1046eb4ef0713#code)
- WBTC Vault: [0xe8b3b780fdb42D9b2eF1E1C6e48853904935d257](https://sepolia.arbiscan.io/address/0xe8b3b780fdb42D9b2eF1E1C6e48853904935d257#code)
- LINK Vault: [0xabB9e2Fc9bdb430244dd6CdCB38c616d62Ddc502](https://sepolia.arbiscan.io/address/0xabB9e2Fc9bdb430244dd6CdCB38c616d62Ddc502#code)
- Router: [0x6FD18378cCC2D4C4C896bdd8cad642349cc3bb8F](https://sepolia.arbiscan.io/address/0x6FD18378cCC2D4C4C896bdd8cad642349cc3bb8F#code)
- CCIP Receiver: [0x4935b336eF4dF0E625DF1984c1E1f3540027BDbb](https://sepolia.arbiscan.io/address/0x4935b336eF4dF0E625DF1984c1E1f3540027BDbb#code)
- Uniswap Pool: [0xefebF7a77c3f5E183F71f284c8cB4B3c9755b672](https://sepolia.arbiscan.io/address/0xefebF7a77c3f5E183F71f284c8cB4B3c9755b672#code)
- Aave Pool: [0x2D97F2c57D45a7a2EbF252d16839Acb925148827](https://sepolia.arbiscan.io/address/0x2D97F2c57D45a7a2EbF252d16839Acb925148827#code)
- LVR Hook: [0x48D84A0E698631D2934277884Ede160795c32135](https://sepolia.arbiscan.io/address/0x48D84A0E698631D2934277884Ede160795c32135#code)
- Data Feeds Cache: [0x4D370021f2b5253f8085B64a6B882265B68A024e](https://sepolia.arbiscan.io/address/0x4D370021f2b5253f8085B64a6B882265B68A024e#code)

### Base Sepolia (Testnet)

- Source Router: [0xDbb5Dd90e4d1382B4fCB56EA41De9617d112B751](https://sepolia.basescan.org/address/0xDbb5Dd90e4d1382B4fCB56EA41De9617d112B751#code)

## Testing

```bash
forge test
forge test -vvv
```

## Technology Stack

- Solidity 0.8.20+
- Foundry
- Chainlink CCIP
- Chainlink CRE-compatible report receiver pattern
- Uniswap V4 hook-compatible architecture
- Aave-style credit delegation mock model

## License

MIT
