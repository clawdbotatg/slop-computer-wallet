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

    event MultisigCreated(address indexed multisig, bytes32 salt, address[] eoaSigners, uint256 threshold);

    constructor(address _implementation) {
        implementation = _implementation;
    }

    /**
     * @notice Deploy a new Multisig clone with the given signer set and threshold.
     * @param eoaSigners EOA signer addresses.
     * @param passkeyQxs Passkey x-coordinates (parallel to passkeyQys / credentialIdHashes).
     * @param passkeyQys Passkey y-coordinates.
     * @param credentialIdHashes keccak256(credentialId) hashes for login lookup; pass 0 to skip.
     * @param threshold Number of signatures required.
     * @param salt Caller-chosen salt to make the address deterministic.
     * @return multisig Address of the deployed clone.
     */
    function createMultisig(
        address[] calldata eoaSigners,
        bytes32[] calldata passkeyQxs,
        bytes32[] calldata passkeyQys,
        bytes32[] calldata credentialIdHashes,
        uint256 threshold,
        bytes32 salt
    ) external returns (address multisig) {
        multisig = Clones.cloneDeterministic(implementation, salt);
        Multisig(payable(multisig)).initialize(eoaSigners, passkeyQxs, passkeyQys, credentialIdHashes, threshold);
        emit MultisigCreated(multisig, salt, eoaSigners, threshold);
    }

    /// @notice Predict the address of a multisig deployed with the given salt.
    function getMultisigAddress(bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, salt, address(this));
    }
}
