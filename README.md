# Apollos Finance Smart Contracts 🚀

Apollos Finance is a next-generation, cross-chain leveraged yield protocol built on **Arbitrum Sepolia** and **Base Sepolia**. It enables users to access sophisticated 2x leverage strategies with built-in AI-driven risk management and LVR protection.

## 🏛 Architecture Overview

The protocol is divided into four functional layers:

### 1. Vault & Strategy Layer (`src/core`)
*   **`ApollosVault.sol`**: A hybrid ERC4626 vault that manages 2x leverage positions. It integrates with Aave V3 for credit delegation and uses an off-chain NAV (Net Asset Value) mechanism for accurate share pricing.
*   **`ApollosFactory.sol`**: The factory responsible for deploying and tracking authorized vault markets.
*   **`ApollosRouter.sol`**: The primary entry point for users to deposit or withdraw assets on the local chain.

### 2. Risk & Intelligence Layer
*   **`LVRHook.sol`**: A Uniswap V4-compatible hook that protects Liquidity Providers from **Loss-Versus-Rebalancing (LVR)** by dynamically adjusting swap fees based on market volatility detected by AI.
*   **`DataFeedsCache.sol`**: A high-performance on-chain cache that stores NAV and VaR (Value at Risk) data updated by Chainlink CRE workflows.
*   **`GenericWorkflowReceiver.sol`**: A secure gateway for Chainlink Keystone/CRE reports, allowing decentralized workflows to trigger protocol actions (like emergency pauses) safely.

### 3. Cross-Chain Interoperability Layer
*   **`ApollosCCIPReceiver.sol`**: Handles incoming messages from Chainlink CCIP. It supports "Store-and-Execute" patterns and "Auto-Zap" (bridging USDC and instantly swapping/depositing into a vault).
*   **`SourceChainRouter.sol`**: A lightweight router for source chains (like Base) to initiate cross-chain deposit requests.

### 4. Infrastructure Mocks (`src/mocks`)
*   Includes `MockAavePool.sol`, `MockUniswapPool.sol`, and `MockToken.sol` for robust local simulation and testnet deployment.

## 🛠 Development & Deployment

### Prerequisites
*   [Foundry](https://book.getfoundry.sh/getting-started/installation) installed.
*   Environment variables configured in `.env`.

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

## 📊 Data Feed Identifiers

The system uses specific `bytes32` IDs to track different data feeds in `DataFeedsCache`. Below are the common IDs (represented as Decimal for Frontend integration):

| Feed Name | Hex ID (bytes32) | Logic / Description |
|-----------|------------------|---------------------|
| **WETH NAV** | `keccak256("WETH_NAV")` | Net Asset Value per afWETH share |
| **WBTC NAV** | `keccak256("WBTC_NAV")` | Net Asset Value per afWBTC share |
| **WETH VaR** | `keccak256("APOLLOS_VAR_WETH")` | 95% Value at Risk for WETH Vault |
| **WBTC VaR** | `keccak256("APOLLOS_VAR_WBTC")` | 95% Value at Risk for WBTC Vault |

## 🔒 Security Model

1.  **Role-Based Access Control**: Sensitive functions (rebalance, pause, emergency) are restricted to authorized `Keepers` and `Rebalancers`.
2.  **Circuit Breakers**: The `Autonomous Auditor` workflow can instantly pause any vault if insolvency or anomalies are detected.
3.  **LVR Protection**: AI-driven dynamic fees discourage toxic arbitrage during high volatility.
4.  **Keystone Receiver**: All workflow reports are validated against a `trustedForwarder` and a strict `allowedSelector` whitelist.

## 💻 Technology Stack

- Solidity 0.8.20+
- Foundry
- Chainlink CCIP
- Chainlink CRE-compatible report receiver pattern
- Uniswap V4 hook-compatible architecture
- Aave-style credit delegation mock model

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---
*Built with 🔥 by Apollos Finance Team to make DeFi smarter, safer, and human-readable.*
