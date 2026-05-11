// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import "../contracts/Multisig.sol";
import "../contracts/MultisigFactory.sol";

/**
 * @notice Deploy the Multisig implementation and the MultisigFactory.
 * @dev Examples:
 *   yarn deploy --file DeployFactory.s.sol            # local anvil
 *   yarn deploy --file DeployFactory.s.sol --network base
 */
contract DeployFactory is ScaffoldETHDeploy {
    function run() external ScaffoldEthDeployerRunner {
        Multisig implementation = new Multisig();
        MultisigFactory factory = new MultisigFactory(address(implementation));

        deployments.push(Deployment({ name: "Multisig", addr: address(implementation) }));
        deployments.push(Deployment({ name: "MultisigFactory", addr: address(factory) }));
    }
}
