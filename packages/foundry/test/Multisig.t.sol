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

        address[] memory eoas = new address[](3);
        eoas[0] = aliceAddr;
        eoas[1] = bobAddr;
        eoas[2] = carolAddr;
        bytes32[] memory empty = new bytes32[](0);

        address ms = factory.createMultisig(eoas, empty, empty, empty, 2, bytes32(uint256(1)));
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
        address[] memory eoas = new address[](2);
        eoas[0] = aliceAddr;
        eoas[1] = bobAddr;
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert(Multisig.InvalidThreshold.selector);
        factory.createMultisig(eoas, empty, empty, empty, 3, bytes32(uint256(2)));
    }

    function test_CannotInitializeImplementationDirectly() public {
        address[] memory eoas = new address[](1);
        eoas[0] = aliceAddr;
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert();
        implementation.initialize(eoas, empty, empty, empty, 1);
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

    function test_AddEoaSigner_ViaExec() public {
        bytes memory data = abi.encodeWithSelector(Multisig.addEoaSigner.selector, eveAddr);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 hash = wallet.getExecHash(address(wallet), 0, data, deadline);
        Multisig.Signature[] memory sigs = _twoEoaSigs(hash, alicePk, aliceAddr, bobPk, bobAddr);

        wallet.execTransaction(address(wallet), 0, data, deadline, sigs);
        assertTrue(_isSigner(eveAddr));
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
        wallet.addEoaSigner(eveAddr);
        vm.expectRevert(Multisig.NotSelf.selector);
        wallet.removeSigner(aliceAddr);
        vm.expectRevert(Multisig.NotSelf.selector);
        wallet.changeThreshold(1);
    }

    // ============ ERC-1271 ============

    function test_IsValidSignature_ThresholdMet() public view {
        bytes32 msgHash = keccak256("hello multisig");
        Multisig.Signature[] memory sigs = _twoEoaSigs(msgHash, alicePk, aliceAddr, bobPk, bobAddr);
        bytes memory packed = abi.encode(sigs);
        assertEq(wallet.isValidSignature(msgHash, packed), ERC1271_MAGIC);
    }

    function test_IsValidSignature_ThresholdNotMet() public view {
        bytes32 msgHash = keccak256("nope");
        Multisig.Signature[] memory sigs = new Multisig.Signature[](1);
        sigs[0] = _eoaSig(msgHash, alicePk, aliceAddr);
        bytes memory packed = abi.encode(sigs);
        assertEq(wallet.isValidSignature(msgHash, packed), ERC1271_INVALID);
    }

    function test_IsValidSignature_ForgedSignerFails() public view {
        bytes32 msgHash = keccak256("forge me");
        Multisig.Signature[] memory sigs = new Multisig.Signature[](2);
        Multisig.Signature memory aliceSig = _eoaSig(msgHash, alicePk, aliceAddr);
        Multisig.Signature memory eveSig = _eoaSig(msgHash, evePk, eveAddr);
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

    // ============ helpers ============

    function _isSigner(address addr) internal view returns (bool) {
        (bool exists,,) = wallet.signerInfo(addr);
        return exists;
    }

    function _eoaSig(bytes32 hash, uint256 pk, address signer) internal pure returns (Multisig.Signature memory) {
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethHash);
        return Multisig.Signature({ sigType: Multisig.SignerType.EOA, signer: signer, data: abi.encodePacked(r, s, v) });
    }

    function _twoEoaSigs(bytes32 hash, uint256 pk1, address addr1, uint256 pk2, address addr2)
        internal
        pure
        returns (Multisig.Signature[] memory sigs)
    {
        sigs = new Multisig.Signature[](2);
        Multisig.Signature memory s1 = _eoaSig(hash, pk1, addr1);
        Multisig.Signature memory s2 = _eoaSig(hash, pk2, addr2);
        if (addr1 < addr2) {
            sigs[0] = s1;
            sigs[1] = s2;
        } else {
            sigs[0] = s2;
            sigs[1] = s1;
        }
    }
}
