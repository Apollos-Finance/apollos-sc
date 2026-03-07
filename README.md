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
