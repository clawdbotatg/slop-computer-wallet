// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import "forge-std/Test.sol";
import "../contracts/Multisig.sol";
import "../contracts/MultisigFactory.sol";

contract MultisigTest is Test {
    Multisig public implementation;
    MultisigFactory public factory;
    Multisig public wallet;

    address public aliceAddr;
    uint256 public alicePk;
    address public bobAddr;
    uint256 public bobPk;
    address public carolAddr;
    uint256 public carolPk;
    address public eveAddr;
    uint256 public evePk;

    bytes4 constant ERC1271_MAGIC = 0x1626ba7e;
    bytes4 constant ERC1271_INVALID = 0xffffffff;

    function setUp() public {
        alicePk = 0xA11CE;
        aliceAddr = vm.addr(alicePk);
        bobPk = 0xB0B;
        bobAddr = vm.addr(bobPk);
        carolPk = 0xCAFE;
        carolAddr = vm.addr(carolPk);
        evePk = 0xEEE;
        eveAddr = vm.addr(evePk);

        implementation = new Multisig();
        factory = new MultisigFactory(address(implementation));

        address[] memory accounts = new address[](3);
        accounts[0] = aliceAddr;
        accounts[1] = bobAddr;
        accounts[2] = carolAddr;
        bytes32[] memory empty = new bytes32[](0);

        address ms = factory.createMultisig(accounts, empty, empty, empty, 2, bytes32(uint256(1)));
        wallet = Multisig(payable(ms));
        vm.deal(address(wallet), 10 ether);
    }

    // ============ Initialization ============

    function test_Initialize() public view {
        assertEq(wallet.threshold(), 2);
        assertEq(wallet.signerCount(), 3);
        assertEq(wallet.nonce(), 0);
        assertTrue(_isSigner(aliceAddr));
        assertTrue(_isSigner(bobAddr));
        assertTrue(_isSigner(carolAddr));
        assertFalse(_isSigner(eveAddr));
    }

    function test_Initialize_RevertOnBadThreshold() public {
        address[] memory accounts = new address[](2);
        accounts[0] = aliceAddr;
        accounts[1] = bobAddr;
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert(Multisig.InvalidThreshold.selector);
        factory.createMultisig(accounts, empty, empty, empty, 3, bytes32(uint256(2)));
    }

    function test_CannotInitializeImplementationDirectly() public {
        address[] memory accounts = new address[](1);
        accounts[0] = aliceAddr;
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert();
        implementation.initialize(accounts, empty, empty, empty, 1);
    }

    // ============ Single exec ============

    function test_ExecTransaction_TransfersEth() public {
        address recipient = makeAddr("recipient");
        uint256 amount = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(recipient, amount, "", deadline);

        Multisig.Signature[] memory sigs = _twoEoaSigs(hash, alicePk, aliceAddr, bobPk, bobAddr);

        wallet.execTransaction(recipient, amount, "", deadline, sigs);

        assertEq(recipient.balance, amount);
        assertEq(wallet.nonce(), 1);
    }

    function test_ExecTransaction_RevertOnTooFewSigners() public {
        address recipient = makeAddr("recipient");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(recipient, 1 ether, "", deadline);

        Multisig.Signature[] memory sigs = new Multisig.Signature[](1);
        sigs[0] = _eoaSig(hash, alicePk, aliceAddr);

        vm.expectRevert(Multisig.ThresholdNotMet.selector);
        wallet.execTransaction(recipient, 1 ether, "", deadline, sigs);
    }

    function test_ExecTransaction_RevertOnUnsortedSignatures() public {
        address recipient = makeAddr("recipient");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(recipient, 1 ether, "", deadline);

        // intentionally pass in reverse order
        (address hi, uint256 hiPk, address lo, uint256 loPk) =
            aliceAddr < bobAddr ? (bobAddr, bobPk, aliceAddr, alicePk) : (aliceAddr, alicePk, bobAddr, bobPk);

        Multisig.Signature[] memory sigs = new Multisig.Signature[](2);
        sigs[0] = _eoaSig(hash, hiPk, hi);
        sigs[1] = _eoaSig(hash, loPk, lo);

        vm.expectRevert(Multisig.SignersUnsorted.selector);
        wallet.execTransaction(recipient, 1 ether, "", deadline, sigs);
    }

    function test_ExecTransaction_RevertOnNonSigner() public {
        address recipient = makeAddr("recipient");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(recipient, 1 ether, "", deadline);

        Multisig.Signature[] memory sigs = new Multisig.Signature[](2);
        Multisig.Signature memory aliceSig = _eoaSig(hash, alicePk, aliceAddr);
        Multisig.Signature memory eveSig = _eoaSig(hash, evePk, eveAddr);
        // place them in ascending order regardless of identity
        if (aliceAddr < eveAddr) {
            sigs[0] = aliceSig;
            sigs[1] = eveSig;
        } else {
            sigs[0] = eveSig;
            sigs[1] = aliceSig;
        }

        vm.expectRevert(Multisig.NotSigner.selector);
        wallet.execTransaction(recipient, 1 ether, "", deadline, sigs);
    }

    function test_ExecTransaction_RevertOnReplay() public {
        address recipient = makeAddr("recipient");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(recipient, 1 ether, "", deadline);
        Multisig.Signature[] memory sigs = _twoEoaSigs(hash, alicePk, aliceAddr, bobPk, bobAddr);

        wallet.execTransaction(recipient, 1 ether, "", deadline, sigs);
        // nonce incremented, so same sigs no longer match new hash
        vm.expectRevert(Multisig.InvalidSignature.selector);
        wallet.execTransaction(recipient, 1 ether, "", deadline, sigs);
    }

    function test_ExecTransaction_RevertOnExpired() public {
        address recipient = makeAddr("recipient");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(recipient, 1 ether, "", deadline);
        Multisig.Signature[] memory sigs = _twoEoaSigs(hash, alicePk, aliceAddr, bobPk, bobAddr);

        vm.warp(deadline + 1);
        vm.expectRevert(Multisig.ExpiredSignature.selector);
        wallet.execTransaction(recipient, 1 ether, "", deadline, sigs);
    }

    // ============ Batch exec ============

    function test_ExecBatch() public {
        address r1 = makeAddr("r1");
        address r2 = makeAddr("r2");
        Multisig.Call[] memory calls = new Multisig.Call[](2);
        calls[0] = Multisig.Call({ target: r1, value: 0.5 ether, data: "" });
        calls[1] = Multisig.Call({ target: r2, value: 0.25 ether, data: "" });

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getBatchExecHash(calls, deadline);
        Multisig.Signature[] memory sigs = _twoEoaSigs(hash, alicePk, aliceAddr, bobPk, bobAddr);

        wallet.execBatchTransaction(calls, deadline, sigs);
        assertEq(r1.balance, 0.5 ether);
        assertEq(r2.balance, 0.25 ether);
        assertEq(wallet.nonce(), 1);
    }

    // ============ Self-governed admin ============

    function test_AddAccountSigner_ViaExec() public {
        bytes memory data = abi.encodeWithSelector(Multisig.addAccountSigner.selector, eveAddr);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(address(wallet), 0, data, deadline);
        Multisig.Signature[] memory sigs = _twoEoaSigs(hash, alicePk, aliceAddr, bobPk, bobAddr);

        wallet.execTransaction(address(wallet), 0, data, deadline, sigs);
        assertTrue(_isSigner(eveAddr));
        assertTrue(wallet.isAccountSigner(eveAddr));
        assertEq(wallet.signerCount(), 4);
    }

    function test_RemoveSigner_ViaExec() public {
        bytes memory data = abi.encodeWithSelector(Multisig.removeSigner.selector, carolAddr);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(address(wallet), 0, data, deadline);
        Multisig.Signature[] memory sigs = _twoEoaSigs(hash, alicePk, aliceAddr, bobPk, bobAddr);

        wallet.execTransaction(address(wallet), 0, data, deadline, sigs);
        assertFalse(_isSigner(carolAddr));
        assertEq(wallet.signerCount(), 2);
    }

    function test_RemoveSigner_RevertIfDropsBelowThreshold() public {
        // remove carol then bob (would leave 1 signer with threshold 2)
        bytes memory data1 = abi.encodeWithSelector(Multisig.removeSigner.selector, carolAddr);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 h1 = wallet.getExecHash(address(wallet), 0, data1, deadline);
        wallet.execTransaction(
            address(wallet), 0, data1, deadline, _twoEoaSigs(h1, alicePk, aliceAddr, bobPk, bobAddr)
        );

        bytes memory data2 = abi.encodeWithSelector(Multisig.removeSigner.selector, bobAddr);
        bytes32 h2 = wallet.getExecHash(address(wallet), 0, data2, deadline);
        Multisig.Signature[] memory sigs = _twoEoaSigs(h2, alicePk, aliceAddr, bobPk, bobAddr);
        vm.expectRevert(Multisig.InvalidThreshold.selector);
        wallet.execTransaction(address(wallet), 0, data2, deadline, sigs);
    }

    function test_ChangeThreshold_ViaExec() public {
        bytes memory data = abi.encodeWithSelector(Multisig.changeThreshold.selector, uint256(3));
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(address(wallet), 0, data, deadline);
        Multisig.Signature[] memory sigs = _twoEoaSigs(hash, alicePk, aliceAddr, bobPk, bobAddr);

        wallet.execTransaction(address(wallet), 0, data, deadline, sigs);
        assertEq(wallet.threshold(), 3);
    }

    function test_DirectAdminCall_Reverts() public {
        vm.expectRevert(Multisig.NotSelf.selector);
        wallet.addAccountSigner(eveAddr);
        vm.expectRevert(Multisig.NotSelf.selector);
        wallet.removeSigner(aliceAddr);
        vm.expectRevert(Multisig.NotSelf.selector);
        wallet.changeThreshold(1);
    }

    // ============ ERC-1271 ============

    function test_IsValidSignature_ThresholdMet() public view {
        bytes32 msgHash = keccak256("hello multisig");
        Multisig.Signature[] memory sigs = _twoEoaSigsRaw(msgHash, alicePk, aliceAddr, bobPk, bobAddr);
        bytes memory packed = abi.encode(sigs);
        assertEq(wallet.isValidSignature(msgHash, packed), ERC1271_MAGIC);
    }

    function test_IsValidSignature_ThresholdNotMet() public view {
        bytes32 msgHash = keccak256("nope");
        Multisig.Signature[] memory sigs = new Multisig.Signature[](1);
        sigs[0] = _eoaSigRaw(msgHash, alicePk, aliceAddr);
        bytes memory packed = abi.encode(sigs);
        assertEq(wallet.isValidSignature(msgHash, packed), ERC1271_INVALID);
    }

    function test_IsValidSignature_ForgedSignerFails() public view {
        bytes32 msgHash = keccak256("forge me");
        Multisig.Signature[] memory sigs = new Multisig.Signature[](2);
        Multisig.Signature memory aliceSig = _eoaSigRaw(msgHash, alicePk, aliceAddr);
        Multisig.Signature memory eveSig = _eoaSigRaw(msgHash, evePk, eveAddr);
        if (aliceAddr < eveAddr) {
            sigs[0] = aliceSig;
            sigs[1] = eveSig;
        } else {
            sigs[0] = eveSig;
            sigs[1] = aliceSig;
        }
        bytes memory packed = abi.encode(sigs);
        assertEq(wallet.isValidSignature(msgHash, packed), ERC1271_INVALID);
    }

    function test_IsValidSignature_AcceptsRawAndPersonalSign() public view {
        // Account signers validate via ECDSA accepting EITHER the raw digest (EIP-712 / Permit2)
        // OR the personal_sign-prefixed one (what wallet EOAs like MetaMask produce). Both pass.
        bytes32 msgHash = keccak256("prefixed");
        Multisig.Signature[] memory prefixed = _twoEoaSigs(msgHash, alicePk, aliceAddr, bobPk, bobAddr);
        assertEq(wallet.isValidSignature(msgHash, abi.encode(prefixed)), ERC1271_MAGIC);
        Multisig.Signature[] memory raw = _twoEoaSigsRaw(msgHash, alicePk, aliceAddr, bobPk, bobAddr);
        assertEq(wallet.isValidSignature(msgHash, abi.encode(raw)), ERC1271_MAGIC);
    }

    // ============ Audit-driven additions ============

    function test_M1_Initialize_RevertOnZeroPasskeyCoordinates() public {
        address[] memory accounts = new address[](1);
        accounts[0] = aliceAddr;
        bytes32[] memory qxs = new bytes32[](1);
        bytes32[] memory qys = new bytes32[](1);
        bytes32[] memory creds = new bytes32[](1);
        // qx = qy = 0 should be rejected.
        vm.expectRevert(Multisig.InvalidSigner.selector);
        factory.createMultisig(accounts, qxs, qys, creds, 1, bytes32(uint256(99)));
    }

    function test_L1_RemoveSigner_ClearsCredentialIdMapping() public {
        // Register a passkey via threshold-approved self-call.
        bytes32 qx = bytes32(uint256(0x1234));
        bytes32 qy = bytes32(uint256(0x5678));
        bytes32 credId = keccak256("cred-1");
        address pkAddr = wallet.getPasskeyAddress(qx, qy);

        bytes memory addData = abi.encodeWithSelector(Multisig.addPasskeySigner.selector, qx, qy, credId);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 addHash = wallet.getExecHash(address(wallet), 0, addData, deadline);
        wallet.execTransaction(
            address(wallet), 0, addData, deadline, _twoEoaSigs(addHash, alicePk, aliceAddr, bobPk, bobAddr)
        );

        assertEq(wallet.credentialIdToAddress(credId), pkAddr);
        assertEq(wallet.credentialIdOf(pkAddr), credId);

        // Now remove the passkey.
        bytes memory rmData = abi.encodeWithSelector(Multisig.removeSigner.selector, pkAddr);
        bytes32 rmHash = wallet.getExecHash(address(wallet), 0, rmData, deadline);
        wallet.execTransaction(
            address(wallet), 0, rmData, deadline, _twoEoaSigs(rmHash, alicePk, aliceAddr, bobPk, bobAddr)
        );

        assertEq(wallet.credentialIdToAddress(credId), address(0), "reverse mapping should be cleared");
        assertEq(wallet.credentialIdOf(pkAddr), bytes32(0), "forward mapping should be cleared");
    }

    function test_L2_Factory_DifferentDeployersGetDifferentAddresses() public {
        address[] memory accounts = new address[](1);
        accounts[0] = aliceAddr;
        bytes32[] memory empty = new bytes32[](0);
        bytes32 salt = bytes32(uint256(7));

        address aliceDeployed;
        address bobDeployed;
        vm.prank(aliceAddr);
        aliceDeployed = factory.createMultisig(accounts, empty, empty, empty, 1, salt);
        vm.prank(bobAddr);
        bobDeployed = factory.createMultisig(accounts, empty, empty, empty, 1, salt);

        assertTrue(aliceDeployed != bobDeployed, "same salt + different deployer should yield different addresses");
        assertEq(factory.getMultisigAddress(aliceAddr, salt), aliceDeployed);
        assertEq(factory.getMultisigAddress(bobAddr, salt), bobDeployed);
    }

    function test_I3_ExecBatch_RevertOnEmpty() public {
        Multisig.Call[] memory calls = new Multisig.Call[](0);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getBatchExecHash(calls, deadline);
        Multisig.Signature[] memory sigs = _twoEoaSigs(hash, alicePk, aliceAddr, bobPk, bobAddr);
        vm.expectRevert(Multisig.EmptyBatch.selector);
        wallet.execBatchTransaction(calls, deadline, sigs);
        // Nonce must not advance on a rejected batch.
        assertEq(wallet.nonce(), 0);
    }

    function test_C_L3_ExecTransactionIsNonReentrant() public {
        ReentrantTarget bad = new ReentrantTarget(address(wallet));

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory innerData = "";
        bytes32 innerHash = keccak256(
            abi.encode(block.chainid, address(wallet), uint256(1), deadline, address(this), uint256(0), keccak256(""))
        );
        Multisig.Signature[] memory innerSigs = _twoEoaSigs(innerHash, alicePk, aliceAddr, bobPk, bobAddr);
        bad.arm(address(this), 0, innerData, deadline, innerSigs);

        bytes memory outerData = abi.encodeWithSelector(ReentrantTarget.trigger.selector);
        bytes32 outerHash = wallet.getExecHash(address(bad), 0, outerData, deadline);
        Multisig.Signature[] memory outerSigs = _twoEoaSigs(outerHash, alicePk, aliceAddr, bobPk, bobAddr);

        vm.expectRevert();
        wallet.execTransaction(address(bad), 0, outerData, deadline, outerSigs);
    }

    function test_B_L1_FactoryRejectsCodelessImplementation() public {
        vm.expectRevert(MultisigFactory.ImplementationHasNoCode.selector);
        new MultisigFactory(aliceAddr);
    }

    // ============ Account (ERC-1271) signers / nested multisigs ============

    /// @dev Deploy a 2-of-2 child multisig owned by alice + bob (both account signers).
    function _deployChild(bytes32 salt) internal returns (Multisig child) {
        address[] memory accounts = new address[](2);
        accounts[0] = aliceAddr;
        accounts[1] = bobAddr;
        bytes32[] memory empty = new bytes32[](0);
        child = Multisig(payable(factory.createMultisig(accounts, empty, empty, empty, 2, salt)));
    }

    /// @dev Build an Account signature whose data is an ERC-1271 blob (the contract signer's own
    ///      Signature[]). The contract tries ECDSA first (fails — not 65 bytes) then ERC-1271.
    function _contractSig(address signer, Multisig.Signature[] memory inner)
        internal
        pure
        returns (Multisig.Signature memory)
    {
        return Multisig.Signature({ sigType: Multisig.SignerType.Account, signer: signer, data: abi.encode(inner) });
    }

    /// @dev Deploy a parent with [eve, child] both as account signers, threshold 2.
    function _deployParent(Multisig child, bytes32 salt) internal returns (Multisig parent) {
        address[] memory accounts = new address[](2);
        accounts[0] = eveAddr;
        accounts[1] = address(child);
        bytes32[] memory empty = new bytes32[](0);
        parent = Multisig(payable(factory.createMultisig(accounts, empty, empty, empty, 2, salt)));
    }

    function _sortPair(Multisig.Signature memory a, address aAddr, Multisig.Signature memory b, address bAddr)
        internal
        pure
        returns (Multisig.Signature[] memory sigs)
    {
        sigs = new Multisig.Signature[](2);
        if (aAddr < bAddr) {
            sigs[0] = a;
            sigs[1] = b;
        } else {
            sigs[0] = b;
            sigs[1] = a;
        }
    }

    /// @dev Parent [eve, child] executes: eve signs (account/personal_sign), child contributes its
    ///      own alice+bob signatures via ERC-1271. Child sub-signers sign the RAW parent hash here.
    function test_NestedMultisig_ExecTransaction() public {
        Multisig child = _deployChild(bytes32(uint256(0xC417D)));
        Multisig parent = _deployParent(child, bytes32(uint256(0xDAD)));
        vm.deal(address(parent), 10 ether);

        assertTrue(parent.isAccountSigner(address(child)));

        address recipient = makeAddr("nested-recipient");
        uint256 amount = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 parentHash = parent.getExecHash(recipient, amount, "", deadline);

        Multisig.Signature[] memory childInner = _twoEoaSigsRaw(parentHash, alicePk, aliceAddr, bobPk, bobAddr);
        Multisig.Signature memory eveSig = _eoaSig(parentHash, evePk, eveAddr);
        Multisig.Signature memory childSig = _contractSig(address(child), childInner);
        Multisig.Signature[] memory sigs = _sortPair(eveSig, eveAddr, childSig, address(child));

        parent.execTransaction(recipient, amount, "", deadline, sigs);
        assertEq(recipient.balance, amount);
        assertEq(parent.nonce(), 1);
    }

    /// @dev A contract signer also satisfies the parent's own ERC-1271 isValidSignature.
    function test_NestedMultisig_IsValidSignature() public {
        Multisig child = _deployChild(bytes32(uint256(0xC418D)));
        Multisig parent = _deployParent(child, bytes32(uint256(0xDAE)));

        bytes32 msgHash = keccak256("nested erc-1271");
        Multisig.Signature[] memory childInner = _twoEoaSigsRaw(msgHash, alicePk, aliceAddr, bobPk, bobAddr);
        Multisig.Signature memory eveSig = _eoaSigRaw(msgHash, evePk, eveAddr);
        Multisig.Signature memory childSig = _contractSig(address(child), childInner);
        Multisig.Signature[] memory sigs = _sortPair(eveSig, eveAddr, childSig, address(child));

        assertEq(parent.isValidSignature(msgHash, abi.encode(sigs)), ERC1271_MAGIC);
    }

    /// @dev The key v3/v4 case: the nested child's signers are EOAs using personal_sign (prefixed) —
    ///      what MetaMask produces. Accepted without raw-hash signing.
    function test_NestedMultisig_ExecTransaction_EoaPersonalSign() public {
        Multisig child = _deployChild(bytes32(uint256(0xC419D)));
        Multisig parent = _deployParent(child, bytes32(uint256(0xDAF)));
        vm.deal(address(parent), 10 ether);

        address recipient = makeAddr("nested-eoa-recipient");
        uint256 amount = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 parentHash = parent.getExecHash(recipient, amount, "", deadline);

        // Child's signers sign with personal_sign (prefixed) — NOT raw.
        Multisig.Signature[] memory childInner = _twoEoaSigs(parentHash, alicePk, aliceAddr, bobPk, bobAddr);
        Multisig.Signature memory eveSig = _eoaSig(parentHash, evePk, eveAddr);
        Multisig.Signature memory childSig = _contractSig(address(child), childInner);
        Multisig.Signature[] memory sigs = _sortPair(eveSig, eveAddr, childSig, address(child));

        parent.execTransaction(recipient, amount, "", deadline, sigs);
        assertEq(recipient.balance, amount);
        assertEq(parent.nonce(), 1);
    }

    function test_AddAccountSigner_Contract_ViaExec() public {
        MockERC1271 mock = new MockERC1271();
        mock.set(true);
        bytes memory data = abi.encodeWithSelector(Multisig.addAccountSigner.selector, address(mock));
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(address(wallet), 0, data, deadline);
        wallet.execTransaction(address(wallet), 0, data, deadline, _twoEoaSigs(hash, alicePk, aliceAddr, bobPk, bobAddr));
        assertTrue(wallet.isAccountSigner(address(mock)));
        assertEq(wallet.signerCount(), 4);
    }

    /// @dev A codeless EOA is a perfectly valid account signer (v4 drops the old code requirement).
    function test_AddAccountSigner_AcceptsCodelessEoa() public {
        bytes memory data = abi.encodeWithSelector(Multisig.addAccountSigner.selector, eveAddr);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(address(wallet), 0, data, deadline);
        wallet.execTransaction(address(wallet), 0, data, deadline, _twoEoaSigs(hash, alicePk, aliceAddr, bobPk, bobAddr));
        assertTrue(wallet.isAccountSigner(eveAddr));
    }

    function test_AddAccountSigner_RevertOnSelf() public {
        bytes memory data = abi.encodeWithSelector(Multisig.addAccountSigner.selector, address(wallet));
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(address(wallet), 0, data, deadline);
        Multisig.Signature[] memory sigs = _twoEoaSigs(hash, alicePk, aliceAddr, bobPk, bobAddr);
        vm.expectRevert(Multisig.InvalidSigner.selector);
        wallet.execTransaction(address(wallet), 0, data, deadline, sigs);
    }

    /// @dev A contract account signer whose validator reverts must fail closed (InvalidSignature).
    function test_ContractSigner_RevertingValidatorFailsClosed() public {
        MockERC1271 mock = new MockERC1271();
        mock.setRevert(true);
        _registerAccountSigner(address(mock));

        address recipient = makeAddr("r");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(recipient, 1 ether, "", deadline);
        Multisig.Signature memory aliceSig = _eoaSig(hash, alicePk, aliceAddr);
        Multisig.Signature memory mockSig = _contractSig(address(mock), new Multisig.Signature[](0));
        Multisig.Signature[] memory sigs = _sortPair(aliceSig, aliceAddr, mockSig, address(mock));
        vm.expectRevert(Multisig.InvalidSignature.selector);
        wallet.execTransaction(recipient, 1 ether, "", deadline, sigs);
    }

    function test_ContractSigner_WrongMagicFails() public {
        MockERC1271 mock = new MockERC1271();
        mock.set(false); // returns 0xffffffff
        _registerAccountSigner(address(mock));

        address recipient = makeAddr("r2");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(recipient, 1 ether, "", deadline);
        Multisig.Signature memory aliceSig = _eoaSig(hash, alicePk, aliceAddr);
        Multisig.Signature memory mockSig = _contractSig(address(mock), new Multisig.Signature[](0));
        Multisig.Signature[] memory sigs = _sortPair(aliceSig, aliceAddr, mockSig, address(mock));
        vm.expectRevert(Multisig.InvalidSignature.selector);
        wallet.execTransaction(recipient, 1 ether, "", deadline, sigs);
    }

    /// @dev An account signer presented with sigType Passkey must be rejected (type mismatch).
    function test_AccountSigner_TypeMismatchRejected() public {
        MockERC1271 mock = new MockERC1271();
        mock.set(true);
        _registerAccountSigner(address(mock));

        address recipient = makeAddr("r3");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(recipient, 1 ether, "", deadline);
        Multisig.Signature memory aliceSig = _eoaSig(hash, alicePk, aliceAddr);
        // Mislabel the account signer as a passkey.
        Multisig.Signature memory mockSig =
            Multisig.Signature({ sigType: Multisig.SignerType.Passkey, signer: address(mock), data: hex"00" });
        Multisig.Signature[] memory sigs = _sortPair(aliceSig, aliceAddr, mockSig, address(mock));
        vm.expectRevert(Multisig.SignerTypeMismatch.selector);
        wallet.execTransaction(recipient, 1 ether, "", deadline, sigs);
    }

    /// @dev Register an account signer on `wallet` via a threshold-approved self-call.
    function _registerAccountSigner(address signer) internal {
        bytes memory data = abi.encodeWithSelector(Multisig.addAccountSigner.selector, signer);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(address(wallet), 0, data, deadline);
        wallet.execTransaction(address(wallet), 0, data, deadline, _twoEoaSigs(hash, alicePk, aliceAddr, bobPk, bobAddr));
    }

    // ============ helpers ============

    function _isSigner(address addr) internal view returns (bool) {
        (bool exists,,,) = wallet.signerInfo(addr);
        return exists;
    }

    function _eoaSig(bytes32 hash, uint256 pk, address signer) internal pure returns (Multisig.Signature memory) {
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethHash);
        return
            Multisig.Signature({ sigType: Multisig.SignerType.Account, signer: signer, data: abi.encodePacked(r, s, v) });
    }

    function _eoaSigRaw(bytes32 hash, uint256 pk, address signer) internal pure returns (Multisig.Signature memory) {
        // No personal_sign prefix — exercises the raw-digest branch.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);
        return
            Multisig.Signature({ sigType: Multisig.SignerType.Account, signer: signer, data: abi.encodePacked(r, s, v) });
    }

    function _twoEoaSigsRaw(bytes32 hash, uint256 pk1, address addr1, uint256 pk2, address addr2)
        internal
        pure
        returns (Multisig.Signature[] memory sigs)
    {
        return _sortPair(_eoaSigRaw(hash, pk1, addr1), addr1, _eoaSigRaw(hash, pk2, addr2), addr2);
    }

    function _twoEoaSigs(bytes32 hash, uint256 pk1, address addr1, uint256 pk2, address addr2)
        internal
        pure
        returns (Multisig.Signature[] memory sigs)
    {
        return _sortPair(_eoaSig(hash, pk1, addr1), addr1, _eoaSig(hash, pk2, addr2), addr2);
    }
}

