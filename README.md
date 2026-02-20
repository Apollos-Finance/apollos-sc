# Apollos Finance Smart Contracts 🚀

Apollos Finance is a next-generation, cross-chain leveraged yield protocol built on **Arbitrum Sepolia** and **Base Sepolia**. It enables users to access sophisticated 2x leverage strategies with a single click, regardless of their source chain, while providing advanced protection against Loss-Versus-Rebalancing (LVR) using Uniswap V4 Hooks.

## 🌟 Key Innovations

### 1. Store-and-Execute CCIP Pattern
To bypass the strict gas limits of cross-chain message delivery, Apollos utilizes a **Store-and-Execute** architecture. Incoming bridge intents are securely stored on the destination chain, allowing users to execute heavy DeFi logic (swapping and vault depositing) in a secondary, local transaction. This ensures 100% reliability for complex multi-step strategies.

### 2. Hybrid ERC4626 Vaults
Our vaults implement a **Dual-Valuation System**:
- **Production Path:** High-efficiency Net Asset Value (NAV) updates calculated off-chain via **Chainlink Workflows** and cached on-chain.
- **Fallback Path:** Real-time on-chain math valuation that automatically kicks in if the off-chain feed becomes stale, ensuring the vault is always solvable.

### 3. LVR Protection via Uniswap V4 Hooks
The protocol employs a custom **LVRHook** that injects dynamic swap fees into Uniswap V4 pools. By analyzing market volatility off-chain using Gemini AI and committing risk scores via Chainlink, the protocol protects liquidity providers from toxic flow during high-volatility events.

---

## 🏗️ Technical Architecture

### Core Contracts (`src/core/`)
- **`ApollosVault.sol`**: The heart of the protocol. An ERC4626 compliant vault that manages Aave credit delegation and Uniswap V4 LP positions.
- **`ApollosCCIPReceiver.sol`**: Manages cross-chain message reception and the Auto-Zap "Reserve Swap" mechanism.
- **`ApollosRouter.sol`**: The unified entry point for local deposits, withdrawals, and native ETH wrapping.
- **`LVRHook.sol`**: A Uniswap V4 hook providing dynamic fee adjustments and vault whitelisting.
- **`ApollosFactory.sol`**: The permissioned registry and deployment engine for new strategy vaults.
- **`SourceChainRouter.sol`**: A lightweight bridge-only gateway deployed on source chains like Base.

### Simulation Infrastructure (`src/mocks/`)
- **`MockAavePool.sol`**: Simulates Aave V3 lending with full Credit Delegation support.
- **`MockUniswapPool.sol`**: A hybrid Uniswap V4 simulation that uses official V4 types while providing a simplified AMM for strategy testing.
- **`MockToken.sol`**: Feature-rich mock tokens with built-in faucets and WETH-style wrapping.

---

## 🚀 Getting Started

### Installation
```bash
# Clone the repository
git clone https://github.com/your-username/ApollosFinance.git
cd apollos-sc

# Install dependencies
forge install
```

### Testing
Apollos features a comprehensive test suite covering strategy logic, cross-chain state transitions, and edge-case reverts.
```bash
# Run all tests
forge test

# Run tests with detailed logs
forge test -vvv
```

### Deployment
Deployment is split into two phases: the Main Hub (Arbitrum) and the Source Gateways (Base).

**1. Deploy to Arbitrum Sepolia (Hub):**
```bash
forge script script/DeployAll.s.sol:DeployAll --rpc-url <ARB_RPC> --private-key <PK> --broadcast
```

**2. Deploy to Base Sepolia (Gateway):**
```bash
forge script script/DeploySourceChain.s.sol:DeploySourceChain --rpc-url <BASE_RPC> --private-key <PK> --broadcast
```

---

## 🛠️ Technology Stack
- **Smart Contracts:** Solidity 0.8.20+
- **Framework:** Foundry
- **Interoperability:** Chainlink CCIP
- **Computation:** Chainlink Workflows (off-chain NAV/LVR)
- **AMM:** Uniswap V4 (Hooks)
- **Lending:** Aave V3 (Credit Delegation)

## 📄 License
This project is licensed under the MIT License.

---
*Built with 🔥 to make DeFi smarter, safer, and human-readable.*
