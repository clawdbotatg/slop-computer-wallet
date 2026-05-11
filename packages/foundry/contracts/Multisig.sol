//SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/WebAuthn.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @title Multisig
 * @notice A simple M-of-N multisig that accepts EOA and passkey (WebAuthn / secp256r1) signers
 * @notice Supports ERC-1271 signature validation so the multisig itself can sign off-chain messages
 * @author BuidlGuidl
 */
contract Multisig is IERC1271, Initializable {
    enum SignerType {
        EOA,
        Passkey
    }

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @dev One element per signature. `signer` MUST be ascending across the array to prevent duplicates.
    /// For EOA: data = 65-byte ECDSA signature, signer = recovered address.
    /// For Passkey: data = abi.encode(bytes32 qx, bytes32 qy, WebAuthn.WebAuthnAuth auth), signer = passkey address.
    struct Signature {
        SignerType sigType;
        address signer;
        bytes data;
    }

    struct SignerInfo {
        bool exists;
        bytes32 qx; // 0 for EOA, non-zero for passkey
        bytes32 qy; // 0 for EOA, non-zero for passkey
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

    event SignerAdded(address indexed signer, bool isPasskey);
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

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the multisig with EOA signers, passkey signers, and a threshold.
     * @param eoaSigners Array of EOA signer addresses.
     * @param passkeyQxs Array of passkey x-coordinates (parallel to passkeyQys / credentialIdHashes).
     * @param passkeyQys Array of passkey y-coordinates.
     * @param credentialIdHashes Array of keccak256(credentialId) values for reverse login lookup. Use 0 to skip.
     * @param _threshold Number of signatures required to execute (1 <= _threshold <= total signers).
     */
    function initialize(
        address[] calldata eoaSigners,
        bytes32[] calldata passkeyQxs,
        bytes32[] calldata passkeyQys,
        bytes32[] calldata credentialIdHashes,
        uint256 _threshold
    ) external initializer {
        if (passkeyQxs.length != passkeyQys.length || passkeyQxs.length != credentialIdHashes.length) {
            revert LengthMismatch();
        }
        uint256 total = eoaSigners.length + passkeyQxs.length;
        if (_threshold == 0 || _threshold > total) revert InvalidThreshold();

        for (uint256 i = 0; i < eoaSigners.length; i++) {
            _addSigner(eoaSigners[i], 0, 0, 0);
        }
        for (uint256 i = 0; i < passkeyQxs.length; i++) {
            address pkAddr = getPasskeyAddress(passkeyQxs[i], passkeyQys[i]);
            _addSigner(pkAddr, passkeyQxs[i], passkeyQys[i], credentialIdHashes[i]);
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

    /// @notice True if `addr` is a registered passkey signer (vs an EOA signer).
    function isPasskey(address addr) public view returns (bool) {
        return signerInfo[addr].qx != bytes32(0);
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
        _addSigner(signer, 0, 0, 0);
    }

    function addPasskeySigner(bytes32 qx, bytes32 qy, bytes32 credentialIdHash) external onlySelf {
        if (qx == bytes32(0) || qy == bytes32(0)) revert InvalidSigner();
        address pkAddr = getPasskeyAddress(qx, qy);
        _addSigner(pkAddr, qx, qy, credentialIdHash);
    }

    function removeSigner(address signer) external onlySelf {
        SignerInfo memory info = signerInfo[signer];
        if (!info.exists) revert NotSigner();
        if (_signers.length - 1 < threshold) revert InvalidThreshold();

        delete signerInfo[signer];
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

    function _addSigner(address signer, bytes32 qx, bytes32 qy, bytes32 credId) internal {
        if (signer == address(0)) revert InvalidSigner();
        if (signerInfo[signer].exists) revert AlreadySigner();
        signerInfo[signer] = SignerInfo({ exists: true, qx: qx, qy: qy });
        _signers.push(signer);
        if (credId != bytes32(0)) {
            credentialIdToAddress[credId] = signer;
        }
        emit SignerAdded(signer, qx != bytes32(0));
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
     */
    function execTransaction(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 deadline,
        Signature[] calldata signatures
    ) external returns (bytes memory result) {
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
     */
    function execBatchTransaction(Call[] calldata calls, uint256 deadline, Signature[] calldata signatures)
        external
        returns (bytes[] memory results)
    {
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

            if (sig.sigType == SignerType.EOA) {
                if (info.qx != bytes32(0)) revert SignerTypeMismatch();
                // EOAs sign the personal_sign-prefixed digest (what wallets produce for eth_sign / signMessage).
                bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(hash);
                address recovered = ECDSA.recover(ethHash, sig.data);
                if (recovered != sig.signer) revert InvalidSignature();
            } else {
                if (info.qx == bytes32(0)) revert SignerTypeMismatch();
                (bytes32 qx, bytes32 qy, WebAuthn.WebAuthnAuth memory auth) =
                    abi.decode(sig.data, (bytes32, bytes32, WebAuthn.WebAuthnAuth));
                if (qx != info.qx || qy != info.qy) revert InvalidSignature();
                bytes memory challenge = abi.encodePacked(hash);
                if (!WebAuthn.verify(challenge, auth, qx, qy)) revert InvalidSignature();
            }
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

            if (sig.sigType == SignerType.EOA) {
                if (info.qx != bytes32(0)) return 0xffffffff;
                bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(hash);
                (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(ethHash, sig.data);
                if (err != ECDSA.RecoverError.NoError || recovered != sig.signer) return 0xffffffff;
            } else {
                if (info.qx == bytes32(0)) return 0xffffffff;
                (bytes32 qx, bytes32 qy, WebAuthn.WebAuthnAuth memory auth) =
                    abi.decode(sig.data, (bytes32, bytes32, WebAuthn.WebAuthnAuth));
                if (qx != info.qx || qy != info.qy) return 0xffffffff;
                bytes memory challenge = abi.encodePacked(hash);
                if (!WebAuthn.verify(challenge, auth, qx, qy)) return 0xffffffff;
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
