//SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import "./Multisig.sol";
import "./Clones.sol";

/**
 * @title MultisigFactory
 * @notice Deploys EIP-1167 minimal proxy clones of the Multisig implementation using CREATE2.
 * @author BuidlGuidl
 */
contract MultisigFactory {
    /// @notice The Multisig implementation contract that all clones delegate to.
    address public immutable implementation;

    event MultisigCreated(
        address indexed multisig, address indexed deployer, bytes32 salt, address[] accounts, uint256 threshold
    );

    error ImplementationHasNoCode();

    constructor(address _implementation) {
        // Audit B L-1: refuse a codeless implementation so every clone has working logic.
        if (_implementation.code.length == 0) revert ImplementationHasNoCode();
        implementation = _implementation;
    }

    /**
     * @notice Deploy a new Multisig clone with the given signer set and threshold.
     * @dev The effective CREATE2 salt is keccak256(deployer, salt) so a mempool watcher
     *      cannot front-run with the same caller-chosen salt and capture pre-funded addresses.
     * @param accounts Account signer addresses — EOA / 7702 / Safe / Multisig / any ERC-1271 wallet.
     * @param passkeyQxs Passkey x-coordinates (parallel to passkeyQys / credentialIdHashes).
     * @param passkeyQys Passkey y-coordinates.
     * @param credentialIdHashes keccak256(credentialId) hashes for login lookup; pass 0 to skip.
     * @param threshold Number of signatures required.
     * @param salt Caller-chosen salt; combined with msg.sender to form the effective salt.
     * @return multisig Address of the deployed clone.
     */
    function createMultisig(
        address[] calldata accounts,
        bytes32[] calldata passkeyQxs,
        bytes32[] calldata passkeyQys,
        bytes32[] calldata credentialIdHashes,
        uint256 threshold,
        bytes32 salt
    ) external returns (address multisig) {
        bytes32 effectiveSalt = _effectiveSalt(msg.sender, salt);
        multisig = Clones.cloneDeterministic(implementation, effectiveSalt);
        Multisig(payable(multisig)).initialize(accounts, passkeyQxs, passkeyQys, credentialIdHashes, threshold);
        emit MultisigCreated(multisig, msg.sender, salt, accounts, threshold);
    }

    /// @notice Predict the address of a multisig the given deployer would get for the given salt.
    function getMultisigAddress(address deployer, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _effectiveSalt(deployer, salt), address(this));
    }

    function _effectiveSalt(address deployer, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(deployer, salt));
    }
}
