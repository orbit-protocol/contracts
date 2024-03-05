# Orbit Protocol Smart Contracts

Welcome to the Orbit Protocol, a revolutionary DeFi lending platform built on the Blast network. Orbit Protocol introduces a non-custodial, open-source framework that facilitates the creation of money markets. Our users can effortlessly earn interest on deposits and borrow assets through a secure, user-friendly interface.

## Introduction

Orbit is optimized for the Blast ecosystem, aiming to provide the best liquidity market for yield-earning assets. Through the Orbit Protocol, users interact with the SpaceStation, the central controller for all lending markets, to engage in lending and borrowing activities using OTokens.

### SpaceStation

The SpaceStation is the heart of the Orbit lending ecosystem, managing the interactions between various lending markets. It ensures seamless operation, security, and efficiency across the protocol.

### OTokens

OTokens represent a pivotal element in the Orbit ecosystem, linked directly to underlying assets such as USDB or ETH. Users can mint OTokens (e.g., oUSDB) by depositing their underlying assets, enabling them to participate in the lending market.

## Usage

Before interacting with the contracts, ensure you have a Blast-compatible wallet and sufficient ETH for gas fees.

### Compiling Contracts

Compile the smart contracts using Hardhat:
```npx hardhat compile```

## Smart Contract Architecture

- **SpaceStation**: Main controller for the Orbit lending markets. Handles the creation of OTokens and manages the overall protocol parameters.
- **OTokens**: ERC20 tokens representing a user's share in a lending pool. Minted upon deposit of the underlying asset and burned upon withdrawal.

### Blast Capabilities

The Orbit Protocol is designed with a "set to claimable" yield mechanism, where the accrued yield on the platform's assets, including ETH and USDB, can be claimed by the designated governor of the smart contract. This feature allows for efficient management and reallocation of generated yield to support the ecosystem's sustainability and growth.

## Security

Orbit prioritizes security with robust smart contract designs, including:
- Reliable oracle pricing
- Safe collateral limits
- Secure liquidation models

## Contributing

We welcome contributions from the community. Please refer to the CONTRIBUTING.md file for more details on how to submit pull requests, report issues, or suggest enhancements.

## License

This project is licensed under the MIT License

## Socials

- Twitter: [https://twitter.com/orbitprotocol](https://twitter.com/orbitlending)
- Discord: [https://discord.gg/orbitprotocol](https://discord.gg/4MFstFJcap)

Join our community to stay updated on the latest developments and participate in shaping the future of DeFi on the Blast network.

Hope to contribute there.
