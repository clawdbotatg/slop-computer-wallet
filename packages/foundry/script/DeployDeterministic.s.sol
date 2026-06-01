// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { console } from "forge-std/console.sol";
import "./DeployHelpers.s.sol";
import "../contracts/Multisig.sol";
import "../contracts/MultisigFactory.sol";

/**
 * @notice Cross-chain deterministic deployment of Multisig impl + MultisigFactory.
 *
 * Uses Arachnid's singleton CREATE2 deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C),
 * which is preinstalled on every major EVM chain. Because the deployer address, salts,
 * and init code are all identical across networks, the resulting addresses are byte-identical
 * on mainnet and every L2 — provided compiler version + optimizer settings match.
 *
 * Idempotent: if the contracts are already deployed on the current chain, this is a no-op
 * that just prints the existing addresses.
 *
 * Usage:
 *   yarn deploy --file DeployDeterministic.s.sol --network base
 *   yarn deploy --file DeployDeterministic.s.sol --network mainnet
 *   yarn deploy --file DeployDeterministic.s.sol --network arbitrum
 *   yarn deploy --file DeployDeterministic.s.sol --network optimism
 *
 * Or directly:
 *   forge script script/DeployDeterministic.s.sol \
 *     --rpc-url <network> \
 *     --account slop-deployer \
 *     --password-file ~/.foundry/keystores/slop-deployer.password.txt \
 *     --broadcast --ffi
 */
contract DeployDeterministic is ScaffoldETHDeploy {
    /// @notice Arachnid's singleton CREATE2 deployer (preinstalled on most major EVM chains).
    /// @dev See https://github.com/Arachnid/deterministic-deployment-proxy
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Bump these whenever the Multisig or MultisigFactory source/initcode changes
    /// to get a new address. Must match between every chain you want a shared address on.
    bytes32 constant IMPL_SALT = keccak256("slop-multisig-impl-v4");
    bytes32 constant FACTORY_SALT = keccak256("slop-multisig-factory-v4");

    error SingletonNotPresent();
    error ImplDeployFailed();
    error FactoryDeployFailed();
    error ImplMissingAfterDeploy();
    error FactoryMissingAfterDeploy();

    function run() external ScaffoldEthDeployerRunner {
        if (CREATE2_DEPLOYER.code.length == 0) revert SingletonNotPresent();

        // 1) Multisig implementation (constructor has no args).
        bytes memory implInit = type(Multisig).creationCode;
        address impl = _create2Address(IMPL_SALT, keccak256(implInit));
        if (impl.code.length == 0) {
            (bool ok,) = CREATE2_DEPLOYER.call(bytes.concat(IMPL_SALT, implInit));
            if (!ok) revert ImplDeployFailed();
        }
        if (impl.code.length == 0) revert ImplMissingAfterDeploy();

        // 2) Factory (constructor takes the implementation address).
        bytes memory factoryInit = bytes.concat(type(MultisigFactory).creationCode, abi.encode(impl));
        address factory = _create2Address(FACTORY_SALT, keccak256(factoryInit));
        if (factory.code.length == 0) {
            (bool ok,) = CREATE2_DEPLOYER.call(bytes.concat(FACTORY_SALT, factoryInit));
            if (!ok) revert FactoryDeployFailed();
        }
        if (factory.code.length == 0) revert FactoryMissingAfterDeploy();

        deployments.push(Deployment({ name: "Multisig", addr: impl }));
        deployments.push(Deployment({ name: "MultisigFactory", addr: factory }));

        console.log("chainId:        ", block.chainid);
        console.log("Multisig impl:  ", impl);
        console.log("MultisigFactory:", factory);
    }

    function _create2Address(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash))))
        );
    }
}
