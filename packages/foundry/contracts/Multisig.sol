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
 * @notice A simple M-of-N multisig with two signer kinds:
 *           - Account: any address validated by ECDSA-or-ERC1271 — a plain EOA, an EIP-7702-delegated
 *             EOA, a Gnosis Safe, another Multisig, or any ERC-1271 contract wallet. The contract does
 *             NOT need to know which at registration: verification tries ECDSA first (covers EOAs/7702,
 *             whose key still signs) and falls back to the signer's ERC-1271 isValidSignature.
 *           - Passkey: WebAuthn / secp256r1.
 * @notice Implements ERC-1271 so the multisig itself can sign off-chain messages AND be registered as
 *         an Account signer on another Multisig / ERC-1271-aware contract.
 * @author BuidlGuidl
 */
contract Multisig is IERC1271, Initializable, ReentrancyGuardTransient {
    enum SignerType {
        Account,
        Passkey
    }

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @dev One element per signature. `signer` MUST be ascending across the array to prevent duplicates.
    /// For Account: data = a 65-byte ECDSA signature (EOA / 7702) OR an ERC-1271 signature blob forwarded
    ///              verbatim to signer.isValidSignature(hash, data) (Safe / nested Multisig / contract wallet).
    ///              The contract tries ECDSA first, then ERC-1271 — the caller need not say which.
    /// For Passkey: data = abi.encode(bytes32 qx, bytes32 qy, WebAuthn.WebAuthnAuth auth), signer = passkey address.
    struct Signature {
        SignerType sigType;
        address signer;
        bytes data;
    }

    struct SignerInfo {
        bool exists;
        SignerType kind; // Account or Passkey
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

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the multisig with account signers, passkey signers, and a threshold.
     * @param accounts Array of account signer addresses — EOA / 7702 / Safe / Multisig / any ERC-1271 wallet.
     * @param passkeyQxs Array of passkey x-coordinates (parallel to passkeyQys / credentialIdHashes).
     * @param passkeyQys Array of passkey y-coordinates.
     * @param credentialIdHashes Array of keccak256(credentialId) values for reverse login lookup. Use 0 to skip.
     * @param _threshold Number of signatures required to execute (1 <= _threshold <= total signers).
     */
    function initialize(
        address[] calldata accounts,
        bytes32[] calldata passkeyQxs,
        bytes32[] calldata passkeyQys,
        bytes32[] calldata credentialIdHashes,
        uint256 _threshold
    ) external initializer {
        if (passkeyQxs.length != passkeyQys.length || passkeyQxs.length != credentialIdHashes.length) {
            revert LengthMismatch();
        }
        uint256 total = accounts.length + passkeyQxs.length;
        if (_threshold == 0 || _threshold > total) revert InvalidThreshold();

        for (uint256 i = 0; i < accounts.length; i++) {
            _addAccountSigner(accounts[i]);
        }
        for (uint256 i = 0; i < passkeyQxs.length; i++) {
            // M-1: reject zero passkey coordinates so we never register a slot that no one can sign for.
            if (passkeyQxs[i] == bytes32(0) || passkeyQys[i] == bytes32(0)) revert InvalidSigner();
            address pkAddr = getPasskeyAddress(passkeyQxs[i], passkeyQys[i]);
            _addSigner(pkAddr, SignerType.Passkey, passkeyQxs[i], passkeyQys[i], credentialIdHashes[i]);
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

    /// @notice True if `addr` is a registered account signer (EOA / 7702 / contract wallet).
    function isAccountSigner(address addr) external view returns (bool) {
        SignerInfo memory info = signerInfo[addr];
        return info.exists && info.kind == SignerType.Account;
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

    /// @notice Register an account signer — EOA / 7702 / Safe / Multisig / any ERC-1271 wallet.
    function addAccountSigner(address signer) external onlySelf {
        _addAccountSigner(signer);
    }

    function addPasskeySigner(bytes32 qx, bytes32 qy, bytes32 credentialIdHash) external onlySelf {
        if (qx == bytes32(0) || qy == bytes32(0)) revert InvalidSigner();
        address pkAddr = getPasskeyAddress(qx, qy);
        _addSigner(pkAddr, SignerType.Passkey, qx, qy, credentialIdHash);
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

    /// @dev Validate-and-register an account signer. Rejects self-reference (which would recurse on
    ///      ERC-1271 verification). No code requirement: a plain EOA has none, and ECDSA validates it.
    function _addAccountSigner(address signer) internal {
        if (signer == address(this)) revert InvalidSigner();
        _addSigner(signer, SignerType.Account, 0, 0, 0);
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

            if (info.kind == SignerType.Account) {
                if (!_isValidAccountSig(sig.signer, hash, sig.data)) revert InvalidSignature();
            } else {
                if (!_isValidPasskeySig(info, hash, sig.data)) revert InvalidSignature();
            }
        }
    }

    /// @dev Validate an Account signer (EOA, 7702-delegated EOA, Safe, nested Multisig, or any ERC-1271
    ///      wallet) over `hash`. Mirrors OpenZeppelin's SignatureChecker: try ECDSA first (covers EOAs /
    ///      7702 — the key still signs), accepting the raw OR personal_sign-prefixed digest; otherwise, if
    ///      the signer has code, defer to its ERC-1271 isValidSignature. staticcall + try/catch keeps this
    ///      view and fails closed, so the contract never needs to know the signer's kind in advance.
    function _isValidAccountSig(address signer, bytes32 hash, bytes memory signature) internal view returns (bool) {
        if (_recoversTo(hash, signature, signer)) return true;
        if (signer.code.length == 0) return false;
        try IERC1271(signer).isValidSignature(hash, signature) returns (bytes4 magic) {
            return magic == IERC1271.isValidSignature.selector;
        } catch {
            return false;
        }
    }

    /// @dev Validate a Passkey (WebAuthn / secp256r1) signature over `hash`.
    function _isValidPasskeySig(SignerInfo memory info, bytes32 hash, bytes memory data) internal view returns (bool) {
        (bytes32 qx, bytes32 qy, WebAuthn.WebAuthnAuth memory auth) =
            abi.decode(data, (bytes32, bytes32, WebAuthn.WebAuthnAuth));
        if (qx != info.qx || qy != info.qy) return false;
        return WebAuthn.verify(abi.encodePacked(hash), auth, qx, qy);
    }

    /// @dev True if `signature` is a valid ECDSA signature by `signer` over `hash`, accepting EITHER the
    ///      raw digest (EIP-712 / Permit2 / contract callers) OR the personal_sign-prefixed digest (what
    ///      wallet EOAs like MetaMask produce). Raw is tried first so EIP-712 flows are unchanged.
    function _recoversTo(bytes32 hash, bytes memory signature, address signer) internal pure returns (bool) {
        (address rawRec, ECDSA.RecoverError rawErr,) = ECDSA.tryRecover(hash, signature);
        if (rawErr == ECDSA.RecoverError.NoError && rawRec == signer) return true;
        (address ethRec, ECDSA.RecoverError ethErr,) =
            ECDSA.tryRecover(MessageHashUtils.toEthSignedMessageHash(hash), signature);
        return ethErr == ECDSA.RecoverError.NoError && ethRec == signer;
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

            if (info.kind == SignerType.Account) {
                if (!_isValidAccountSig(sig.signer, hash, sig.data)) return 0xffffffff;
            } else {
                if (!_isValidPasskeySig(info, hash, sig.data)) return 0xffffffff;
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
