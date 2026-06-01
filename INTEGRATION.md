# Integration guide

Everything a frontend / backend / bot needs to talk to the live `MultisigFactory` and `Multisig` contracts. All examples use [viem](https://viem.sh) but the same calls work in ethers or any other lib.

---

## 1. Live addresses & ABIs

| | Address | ABI |
|---|---|---|
| `Multisig` (implementation) | [`0x5Be7f750Cc271DBf0C6027a45bFe78b99504CE3A`](https://etherscan.io/address/0x5Be7f750Cc271DBf0C6027a45bFe78b99504CE3A#code) | [`abi/Multisig.json`](abi/Multisig.json) |
| `MultisigFactory` | [`0xfcdEe21865b60C2700C23Cd946316CEdA0F215B5`](https://etherscan.io/address/0xfcdEe21865b60C2700C23Cd946316CEdA0F215B5#code) | [`abi/MultisigFactory.json`](abi/MultisigFactory.json) |

These are the **v4** addresses (the `-v4` deploy salt). v4 collapses EOA and ERC-1271 contract signers into a single **Account** signer kind, validated polymorphically (ECDSA, accepting raw or personal_sign, then ERC-1271 fallback — the OpenZeppelin `SignatureChecker` pattern). So a plain EOA, an EIP-7702 smart account (e.g. MetaMask), a Gnosis Safe, or another `Multisig` can all be signers, and the contract never needs to know which at registration. **Passkey** stays its own kind. Same addresses on every chain we deploy to (as long as the source doesn't change). See [`README.md`](README.md#deploying-to-a-new-chain) for the deploy walkthrough.

> The earlier v1 deploy (`MultisigFactory` `0x21f0…602E`, `Multisig` `0x346D…df1e`) lacked contract signers and is superseded — do not create new wallets on it.

Pinned ABI URLs (commit-stable):
- `https://raw.githubusercontent.com/clawdbotatg/slop-computer-wallet/main/abi/Multisig.json`
- `https://raw.githubusercontent.com/clawdbotatg/slop-computer-wallet/main/abi/MultisigFactory.json`

Etherscan also serves the ABI directly via API per address.

---

## 2. Constants you'll need everywhere

```ts
import MultisigAbi from "./abi/Multisig.json";
import FactoryAbi from "./abi/MultisigFactory.json";

export const FACTORY = "0xfcdEe21865b60C2700C23Cd946316CEdA0F215B5" as const;
export const MULTISIG_IMPL = "0x5Be7f750Cc271DBf0C6027a45bFe78b99504CE3A" as const;

export const SIGNER_TYPE = { Account: 0, Passkey: 1 } as const;
export type Signature = {
  sigType: 0 | 1;        // 0 = Account (EOA / 7702 / Safe / Multisig / any ERC-1271), 1 = Passkey
  signer: `0x${string}`; // the account address, or keccak256(qx||qy)[12:] for passkeys
  data: `0x${string}`;   // Account: a 65-byte ECDSA sig (EOA/7702) OR an ERC-1271 blob (Safe/Multisig/contract);
                         // the contract tries ECDSA first, then ERC-1271. Passkey: abi.encode(qx, qy, WebAuthnAuth)
};
```

---

## 3. Predict a multisig address before deploying

The factory binds `msg.sender` into the effective CREATE2 salt to prevent front-running, so each deployer gets their own address space for any given user-supplied salt.

```ts
import { createPublicClient, http } from "viem";
import { mainnet } from "viem/chains";

const client = createPublicClient({ chain: mainnet, transport: http(RPC_URL) });

const predicted = await client.readContract({
  address: FACTORY,
  abi: FactoryAbi,
  functionName: "getMultisigAddress",
  args: [DEPLOYER_EOA, SALT_BYTES32],
});
// → address(20 bytes)
```

`SALT_BYTES32` is any 32-byte value you choose; we use `keccak256(toBytes(label))` in our reference frontend. Different `(deployer, salt)` pairs deterministically map to different multisig addresses.

**Cross-chain identity**: predict on chain A, deploy on chain B — the address is identical because the factory address, salt, and clone init-code hash are identical on every chain. So you can pre-fund a future multisig address on multiple chains before it ever physically exists on any of them.

---

## 4. Create a multisig

```ts
import { walletClient } from "./your-wallet";

const hash = await walletClient.writeContract({
  address: FACTORY,
  abi: FactoryAbi,
  functionName: "createMultisig",
  args: [
    accounts,           // address[]            — account signers: EOA / 7702 / Safe / Multisig / any ERC-1271
    passkeyQxs,         // bytes32[]            — passkey x-coords (parallel arrays)
    passkeyQys,         // bytes32[]            — passkey y-coords
    credentialIdHashes, // bytes32[]            — keccak256(credentialId) per passkey, 0x00 to skip
    threshold,          // uint256              — sigs required (1 <= threshold <= total signers)
    salt,               // bytes32              — your unique salt
  ],
});
```

**Validation rules** (revert with `InvalidThreshold`, `InvalidSigner`, `AlreadySigner`, `LengthMismatch`):
- `threshold >= 1` and `threshold <= accounts.length + passkeyQxs.length`
- No `address(0)` in `accounts`, and no account may be the multisig itself (`address(this)`)
- No duplicate signers (an address may not appear twice — across accounts and passkeys after the passkey-address derivation)
- For passkeys: `qx != 0 && qy != 0`
- Account signers have **no** code requirement — a plain EOA (no code) is fine; the contract validates it by ECDSA
- Array lengths match: `passkeyQxs.length == passkeyQys.length == credentialIdHashes.length`

**Passkey address derivation**: `passkeyAddr = address(uint160(uint256(keccak256(abi.encodePacked(qx, qy)))))`. The contract exposes this as `Multisig.getPasskeyAddress(qx, qy)` view.

**Event emitted**:
```solidity
event MultisigCreated(
  address indexed multisig,
  address indexed deployer,
  bytes32 salt,
  address[] accounts,
  uint256 threshold
);
```

---

## 5. Compute the exec hash off-chain

Signers sign this hash. Both the contract and your client must agree on it.

**Single call** — `Multisig.getExecHash(target, value, data, deadline)`:

```solidity
keccak256(abi.encode(
  block.chainid,    // uint256
  address(this),    // address — the multisig
  nonce,            // uint256 — Multisig.nonce() at sign time
  deadline,         // uint256 — unix timestamp; tx is valid through this second inclusive
  target,           // address
  value,            // uint256
  keccak256(data)   // bytes32 — hash of the calldata, NOT data itself
))
```

```ts
import { encodeAbiParameters, keccak256, parseAbiParameters } from "viem";

const nonce = await client.readContract({
  address: multisig, abi: MultisigAbi, functionName: "nonce",
});

const execHash = keccak256(
  encodeAbiParameters(
    parseAbiParameters("uint256, address, uint256, uint256, address, uint256, bytes32"),
    [BigInt(chainId), multisig, nonce, deadline, target, value, keccak256(data)],
  ),
);
```

**Batch call** — `Multisig.getBatchExecHash(calls, deadline)`:

```solidity
keccak256(abi.encode(
  block.chainid,
  address(this),
  nonce,
  deadline,
  keccak256(abi.encode(calls))   // bytes32 — hash of the abi-encoded Call[]
))
```

The contract exposes `getExecHash` and `getBatchExecHash` as view functions, so when in doubt you can just call them on-chain.

---

## 6. Sign the hash

### Account signer — EOA / 7702 smart account

A normal `personal_sign` works (the contract accepts both raw and personal_sign-prefixed digests, trying raw first):

```ts
const sig = await walletClient.signMessage({
  message: { raw: execHash },  // viem treats `{raw: ...}` as personal_sign over the bytes
});

const signature: Signature = {
  sigType: SIGNER_TYPE.Account,
  signer: signerAddress,       // recovers from execHash (raw or personal_sign-prefixed)
  data: sig,                   // 65 bytes: r || s || v
};
```

### Passkey signer (WebAuthn / P-256)

Have the authenticator sign over a challenge equal to the **raw** `execHash` bytes (no prefix). The contract verifies via OpenZeppelin's `WebAuthn.verify`.

```ts
const challenge = hexToBytes(execHash);
// ...kick off navigator.credentials.get with publicKey.challenge = challenge...
const auth = await getWebAuthnAssertion(challenge, credentialId);

const signature: Signature = {
  sigType: SIGNER_TYPE.Passkey,
  signer: passkeyAddress,      // keccak256(qx||qy)[12:]
  data: encodeAbiParameters(
    parseAbiParameters("bytes32, bytes32, (bytes32, bytes32, uint256, uint256, bytes, string)"),
    [qx, qy, {
      r: auth.r, s: auth.s,
      challengeIndex: auth.challengeIndex,
      typeIndex: auth.typeIndex,
      authenticatorData: auth.authenticatorData,
      clientDataJSON: auth.clientDataJSON,
    }],
  ),
};
```

The inner tuple matches OpenZeppelin's `WebAuthn.WebAuthnAuth` struct exactly.

### Account signer — contract wallet (Safe / nested Multisig / any ERC-1271)

A contract account signer is **also** `sigType: Account` — the contract tries ECDSA first (which fails for a contract address) and then falls back to the signer's ERC-1271 `isValidSignature(execHash, data)`. The `data` is whatever that contract's validator expects.

For a **nested Multisig**, `data` is its own `Signature[]` blob: collect threshold-or-more signatures from the child's signers over the parent's `execHash` (its account signers via `signMessage({raw})` / personal_sign; its passkeys via raw challenge), sorted by signer, then:

```ts
const signature: Signature = {
  sigType: SIGNER_TYPE.Account,        // contract signers are Accounts too in v4
  signer: childMultisigAddress,
  data: encodeAbiParameters(
    parseAbiParameters("(uint8 sigType, address signer, bytes data)[]"),
    [childSignatures],
  ),
};
```

For a **Gnosis Safe**, `data` is the Safe owners' signature blob over the `SafeMessage`-wrapped `execHash` (produced via the Safe app / SDK).

The parent does a `staticcall` to `childMultisigAddress.isValidSignature(execHash, data)` and accepts the signer iff it returns the `0x1626ba7e` magic value. A reverting or non-conforming child fails closed (treated as an invalid signature). The child counts as exactly **one** signer toward the parent's threshold, regardless of its own internal threshold.

For non-`Multisig` ERC-1271 signers (a Safe, a custom validator), `data` is whatever that contract's `isValidSignature` expects.

---

## 7. Execute

`signatures[]` **must be sorted ascending by `signer`** — the contract rejects out-of-order arrays as `SignersUnsorted` and rejects duplicates the same way (since `signer <= prev` for either case).

```ts
const sorted = signatures.sort((a, b) =>
  a.signer.toLowerCase() < b.signer.toLowerCase() ? -1 : 1,
);

const txHash = await walletClient.writeContract({
  address: multisig,
  abi: MultisigAbi,
  functionName: "execTransaction",
  args: [target, value, data, deadline, sorted],
});
```

For batches:

```ts
await walletClient.writeContract({
  address: multisig,
  abi: MultisigAbi,
  functionName: "execBatchTransaction",
  args: [calls, deadline, sorted],
});
```

A successful `execTransaction` / `execBatchTransaction` increments `nonce` by 1 and emits `Executed(target, value, data)` for each call. Reverts (and their meanings) are listed in [§11](#11-error-reference).

---

## 8. ERC-1271 (signing as the multisig)

The multisig itself can sign messages on behalf of integrations that check `IERC1271.isValidSignature(bytes32 hash, bytes signatures)`.

The `signatures` blob is `abi.encode(Signature[])` — the same struct array as `execTransaction`, sorted by signer. The contract returns `0x1626ba7e` if at least `threshold` registered signers produced valid signatures over `hash`.

**Note on EOA signers**: ERC-1271 accepts **either** a signature over the raw hash **as-passed** (no prefix — so EIP-712 callers like Permit2 / Seaport / CoW Protocol work) **or** a `personal_sign`-prefixed signature over it. Raw is tried first. The prefixed form is what lets a wallet EOA (MetaMask) co-sign as a signer of a nested `Multisig` without raw-hash signing. Contract account signers fall through to their own ERC-1271 validator.

```ts
const packed = encodeAbiParameters(
  parseAbiParameters(
    "(uint8 sigType, address signer, bytes data)[]",
  ),
  [sortedSignatures],
);

const magic = await client.readContract({
  address: multisig, abi: MultisigAbi, functionName: "isValidSignature",
  args: [eip712Digest, packed],
});
// magic === "0x1626ba7e" → valid
```

A `personal_sign` over the hash validates for account signers (raw is tried first, then the prefixed form), so you don't need to special-case prefix handling off-chain — a normal `signMessage({ raw: hash })` works.

---

## 9. Admin actions

All membership changes are `onlySelf` — the multisig must call them on itself via a threshold-approved `execTransaction`. Encode the calldata for one of these functions, then push it through the normal exec flow with `target = multisig`:

| Function | Args | What it does |
|---|---|---|
| `addAccountSigner(address signer)` | account address | Adds an account signer (EOA / 7702 / Safe / Multisig / any ERC-1271). Reverts `InvalidSigner` for `address(0)` or the multisig itself |
| `addPasskeySigner(bytes32 qx, bytes32 qy, bytes32 credentialIdHash)` | passkey coords + lookup hash | Adds a passkey signer |
| `removeSigner(address signer)` | any signer address | Removes a signer. Reverts `InvalidThreshold` if it would drop signer count below current threshold |
| `changeThreshold(uint256 newThreshold)` | new M | Reverts `InvalidThreshold` if `newThreshold == 0` or `> signers.length` |

`addPasskeySigner` rejects zero coordinates (`qx == 0 || qy == 0`). `addAccountSigner` rejects `address(0)` and self. All reject duplicates.

Example: queue an "add account signer" through exec:

```ts
const data = encodeFunctionData({
  abi: MultisigAbi,
  functionName: "addAccountSigner",
  args: [newSignerAddress],
});

// Sign + execute as normal, with target = multisig and value = 0.
```

---

## 10. Reading state

Common view functions:

```ts
// All current signers (no particular order)
const signers = await client.readContract({
  address: multisig, abi: MultisigAbi, functionName: "getSigners",
});

const threshold = await client.readContract({
  address: multisig, abi: MultisigAbi, functionName: "threshold",
});

const nonce = await client.readContract({
  address: multisig, abi: MultisigAbi, functionName: "nonce",
});

// Per-signer metadata. `kind` is the SignerType enum: 0 = Account, 1 = Passkey.
const [exists, kind, qx, qy] = await client.readContract({
  address: multisig, abi: MultisigAbi, functionName: "signerInfo",
  args: [someAddress],
});

// Is this address a passkey signer?
const isPasskey = await client.readContract({
  address: multisig, abi: MultisigAbi, functionName: "isPasskey",
  args: [someAddress],
});

// Is this address an account signer (EOA / 7702 / contract wallet)?
const isAccountSigner = await client.readContract({
  address: multisig, abi: MultisigAbi, functionName: "isAccountSigner",
  args: [someAddress],
});

// Reverse lookup: which passkey is registered for a given credentialId?
const [passkeyAddr, qx, qy] = await client.readContract({
  address: multisig, abi: MultisigAbi, functionName: "getPasskeyByCredentialId",
  args: [credentialIdHash],
});
```

Events you'll typically index:

```solidity
event SignerAdded(address indexed signer, uint8 kind); // SignerType: 0 = Account, 1 = Passkey
event SignerRemoved(address indexed signer);
event ThresholdChanged(uint256 newThreshold);
event Executed(address indexed target, uint256 value, bytes data);
event BatchExecuted(uint256 callCount);
```

Plus the factory:

```solidity
event MultisigCreated(
  address indexed multisig,
  address indexed deployer,
  bytes32 salt,
  address[] accounts,
  uint256 threshold
);
```

---

## 11. Error reference

Reverts from `Multisig`:

| Error | Meaning |
|---|---|
| `NotSelf()` | `onlySelf` function called by an external caller (admin actions are only callable via threshold-approved exec) |
| `InvalidThreshold()` | Threshold is 0, exceeds signer count, or removing a signer would drop signers below threshold |
| `InvalidSigner()` | `address(0)`, zero passkey coordinates, or an account signer equal to the multisig itself |
| `AlreadySigner()` | Address already registered as a signer |
| `NotSigner()` | Sig produced by an address that isn't a signer |
| `LengthMismatch()` | Parallel passkey arrays have different lengths |
| `ExpiredSignature()` | `block.timestamp > deadline` |
| `InvalidSignature()` | Account: neither ECDSA recovery (raw or prefixed) nor the signer's ERC-1271 validator accepted the sig. Passkey: WebAuthn verify failed or coords don't match |
| `ThresholdNotMet()` | Fewer signatures provided than required |
| `SignersUnsorted()` | Signature array not sorted ascending by `signer` (this also catches duplicate signers) |
| `ExecutionFailed()` | Inner call reverted with no data; otherwise the inner revert is bubbled up verbatim |
| `SignerTypeMismatch()` | The `sigType` in the signature doesn't match the registered signer's kind (Account vs Passkey) |
| `EmptyBatch()` | `execBatchTransaction` called with zero calls (no-op rejected to avoid burning a nonce) |

Reverts from `MultisigFactory`:

| Error | Meaning |
|---|---|
| `ImplementationHasNoCode()` | Factory constructor was given an address with no contract code |

---

## 12. Cross-chain replay

Each exec hash includes `block.chainid` so a signature collected on Ethereum mainnet can't be replayed on Base or any other chain. If you want to authorize the same action on multiple chains, you sign multiple hashes (one per chain) and submit each independently.

This is true even though the multisig addresses are identical across chains — same address ≠ same state, and nonces advance independently per chain.

---

## 13. Frontend integration cheat sheet

Minimum viable flow:

1. Read `factory.getMultisigAddress(deployer, salt)` to predict + display the address.
2. Call `factory.createMultisig(...)` with the signer set + threshold + salt.
3. For each transaction the user wants to propose:
   1. Read `multisig.nonce()` and pick a `deadline`.
   2. Compute `execHash` per [§5](#5-compute-the-exec-hash-off-chain) (or call `multisig.getExecHash` for safety).
   3. Each signer signs it; collect signatures off-chain (any transport works — link share, IPFS, server, etc).
   4. Sort by `signer` and call `multisig.execTransaction(target, value, data, deadline, sorted)`.
4. Watch `Executed` events for confirmation.

For an admin change (add/remove signer, change threshold), repeat step 3 with `target = multisig` and `data = encodeFunctionData(...)` for the admin function.

For ERC-1271 verification against the multisig: collect threshold-or-more signatures of the dapp's hash (no prefix), abi-encode them as `Signature[]`, return the encoded bytes from your wallet provider's `personal_sign` / `eth_signTypedData` handler.
