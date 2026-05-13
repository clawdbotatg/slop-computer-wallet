# slop-computer-wallet

> A simple M-of-N multisig with EOA + passkey signers, deployed via factory/proxy. ERC-1271 ready.

Built with Scaffold-ETH 2 + Foundry.

## Quick links

- **Integration guide**: [`INTEGRATION.md`](INTEGRATION.md) — call patterns, signature format, viem snippets, ERC-1271, error reference. Read this first if you're wiring a frontend or service to the factory.
- **ABIs**: [`abi/Multisig.json`](abi/Multisig.json) · [`abi/MultisigFactory.json`](abi/MultisigFactory.json)
- **Live `MultisigFactory`**: [`0x21f03d2AdaEAaFe75e0C721bD1eBbC4C9aF9602E`](https://etherscan.io/address/0x21f03d2AdaEAaFe75e0C721bD1eBbC4C9aF9602E#code) — same address on every supported chain
- **Live `Multisig` implementation**: [`0x346Db4e22dDF585c8f97496820c2106aE277df1e`](https://etherscan.io/address/0x346Db4e22dDF585c8f97496820c2106aE277df1e#code)
- Chains: Ethereum mainnet (1), Base (8453) — see [§Deployed contracts](#deployed-contracts) for explorer links.

## What's here

- `packages/foundry/contracts/Multisig.sol` — the multisig. Mix EOA and passkey (WebAuthn / secp256r1) signers, configurable threshold, self-governed admin (add/remove signer + change threshold via `execTransaction`), ERC-1271 `isValidSignature`, transient-storage reentrancy guard.
- `packages/foundry/contracts/MultisigFactory.sol` — EIP-1167 minimal-proxy factory. CREATE2 salt is `keccak256(msg.sender, salt)` so different deployers can't collide on the same predicted address.
- `packages/foundry/test/Multisig.t.sol` — 25 tests covering init, exec, batch, threshold rules, replay, expiry, admin paths, ERC-1271, reentrancy, factory invariants. All audit-driven additions are prefixed with their finding ID (e.g. `test_M1_*`, `test_L2_*`).
- `packages/foundry/script/DeployDeterministic.s.sol` — production cross-chain deploy via the Arachnid CREATE2 singleton. Gives identical contract addresses on every EVM chain it runs against.
- `packages/foundry/script/DeployFactory.s.sol` — simple `new`-based deploy used for local anvil iteration.
- `packages/nextjs/app/page.tsx` — factory UI: pick signers + threshold + salt, predict the address, deploy.
- `packages/nextjs/app/[address]/page.tsx` — multisig UI: view state, propose a tx, collect signatures from connected wallet(s), execute. Quick-admin form fills the calldata for `addEoaSigner` / `removeSigner` / `changeThreshold`.

## Signature format

`execTransaction` takes an array of `Signature` structs (`sigType`, `signer`, `data`), **sorted ascending by `signer`** — duplicates and unsorted arrays revert.

- **EOA**: `data` = a 65-byte ECDSA signature over `getExecHash(...)` produced via `personal_sign`. The contract applies the `\x19Ethereum Signed Message:\n32` prefix before `ecrecover`, so any wallet's `signMessage` works.
- **Passkey**: `data` = `abi.encode(qx, qy, WebAuthn.WebAuthnAuth)`. The contract verifies via OZ `WebAuthn.verify` against the raw exec hash as the challenge.

`isValidSignature` (ERC-1271) recovers the hash **as-passed** (no `personal_sign` prefix), so callers like Permit2 / Seaport that present an EIP-712 digest validate correctly.

## Local quickstart

```bash
yarn install
yarn chain          # terminal 1: anvil at :8545
yarn deploy         # terminal 2: deploys via DeployFactory.s.sol
yarn start          # terminal 3: dev server at :3001
```

For local deploys the Anvil prefunded account #9 is used via the `scaffold-eth-default` keystore (password `localhost`).

## Deployed contracts

Both contracts deploy via the [Arachnid CREATE2 singleton](https://github.com/Arachnid/deterministic-deployment-proxy) at `0x4e59b44847b379578588920cA78FbF26c0B4956C`, which is preinstalled on every major EVM chain. Same salts + same compiler settings → identical addresses on every chain.

### Live deployments

| Chain | Multisig (implementation) | MultisigFactory |
|---|---|---|
| Ethereum mainnet (1) | [`0x346Db4e22dDF585c8f97496820c2106aE277df1e`](https://etherscan.io/address/0x346Db4e22dDF585c8f97496820c2106aE277df1e#code) | [`0x21f03d2AdaEAaFe75e0C721bD1eBbC4C9aF9602E`](https://etherscan.io/address/0x21f03d2AdaEAaFe75e0C721bD1eBbC4C9aF9602E#code) |
| Base (8453) | [`0x346Db4e22dDF585c8f97496820c2106aE277df1e`](https://basescan.org/address/0x346Db4e22dDF585c8f97496820c2106aE277df1e#code) | [`0x21f03d2AdaEAaFe75e0C721bD1eBbC4C9aF9602E`](https://basescan.org/address/0x21f03d2AdaEAaFe75e0C721bD1eBbC4C9aF9602E#code) |

Both contracts are verified on the respective explorer (click the addresses to read the source). On every chain, `Factory.implementation()` returns the impl address above.

### Artifacts in this repo

| Path | What |
|---|---|
| `packages/foundry/deployments/1.json` | Mainnet address map (used by the frontend) |
| `packages/foundry/deployments/8453.json` | Base address map (used by the frontend) |
| `packages/foundry/broadcast/DeployDeterministic.s.sol/1/run-latest.json` | Mainnet tx receipts |
| `packages/foundry/broadcast/DeployDeterministic.s.sol/8453/run-latest.json` | Base tx receipts |
| `packages/foundry/script/DeployDeterministic.s.sol` | The script that produced all of the above |

### Salts used

```
IMPL_SALT    = keccak256("slop-multisig-impl-v1")
FACTORY_SALT = keccak256("slop-multisig-factory-v1")
```

Bump these (e.g. to `-v2`) if `Multisig.sol` or `MultisigFactory.sol` ever change — otherwise the post-deploy `code.length` check will fail because the new bytecode hashes to a different address.

## Deploying to a new chain

The same `DeployDeterministic.s.sol` script handles every chain. Because it goes through the Arachnid singleton, you'll get the same `0x346D...df1e` and `0x21f0...602E` addresses as the live deployments above, provided you don't change `Multisig.sol`/`MultisigFactory.sol` or compiler settings.

### One-time setup

1. **Add your Alchemy key.** Edit `packages/foundry/.env` and replace `ALCHEMY_API_KEY=...` with your own key from [dashboard.alchemy.com](https://dashboard.alchemy.com). One Alchemy app covers all networks. The committed `.env.example` is a template; the real `.env` is gitignored.
2. **(Optional) Use your own Etherscan key** for `--verify` instead of the shared scaffold-eth default. Replace `ETHERSCAN_API_KEY=...` in the same `.env`. A single Etherscan V2 key works on mainnet, Base, Arbitrum, Optimism, Polygon.
3. **Create a deployer keystore.** This repo expects a Foundry keystore named `slop-deployer` with its password in a sibling file. Generate one:

   ```bash
   cast wallet new ~/.foundry/keystores
   # then rename it
   mv ~/.foundry/keystores/<uuid-the-command-printed> ~/.foundry/keystores/slop-deployer
   # and save the password you typed into:
   echo -n "<your password>" > ~/.foundry/keystores/slop-deployer.password.txt
   chmod 600 ~/.foundry/keystores/slop-deployer.password.txt
   ```

   Verify:

   ```bash
   cast wallet address --account slop-deployer \
     --password-file ~/.foundry/keystores/slop-deployer.password.txt
   ```

   Both files live in `~/.foundry/keystores/` — outside the repo, never committed.

### Per-chain deploy

1. **Fund the deployer EOA** on the target chain. Total cost for both contracts is ~3.95M gas, so:

   - Mainnet at 0.5–3 gwei → 0.002–0.012 ETH. Fund 0.005–0.01 ETH and you're comfortable.
   - L2s (Base, Arbitrum, Optimism) → fractions of a cent. Send ~0.001 ETH and forget about it.

2. **Run the script:**

   ```bash
   forge script packages/foundry/script/DeployDeterministic.s.sol \
     --rpc-url <network> \
     --account slop-deployer \
     --password-file ~/.foundry/keystores/slop-deployer.password.txt \
     --broadcast --ffi --verify
   ```

   `<network>` is any key from `[rpc_endpoints]` in `packages/foundry/foundry.toml` — `mainnet`, `base`, `arbitrum`, `optimism`, `sepolia`, `baseSepolia`, etc.

3. **Idempotent**: if the contracts already exist on that chain, the script is a no-op that just prints the addresses. Safe to re-run after a partial failure.

4. **Verification** happens inline thanks to `--verify`. The Etherscan V2 endpoints in `foundry.toml` route to the right explorer per chain id. If verify times out, re-run manually:

   ```bash
   forge verify-contract 0x346Db4e22dDF585c8f97496820c2106aE277df1e Multisig --chain <chainId>
   forge verify-contract 0x21f03d2AdaEAaFe75e0C721bD1eBbC4C9aF9602E MultisigFactory \
     --chain <chainId> \
     --constructor-args $(cast abi-encode "constructor(address)" 0x346Db4e22dDF585c8f97496820c2106aE277df1e)
   ```

5. **Frontend pickup**: a fresh `packages/foundry/deployments/<chainId>.json` is written automatically, and the broadcast receipts land under `packages/foundry/broadcast/DeployDeterministic.s.sol/<chainId>/`. Commit those so the frontend can find the factory.

### Re-deploying (e.g. after a contract change)

Bump the salts in `DeployDeterministic.s.sol`:

```solidity
bytes32 constant IMPL_SALT    = keccak256("slop-multisig-impl-v2");
bytes32 constant FACTORY_SALT = keccak256("slop-multisig-factory-v2");
```

Then re-run the deploy command. The new addresses will again be identical across chains, and the v1 deployment stays in place untouched.

### Skipped chains

zkSync Era and other zkEVMs don't use canonical EVM bytecode; the Arachnid singleton may not exist there, and even if you redeployed it, the same source would compile to different bytecode and addresses. Skip them or deploy separately with chain-specific tooling.

## Contracts at a glance

```
MultisigFactory.createMultisig(eoaSigners, qxs, qys, credentialIds, threshold, salt)
   ↓ CREATE2 (effectiveSalt = keccak256(msg.sender, salt))
Multisig (EIP-1167 clone)
   ├── execTransaction(target, value, data, deadline, signatures[])      ← nonReentrant
   ├── execBatchTransaction(calls[], deadline, signatures[])             ← nonReentrant
   ├── isValidSignature(hash, abi.encode(signatures[]))   → ERC-1271 magic value
   ├── addEoaSigner(addr)       ┐
   ├── addPasskeySigner(qx,qy,credId)   ├ onlySelf — only callable via execTransaction
   ├── removeSigner(addr)       │      reaching threshold
   └── changeThreshold(uint256) ┘
```

Known unaddressed brittleness: M-of-M setups and 1-of-1 setups are allowed. Lose a key and the multisig is stuck. This is an opt-in tradeoff — guard against it in the UI, not the contract.

## Contributing

See [CONTRIBUTING.MD](https://github.com/scaffold-eth/scaffold-eth-2/blob/main/CONTRIBUTING.md).
