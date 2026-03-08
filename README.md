# Apollos Finance Smart Contracts

Apollos Finance is a next-generation, cross-chain leveraged yield protocol built on **Arbitrum Sepolia** and **Base Sepolia**. It enables users to access sophisticated 2x leverage strategies with built-in AI-driven risk management and LVR protection.

## Architecture Overview

The protocol is divided into four functional layers:

### 1. Vault & Strategy Layer (`src/core`)
- **`ApollosVault.sol`**: A hybrid ERC4626 vault that manages 2x leverage positions. It integrates with Aave V3 for credit delegation and uses an off-chain NAV (Net Asset Value) mechanism for accurate share pricing.
- **`ApollosFactory.sol`**: The factory responsible for deploying and tracking authorized vault markets.
- **`ApollosRouter.sol`**: The primary entry point for users to deposit or withdraw assets on the local chain.

### 2. Risk & Intelligence Layer
- **`LVRHook.sol`**: A Uniswap V4-compatible hook that protects Liquidity Providers from **Loss-Versus-Rebalancing (LVR)** by dynamically adjusting swap fees based on market volatility detected by AI.
- **`DataFeedsCache.sol`**: A high-performance on-chain cache that stores NAV and VaR (Value at Risk) data updated by Chainlink CRE workflows.
- **`GenericWorkflowReceiver.sol`**: A secure gateway for Chainlink Keystone/CRE reports, allowing decentralized workflows to trigger protocol actions (like emergency pauses) safely.

### 3. Cross-Chain Interoperability Layer
- **`ApollosCCIPReceiver.sol`**: Handles incoming messages from Chainlink CCIP. It supports "Store-and-Execute" patterns and "Auto-Zap" (bridging USDC and instantly swapping/depositing into a vault).
- **`SourceChainRouter.sol`**: A lightweight router for source chains (like Base) to initiate cross-chain deposit requests.

### 4. Infrastructure Mocks (`src/mocks`)
- Includes `MockAavePool.sol`, `MockUniswapPool.sol`, and `MockToken.sol` for robust local simulation and testnet deployment.

## Development and Deployment

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed.
- Environment variables configured in `.env`.

### Local Testing
Run the comprehensive test suite:
```bash
forge test
# For detailed trace
forge test -vvv
```

### Deployment Commands

#### 1. Deploy Full System (Arbitrum Sepolia)
```bash
forge script script/DeployAll.s.sol:DeployAll --rpc-url $ARB_RPC --private-key $PRIVATE_KEY --broadcast --verify
```

#### 2. Deploy Source Router (Base Sepolia)
```bash
forge script script/DeploySourceChain.s.sol:DeploySourceChain --rpc-url $BASE_RPC --private-key $PRIVATE_KEY --broadcast --verify
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

## Data Feed Identifiers

The system uses specific `bytes32` IDs to track different data feeds in `DataFeedsCache`. Below are the common IDs (represented as Decimal for frontend integration):

| Feed Name | Hex ID (bytes32) | Logic / Description |
|-----------|------------------|---------------------|
| **WETH NAV** | `keccak256("WETH_NAV")` | Net Asset Value per afWETH share |
| **WBTC NAV** | `keccak256("WBTC_NAV")` | Net Asset Value per afWBTC share |
| **WETH VaR** | `keccak256("APOLLOS_VAR_WETH")` | 95% Value at Risk for WETH Vault |
| **WBTC VaR** | `keccak256("APOLLOS_VAR_WBTC")` | 95% Value at Risk for WBTC Vault |

## Security Model

1. **Role-Based Access Control**: Sensitive functions (rebalance, pause, emergency) are restricted to authorized `keepers` and `rebalancers`.
2. **Circuit Breakers**: The Autonomous Auditor workflow can pause a vault when insolvency or anomalies are detected.
3. **LVR Protection**: AI-driven dynamic fees discourage toxic arbitrage during high volatility.
4. **Keystone Receiver**: All workflow reports are validated against a `trustedForwarder` and a strict `allowedSelector` whitelist.

## Technology Stack

- Solidity 0.8.20+
- Foundry
- Chainlink CCIP
- Chainlink CRE-compatible report receiver pattern
- Uniswap V4 hook-compatible architecture
- Aave-style credit delegation mock model

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).

---
Built by the Apollos Finance Team to make DeFi smarter, safer, and human-readable.
