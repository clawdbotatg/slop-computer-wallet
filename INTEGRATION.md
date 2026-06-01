# Integration guide

Everything a frontend / backend / bot needs to talk to the live `MultisigFactory` and `Multisig` contracts. All examples use [viem](https://viem.sh) but the same calls work in ethers or any other lib.

---

## 1. Live addresses & ABIs

| | Address | ABI |
|---|---|---|
| `Multisig` (implementation) | [`0x20d8866d59aA288966e515f3c6cA886555a2Ae11`](https://etherscan.io/address/0x20d8866d59aA288966e515f3c6cA886555a2Ae11#code) | [`abi/Multisig.json`](abi/Multisig.json) |
| `MultisigFactory` | [`0x695123afA4E2C4F948E977e1974Ac80372044F31`](https://etherscan.io/address/0x695123afA4E2C4F948E977e1974Ac80372044F31#code) | [`abi/MultisigFactory.json`](abi/MultisigFactory.json) |

These are the **v3** addresses (the `-v3` deploy salt). v2 added ERC-1271 contract signers (a `Multisig` can be a signer on another `Multisig`); v3 makes `isValidSignature` accept a personal_sign-prefixed signature in addition to the raw digest, so a wallet EOA (e.g. MetaMask) can be a signer of a nested `Multisig` without raw-hash signing. Same addresses on every chain we deploy to (as long as the source doesn't change). See [`README.md`](README.md#deploying-to-a-new-chain) for the deploy walkthrough.

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

export const FACTORY = "0x695123afA4E2C4F948E977e1974Ac80372044F31" as const;
export const MULTISIG_IMPL = "0x20d8866d59aA288966e515f3c6cA886555a2Ae11" as const;

export const SIGNER_TYPE = { EOA: 0, Passkey: 1, ERC1271: 2 } as const;
export type Signature = {
  sigType: 0 | 1 | 2;    // 0 = EOA, 1 = Passkey, 2 = ERC1271 (contract signer)
  signer: `0x${string}`; // EOA address, keccak256(qx||qy)[12:] for passkeys, or the contract signer's address
  data: `0x${string}`;   // EOA: 65-byte ECDSA sig · Passkey: abi.encode(qx, qy, WebAuthnAuth)
                         // ERC1271: the inner blob forwarded verbatim to signer.isValidSignature(hash, data)
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
    eoaSigners,         // address[]            — EOA signer addresses
    passkeyQxs,         // bytes32[]            — passkey x-coords (parallel arrays)
    passkeyQys,         // bytes32[]            — passkey y-coords
    credentialIdHashes, // bytes32[]            — keccak256(credentialId) per passkey, 0x00 to skip
    contractSigners,    // address[]            — ERC-1271 contract signers (e.g. another Multisig); must have code
    threshold,          // uint256              — sigs required (1 <= threshold <= total signers)
    salt,               // bytes32              — your unique salt
  ],
});
```

**Validation rules** (revert with `InvalidThreshold`, `InvalidSigner`, `AlreadySigner`, `LengthMismatch`, `ContractSignerHasNoCode`):
- `threshold >= 1` and `threshold <= eoaSigners.length + passkeyQxs.length + contractSigners.length`
- No `address(0)` in `eoaSigners`
- No duplicate signers (an address may not appear twice — across EOA, passkey, and contract-signer sets after the passkey-address derivation)
- For passkeys: `qx != 0 && qy != 0`
- For contract signers: the address must have code, and may not be the multisig itself (`address(this)`)
- Array lengths match: `passkeyQxs.length == passkeyQys.length == credentialIdHashes.length`

**Passkey address derivation**: `passkeyAddr = address(uint160(uint256(keccak256(abi.encodePacked(qx, qy)))))`. The contract exposes this as `Multisig.getPasskeyAddress(qx, qy)` view.

**Event emitted**:
```solidity
event MultisigCreated(
  address indexed multisig,
  address indexed deployer,
  bytes32 salt,
  address[] eoaSigners,
  address[] contractSigners,
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

### EOA signer

The contract applies the `\x19Ethereum Signed Message:\n32` prefix before `ecrecover`, so a normal `personal_sign` works:

```ts
const sig = await walletClient.signMessage({
  message: { raw: execHash },  // viem treats `{raw: ...}` as personal_sign over the bytes
});

const signature: Signature = {
  sigType: SIGNER_TYPE.EOA,
  signer: signerAddress,       // must equal ecrecover(prefixed(execHash), sig)
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

### Contract signer (ERC-1271 / nested multisig)

A registered contract signer (e.g. another `Multisig`) approves by producing an ERC-1271 signature blob that its own `isValidSignature(hash, data)` accepts. The parent forwards the `execHash` to the child. The child's **passkey** signers sign that hash as their raw challenge; its **EOA** signers can sign it either raw or (as of v3) via a normal `personal_sign` — the latter is what lets a MetaMask EOA co-sign without raw-hash signing.

```ts
// `childSignatures` = threshold-or-more Signature[] from the child's signers over the parent's
// execHash (EOA: signMessage({raw}) personal_sign works in v3; passkey: raw challenge), sorted by signer.
const signature: Signature = {
  sigType: SIGNER_TYPE.ERC1271,
  signer: childMultisigAddress,
  data: encodeAbiParameters(
    parseAbiParameters("(uint8 sigType, address signer, bytes data)[]"),
    [childSignatures],
  ),
};
```

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

**Important semantic difference from `execTransaction`**: for EOA signers, ERC-1271 accepts **either** a signature over the raw hash **as-passed** (no prefix — so EIP-712 callers like Permit2 / Seaport / CoW Protocol work) **or** a `personal_sign`-prefixed signature over it. Raw is tried first. The prefixed form is what lets a wallet EOA (MetaMask) co-sign as a signer of a nested `Multisig` without raw-hash signing.

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

As of v3 a `personal_sign` over the hash also validates for EOA signers (raw is tried first, then the prefixed form), so you don't need to special-case prefix handling off-chain — a normal `signMessage({ raw: hash })` works.

---

## 9. Admin actions

All membership changes are `onlySelf` — the multisig must call them on itself via a threshold-approved `execTransaction`. Encode the calldata for one of these functions, then push it through the normal exec flow with `target = multisig`:

| Function | Args | What it does |
|---|---|---|
| `addEoaSigner(address signer)` | EOA address | Adds an EOA signer |
| `addPasskeySigner(bytes32 qx, bytes32 qy, bytes32 credentialIdHash)` | passkey coords + lookup hash | Adds a passkey signer |
| `addContractSigner(address signer)` | contract address | Adds an ERC-1271 contract signer (e.g. another `Multisig`). Reverts `ContractSignerHasNoCode` if codeless, `InvalidSigner` if it's the multisig itself |
| `removeSigner(address signer)` | any signer address | Removes a signer. Reverts `InvalidThreshold` if it would drop signer count below current threshold |
| `changeThreshold(uint256 newThreshold)` | new M | Reverts `InvalidThreshold` if `newThreshold == 0` or `> signers.length` |

`addPasskeySigner` rejects zero coordinates (`qx == 0 || qy == 0`). `addEoaSigner` rejects `address(0)`. `addContractSigner` requires the address to have code. All reject duplicates.

Example: queue an "add EOA signer" through exec:

```ts
const data = encodeFunctionData({
  abi: MultisigAbi,
  functionName: "addEoaSigner",
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

// Per-signer metadata. `kind` is the SignerType enum: 0 = EOA, 1 = Passkey, 2 = ERC1271.
const [exists, kind, qx, qy] = await client.readContract({
  address: multisig, abi: MultisigAbi, functionName: "signerInfo",
  args: [someAddress],
});

// Is this address a passkey signer?
const isPasskey = await client.readContract({
  address: multisig, abi: MultisigAbi, functionName: "isPasskey",
  args: [someAddress],
});

// Is this address an ERC-1271 contract signer?
const isContractSigner = await client.readContract({
  address: multisig, abi: MultisigAbi, functionName: "isContractSigner",
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
event SignerAdded(address indexed signer, uint8 kind); // SignerType: 0 = EOA, 1 = Passkey, 2 = ERC1271
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
  address[] eoaSigners,
  address[] contractSigners,
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
| `InvalidSigner()` | `address(0)`, zero passkey coordinates, or a contract signer equal to the multisig itself |
| `AlreadySigner()` | Address already registered as a signer |
| `NotSigner()` | Sig produced by an address that isn't a signer |
| `LengthMismatch()` | Parallel passkey arrays have different lengths |
| `ExpiredSignature()` | `block.timestamp > deadline` |
| `InvalidSignature()` | ECDSA recovery doesn't match `sig.signer`, or WebAuthn verify failed, or passkey coords don't match registered ones |
| `ThresholdNotMet()` | Fewer signatures provided than required |
| `SignersUnsorted()` | Signature array not sorted ascending by `signer` (this also catches duplicate signers) |
| `ExecutionFailed()` | Inner call reverted with no data; otherwise the inner revert is bubbled up verbatim |
| `SignerTypeMismatch()` | The `sigType` in the signature doesn't match the registered signer's kind (EOA / Passkey / ERC1271) |
| `EmptyBatch()` | `execBatchTransaction` called with zero calls (no-op rejected to avoid burning a nonce) |
| `ContractSignerHasNoCode()` | `addContractSigner` / `initialize` given a contract-signer address with no code |

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
