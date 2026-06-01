//SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/WebAuthn.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title Multisig
 * @notice A simple M-of-N multisig that accepts EOA, passkey (WebAuthn / secp256r1), and
 *         ERC-1271 contract signers (e.g. another Multisig) as members.
 * @notice Supports ERC-1271 signature validation so the multisig itself can sign off-chain messages
 *         AND can in turn be registered as a signer on another ERC-1271-aware contract (incl. another Multisig).
 * @author BuidlGuidl
 */
contract Multisig is IERC1271, Initializable, ReentrancyGuardTransient {
    enum SignerType {
        EOA,
        Passkey,
        ERC1271
    }

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @dev One element per signature. `signer` MUST be ascending across the array to prevent duplicates.
    /// For EOA: data = 65-byte ECDSA signature, signer = recovered address.
    /// For Passkey: data = abi.encode(bytes32 qx, bytes32 qy, WebAuthn.WebAuthnAuth auth), signer = passkey address.
    /// For ERC1271: data = the inner signature blob forwarded verbatim to signer.isValidSignature(hash, data),
    ///              signer = the contract signer's address.
    struct Signature {
        SignerType sigType;
        address signer;
        bytes data;
    }

    struct SignerInfo {
        bool exists;
        SignerType kind; // authoritative type discriminator (EOA / Passkey / ERC1271)
        bytes32 qx; // passkey only; 0 otherwise
        bytes32 qy; // passkey only; 0 otherwise
    }

    /// @notice Per-signer metadata. exists=true means active signer.
    mapping(address => SignerInfo) public signerInfo;

    /// @notice Iterable list of all current signers (no particular order).
    address[] internal _signers;

    /// @notice Number of signatures required to execute a transaction.
    uint256 public threshold;

    /// @notice Replay nonce. Incremented on every successful execTransaction / execBatchTransaction.
    uint256 public nonce;

    /// @notice Optional reverse lookup: keccak256(credentialId) => passkey address (for login flows).
    mapping(bytes32 => address) public credentialIdToAddress;

    /// @notice Forward lookup: passkey signer address => credentialId hash that maps to it (0 if none set).
    /// @dev Kept so removeSigner can clear `credentialIdToAddress` and avoid stale reverse-lookup entries.
    mapping(address => bytes32) public credentialIdOf;

    event SignerAdded(address indexed signer, SignerType kind);
    event SignerRemoved(address indexed signer);
    event ThresholdChanged(uint256 newThreshold);
    event Executed(address indexed target, uint256 value, bytes data);
    event BatchExecuted(uint256 callCount);

    error NotSelf();
    error InvalidThreshold();
    error InvalidSigner();
    error AlreadySigner();
    error NotSigner();
    error LengthMismatch();
    error ExpiredSignature();
    error InvalidSignature();
    error ThresholdNotMet();
    error SignersUnsorted();
    error ExecutionFailed();
    error SignerTypeMismatch();
    error EmptyBatch();
    error ContractSignerHasNoCode();

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the multisig with EOA signers, passkey signers, contract (ERC-1271) signers, and a threshold.
     * @param eoaSigners Array of EOA signer addresses.
     * @param passkeyQxs Array of passkey x-coordinates (parallel to passkeyQys / credentialIdHashes).
     * @param passkeyQys Array of passkey y-coordinates.
     * @param credentialIdHashes Array of keccak256(credentialId) values for reverse login lookup. Use 0 to skip.
     * @param contractSigners Array of ERC-1271 contract signer addresses (e.g. another Multisig). Must have code.
     * @param _threshold Number of signatures required to execute (1 <= _threshold <= total signers).
     */
    function initialize(
        address[] calldata eoaSigners,
        bytes32[] calldata passkeyQxs,
        bytes32[] calldata passkeyQys,
        bytes32[] calldata credentialIdHashes,
        address[] calldata contractSigners,
        uint256 _threshold
    ) external initializer {
        if (passkeyQxs.length != passkeyQys.length || passkeyQxs.length != credentialIdHashes.length) {
            revert LengthMismatch();
        }
        uint256 total = eoaSigners.length + passkeyQxs.length + contractSigners.length;
        if (_threshold == 0 || _threshold > total) revert InvalidThreshold();

        for (uint256 i = 0; i < eoaSigners.length; i++) {
            _addSigner(eoaSigners[i], SignerType.EOA, 0, 0, 0);
        }
        for (uint256 i = 0; i < passkeyQxs.length; i++) {
            // M-1: reject zero passkey coordinates so we never register a slot that no one can sign for.
            if (passkeyQxs[i] == bytes32(0) || passkeyQys[i] == bytes32(0)) revert InvalidSigner();
            address pkAddr = getPasskeyAddress(passkeyQxs[i], passkeyQys[i]);
            _addSigner(pkAddr, SignerType.Passkey, passkeyQxs[i], passkeyQys[i], credentialIdHashes[i]);
        }
        for (uint256 i = 0; i < contractSigners.length; i++) {
            _addContractSigner(contractSigners[i]);
        }

        threshold = _threshold;
        emit ThresholdChanged(_threshold);
    }

    // ============ View helpers ============

    /// @notice Derive a deterministic address from passkey public key coordinates.
    function getPasskeyAddress(bytes32 qx, bytes32 qy) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(qx, qy)))));
    }

    /// @notice Return all current signers.
    function getSigners() external view returns (address[] memory) {
        return _signers;
    }

    /// @notice Total active signer count.
    function signerCount() external view returns (uint256) {
        return _signers.length;
    }

    /// @notice True if `addr` is a registered passkey signer.
    function isPasskey(address addr) public view returns (bool) {
        return signerInfo[addr].kind == SignerType.Passkey;
    }

    /// @notice True if `addr` is a registered ERC-1271 contract signer.
    function isContractSigner(address addr) external view returns (bool) {
        SignerInfo memory info = signerInfo[addr];
        return info.exists && info.kind == SignerType.ERC1271;
    }

    /// @notice Look up a passkey by credentialId hash (login flow). Returns zeroes if not registered.
    function getPasskeyByCredentialId(bytes32 credentialIdHash)
        external
        view
        returns (address passkeyAddr, bytes32 qx, bytes32 qy)
    {
        passkeyAddr = credentialIdToAddress[credentialIdHash];
        if (passkeyAddr != address(0)) {
            qx = signerInfo[passkeyAddr].qx;
            qy = signerInfo[passkeyAddr].qy;
        }
    }

    // ============ Self-governed admin (callable only via execTransaction reaching threshold) ============

    function addEoaSigner(address signer) external onlySelf {
        _addSigner(signer, SignerType.EOA, 0, 0, 0);
    }

    function addPasskeySigner(bytes32 qx, bytes32 qy, bytes32 credentialIdHash) external onlySelf {
        if (qx == bytes32(0) || qy == bytes32(0)) revert InvalidSigner();
        address pkAddr = getPasskeyAddress(qx, qy);
        _addSigner(pkAddr, SignerType.Passkey, qx, qy, credentialIdHash);
    }

    /// @notice Register an ERC-1271 contract (e.g. another Multisig) as a signer.
    /// @dev The contract must already have code; a codeless address could never validate a signature.
    function addContractSigner(address signer) external onlySelf {
        _addContractSigner(signer);
    }

    function removeSigner(address signer) external onlySelf {
        SignerInfo memory info = signerInfo[signer];
        if (!info.exists) revert NotSigner();
        if (_signers.length - 1 < threshold) revert InvalidThreshold();

        delete signerInfo[signer];

        // L-1: clear the reverse credentialId mapping so off-chain lookups don't return a removed passkey.
        bytes32 credId = credentialIdOf[signer];
        if (credId != bytes32(0)) {
            delete credentialIdToAddress[credId];
            delete credentialIdOf[signer];
        }

        // swap-pop from _signers
        for (uint256 i = 0; i < _signers.length; i++) {
            if (_signers[i] == signer) {
                _signers[i] = _signers[_signers.length - 1];
                _signers.pop();
                break;
            }
        }
        emit SignerRemoved(signer);
    }

    function changeThreshold(uint256 newThreshold) external onlySelf {
        if (newThreshold == 0 || newThreshold > _signers.length) revert InvalidThreshold();
        threshold = newThreshold;
        emit ThresholdChanged(newThreshold);
    }

    /// @dev Validate-and-register a contract signer. Rejects self-reference (which would recurse on
    ///      verification) and codeless addresses (which could never produce a valid ERC-1271 result).
    function _addContractSigner(address signer) internal {
        if (signer == address(this)) revert InvalidSigner();
        if (signer.code.length == 0) revert ContractSignerHasNoCode();
        _addSigner(signer, SignerType.ERC1271, 0, 0, 0);
    }

    function _addSigner(address signer, SignerType kind, bytes32 qx, bytes32 qy, bytes32 credId) internal {
        if (signer == address(0)) revert InvalidSigner();
        if (signerInfo[signer].exists) revert AlreadySigner();
        signerInfo[signer] = SignerInfo({ exists: true, kind: kind, qx: qx, qy: qy });
        _signers.push(signer);
        if (credId != bytes32(0)) {
            credentialIdToAddress[credId] = signer;
            credentialIdOf[signer] = credId;
        }
        emit SignerAdded(signer, kind);
    }

    // ============ Execution ============

    /// @notice Hash for a single-call execution. Signatures must be over this digest.
    function getExecHash(address target, uint256 value, bytes calldata data, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), nonce, deadline, target, value, keccak256(data)));
    }

    /// @notice Hash for a batched execution.
    function getBatchExecHash(Call[] calldata calls, uint256 deadline) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), nonce, deadline, keccak256(abi.encode(calls))));
    }

    /**
     * @notice Execute a single call once enough signers have approved.
     * @dev Signatures array MUST be sorted ascending by `signer`.
     *      `deadline` is inclusive — a tx with `block.timestamp == deadline` still executes.
     *      `nonReentrant` (audit C L-3) prevents a malicious `target` from re-entering an exec
     *      function and consuming pre-signed signatures for a future nonce out of order.
     */
    function execTransaction(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 deadline,
        Signature[] calldata signatures
    ) external nonReentrant returns (bytes memory result) {
        if (block.timestamp > deadline) revert ExpiredSignature();
        bytes32 hash = getExecHash(target, value, data, deadline);
        _verifySignatures(hash, signatures);
        nonce++;

        (bool ok, bytes memory ret) = target.call{ value: value }(data);
        if (!ok) _bubbleRevert(ret);
        emit Executed(target, value, data);
        return ret;
    }

    /**
     * @notice Execute a batch of calls atomically once enough signers have approved.
     * @dev Signatures array MUST be sorted ascending by `signer`.
     *      `deadline` is inclusive. `nonReentrant` (audit C L-3) preserves intra-batch ordering.
     */
    function execBatchTransaction(Call[] calldata calls, uint256 deadline, Signature[] calldata signatures)
        external
        nonReentrant
        returns (bytes[] memory results)
    {
        // I-3: refuse empty batches so we never burn a nonce on a no-op.
        if (calls.length == 0) revert EmptyBatch();
        if (block.timestamp > deadline) revert ExpiredSignature();
        bytes32 hash = getBatchExecHash(calls, deadline);
        _verifySignatures(hash, signatures);
        nonce++;

        results = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].target.call{ value: calls[i].value }(calls[i].data);
            if (!ok) _bubbleRevert(ret);
            emit Executed(calls[i].target, calls[i].value, calls[i].data);
            results[i] = ret;
        }
        emit BatchExecuted(calls.length);
    }

    function _bubbleRevert(bytes memory ret) internal pure {
        if (ret.length == 0) revert ExecutionFailed();
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }

    // ============ Signature verification ============

    function _verifySignatures(bytes32 hash, Signature[] calldata signatures) internal view {
        if (signatures.length < threshold) revert ThresholdNotMet();

        address prev = address(0);
        for (uint256 i = 0; i < signatures.length; i++) {
            Signature calldata sig = signatures[i];
            if (sig.signer <= prev) revert SignersUnsorted();
            prev = sig.signer;

            SignerInfo memory info = signerInfo[sig.signer];
            if (!info.exists) revert NotSigner();
            if (sig.sigType != info.kind) revert SignerTypeMismatch();

            if (info.kind == SignerType.EOA) {
                // EOAs sign the personal_sign-prefixed digest (what wallets produce for eth_sign / signMessage).
                bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(hash);
                address recovered = ECDSA.recover(ethHash, sig.data);
                if (recovered != sig.signer) revert InvalidSignature();
            } else if (info.kind == SignerType.Passkey) {
                (bytes32 qx, bytes32 qy, WebAuthn.WebAuthnAuth memory auth) =
                    abi.decode(sig.data, (bytes32, bytes32, WebAuthn.WebAuthnAuth));
                if (qx != info.qx || qy != info.qy) revert InvalidSignature();
                bytes memory challenge = abi.encodePacked(hash);
                if (!WebAuthn.verify(challenge, auth, qx, qy)) revert InvalidSignature();
            } else {
                // ERC-1271 contract signer (e.g. a nested Multisig). Forward the raw hash; the signer
                // applies its own digest scheme. A staticcall keeps this view and blocks re-entrancy.
                if (!_isValidContractSig(sig.signer, hash, sig.data)) revert InvalidSignature();
            }
        }
    }

    /// @dev Validate a contract signer via ERC-1271. Wrapped in try/catch so a reverting or
    ///      non-conforming signer fails closed (treated as an invalid signature) rather than
    ///      bubbling a revert through verification.
    function _isValidContractSig(address signer, bytes32 hash, bytes memory data) internal view returns (bool) {
        try IERC1271(signer).isValidSignature(hash, data) returns (bytes4 magic) {
            return magic == IERC1271.isValidSignature.selector;
        } catch {
            return false;
        }
    }

    /**
     * @notice ERC-1271 signature validation. Returns the magic value if `signatures` proves that at least
     *         `threshold` registered signers signed `hash`. The signature bytes is an abi-encoded Signature[].
     */
    function isValidSignature(bytes32 hash, bytes memory signatures) external view returns (bytes4 magicValue) {
        Signature[] memory sigs = abi.decode(signatures, (Signature[]));
        if (sigs.length < threshold) return 0xffffffff;

        address prev = address(0);
        for (uint256 i = 0; i < sigs.length; i++) {
            Signature memory sig = sigs[i];
            if (sig.signer <= prev) return 0xffffffff;
            prev = sig.signer;

            SignerInfo memory info = signerInfo[sig.signer];
            if (!info.exists) return 0xffffffff;
            if (sig.sigType != info.kind) return 0xffffffff;

            if (info.kind == SignerType.EOA) {
                // M-2: ERC-1271 verifies the hash as-signed. DeFi protocols (EIP-712 / signTypedData_v4) pass an
                // already-prepared digest — adding a personal_sign prefix here would silently reject them.
                (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, sig.data);
                if (err != ECDSA.RecoverError.NoError || recovered != sig.signer) return 0xffffffff;
            } else if (info.kind == SignerType.Passkey) {
                (bytes32 qx, bytes32 qy, WebAuthn.WebAuthnAuth memory auth) =
                    abi.decode(sig.data, (bytes32, bytes32, WebAuthn.WebAuthnAuth));
                if (qx != info.qx || qy != info.qy) return 0xffffffff;
                bytes memory challenge = abi.encodePacked(hash);
                if (!WebAuthn.verify(challenge, auth, qx, qy)) return 0xffffffff;
            } else {
                // ERC-1271 contract signer: forward the raw hash to its own validator.
                if (!_isValidContractSig(sig.signer, hash, sig.data)) return 0xffffffff;
            }
        }

        return IERC1271.isValidSignature.selector;
    }

    // ============ Receivers ============

    receive() external payable { }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