/// @notice Helper used by test_C_L3_*: when the multisig calls `trigger()`, this contract
/// re-enters `execTransaction` on the multisig. With the reentrancy guard in place this
/// inner call must revert.
contract ReentrantTarget {
    Multisig public immutable wallet;
    address public target;
    uint256 public value;
    bytes public data;
    uint256 public deadline;
    Multisig.Signature[] internal _sigs;

    constructor(address _wallet) {
        wallet = Multisig(payable(_wallet));
    }

    function arm(
        address _target,
        uint256 _value,
        bytes calldata _data,
        uint256 _deadline,
        Multisig.Signature[] calldata sigs
    ) external {
        target = _target;
        value = _value;
        data = _data;
        deadline = _deadline;
        delete _sigs;
        for (uint256 i = 0; i < sigs.length; i++) {
            _sigs.push(sigs[i]);
        }
    }

    function trigger() external {
        wallet.execTransaction(target, value, data, deadline, _sigs);
    }
}

/// @notice Configurable ERC-1271 validator used to test the contract-account-signer path:
/// it can return the magic value, return the invalid sentinel, or revert.
contract MockERC1271 is IERC1271 {
    bool internal _ok;
    bool internal _revert;

    function set(bool ok) external {
        _ok = ok;
        _revert = false;
    }

    function setRevert(bool doRevert) external {
        _revert = doRevert;
    }

    function isValidSignature(bytes32, bytes memory) external view returns (bytes4) {
        if (_revert) revert("MockERC1271: nope");
        return _ok ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}
