"use client";

import { useMemo, useState } from "react";
import { useParams } from "next/navigation";
import Link from "next/link";
import { Address, AddressInput, Balance } from "@scaffold-ui/components";
import type { NextPage } from "next";
import {
  encodeAbiParameters,
  encodeFunctionData,
  isAddress,
  keccak256,
  parseAbiParameters,
  parseEther,
  zeroAddress,
} from "viem";
import { hardhat } from "viem/chains";
import { useAccount, useReadContract, useSignMessage, useWriteContract } from "wagmi";
import deployedContracts from "~~/contracts/deployedContracts";
import { useTargetNetwork } from "~~/hooks/scaffold-eth";

const MULTISIG_ABI_FALLBACK = [] as const;

function useMultisigAbi() {
  const { targetNetwork } = useTargetNetwork();
  return useMemo(() => {
    const chainContracts = (deployedContracts as any)[targetNetwork.id];
    return chainContracts?.Multisig?.abi ?? MULTISIG_ABI_FALLBACK;
  }, [targetNetwork.id]);
}

type SignatureEntry = {
  sigType: 0 | 1; // 0 = EOA, 1 = passkey (UI only supports EOA in v1)
  signer: `0x${string}`;
  data: `0x${string}`;
};

const MultisigPage: NextPage = () => {
  const params = useParams<{ address: string }>();
  const multisig = params.address as `0x${string}`;
  const { address: connectedAddress } = useAccount();
  const { targetNetwork } = useTargetNetwork();
  const abi = useMultisigAbi();
  const { signMessageAsync } = useSignMessage();
  const { writeContractAsync, isPending: isExecuting } = useWriteContract();

  // === Reads ===
  const { data: signersList } = useReadContract({
    address: multisig,
    abi,
    functionName: "getSigners",
  });
  const { data: thresholdData } = useReadContract({
    address: multisig,
    abi,
    functionName: "threshold",
  });
  const { data: nonceData, refetch: refetchNonce } = useReadContract({
    address: multisig,
    abi,
    functionName: "nonce",
  });

  const threshold = thresholdData ? Number(thresholdData) : 0;
  const nonce = nonceData ? BigInt(nonceData.toString()) : 0n;

  // === Transaction form ===
  const [target, setTarget] = useState<string>("");
  const [valueEth, setValueEth] = useState<string>("0");
  const [callData, setCallData] = useState<string>("0x");
  const [deadlineMins, setDeadlineMins] = useState<string>("60");
  const [signatures, setSignatures] = useState<SignatureEntry[]>([]);

  const deadlineTs = useMemo(() => {
    const mins = Number(deadlineMins);
    if (!mins || mins < 1) return 0n;
    return BigInt(Math.floor(Date.now() / 1000) + mins * 60);
  }, [deadlineMins]);

  const valueWei = useMemo(() => {
    try {
      return parseEther(valueEth || "0");
    } catch {
      return 0n;
    }
  }, [valueEth]);

  const dataHex = (callData.startsWith("0x") ? callData : `0x${callData}`) as `0x${string}`;

  // Compute the same hash as the contract's getExecHash off-chain.
  const execHash = useMemo(() => {
    if (!isAddress(target) || !deadlineTs) return null;
    return keccak256(
      encodeAbiParameters(parseAbiParameters("uint256, address, uint256, uint256, address, uint256, bytes32"), [
        BigInt(targetNetwork.id),
        multisig,
        nonce,
        deadlineTs,
        target as `0x${string}`,
        valueWei,
        keccak256(dataHex),
      ]),
    );
  }, [target, deadlineTs, multisig, nonce, valueWei, dataHex, targetNetwork.id]);

  const sigBy = (a: string) => signatures.find(s => s.signer.toLowerCase() === a.toLowerCase());
  const sortedSigs = useMemo(
    () => [...signatures].sort((a, b) => (a.signer.toLowerCase() < b.signer.toLowerCase() ? -1 : 1)),
    [signatures],
  );

  const handleSign = async () => {
    if (!execHash || !connectedAddress) return;
    try {
      // Sign the raw hash. wagmi's signMessage uses personal_sign which prefixes; we want the raw digest signed.
      // We re-derive what would be ecrecover'able on the contract: contract uses ECDSA.recover(hash, sig).
      // OZ's ECDSA.recover does NOT add the personal_sign prefix; it expects sig over `hash` directly.
      // signMessage with `raw` passes hash directly.
      const sig = (await signMessageAsync({ message: { raw: execHash } })) as `0x${string}`;
      const signer = connectedAddress as `0x${string}`;
      setSignatures(prev => [
        ...prev.filter(s => s.signer.toLowerCase() !== signer.toLowerCase()),
        { sigType: 0, signer, data: sig },
      ]);
    } catch (e) {
      console.error("sign error", e);
    }
  };

  const handleExecute = async () => {
    if (!execHash || sortedSigs.length < threshold) return;
    try {
      await writeContractAsync({
        address: multisig,
        abi,
        functionName: "execTransaction",
        args: [
          target as `0x${string}`,
          valueWei,
          dataHex,
          deadlineTs,
          sortedSigs.map(s => ({ sigType: s.sigType, signer: s.signer, data: s.data })),
        ],
      });
      setSignatures([]);
      refetchNonce();
    } catch (e) {
      console.error("execute error", e);
    }
  };

  // ===== Quick presets for admin calls =====
  const buildAdminCall = (preset: "addEoa" | "remove" | "changeThreshold", arg: string) => {
    if (preset === "addEoa" && isAddress(arg)) {
      setTarget(multisig);
      setValueEth("0");
      setCallData(encodeFunctionData({ abi, functionName: "addEoaSigner", args: [arg as `0x${string}`] }));
    } else if (preset === "remove" && isAddress(arg)) {
      setTarget(multisig);
      setValueEth("0");
      setCallData(encodeFunctionData({ abi, functionName: "removeSigner", args: [arg as `0x${string}`] }));
    } else if (preset === "changeThreshold" && arg) {
      const n = BigInt(arg);
      setTarget(multisig);
      setValueEth("0");
      setCallData(encodeFunctionData({ abi, functionName: "changeThreshold", args: [n] }));
    }
    setSignatures([]);
  };

  const [adminAddr, setAdminAddr] = useState("");
  const [adminThreshold, setAdminThreshold] = useState("");

  return (
    <div className="flex flex-col items-center pt-10 px-4 pb-16">
      <div className="max-w-3xl w-full space-y-6">
        <Link href="/" className="text-sm opacity-70 hover:opacity-100">
          ← back to factory
        </Link>

        {/* Info card */}
        <div className="bg-base-200 rounded-3xl p-6">
          <h1 className="text-2xl font-bold mb-2">Multisig</h1>
          <Address
            address={multisig}
            chain={targetNetwork}
            blockExplorerAddressLink={
              targetNetwork.id === hardhat.id ? `/blockexplorer/address/${multisig}` : undefined
            }
          />
          <div className="grid grid-cols-3 gap-4 mt-4">
            <div className="bg-base-100 rounded-xl p-3">
              <p className="text-xs opacity-60">Balance</p>
              <Balance address={multisig} />
            </div>
            <div className="bg-base-100 rounded-xl p-3">
              <p className="text-xs opacity-60">Threshold</p>
              <p className="font-mono text-xl">
                {threshold}
                <span className="opacity-60 text-base"> / {signersList ? (signersList as string[]).length : "?"}</span>
              </p>
            </div>
            <div className="bg-base-100 rounded-xl p-3">
              <p className="text-xs opacity-60">Nonce</p>
              <p className="font-mono text-xl">{nonce.toString()}</p>
            </div>
          </div>

          <div className="mt-4">
            <p className="text-sm opacity-70 mb-2">Signers</p>
            <div className="space-y-1">
              {(signersList as string[] | undefined)?.map(s => (
                <div key={s} className="bg-base-100 rounded-lg p-2 flex justify-between items-center">
                  <Address
                    address={s as `0x${string}`}
                    chain={targetNetwork}
                    blockExplorerAddressLink={
                      targetNetwork.id === hardhat.id ? `/blockexplorer/address/${s}` : undefined
                    }
                  />
                  {sigBy(s) && <span className="badge badge-success badge-sm">signed</span>}
                </div>
              )) ?? <p className="opacity-60 text-sm">loading…</p>}
            </div>
          </div>
        </div>

        {/* Propose & sign */}
        <div className="bg-base-200 rounded-3xl p-6">
          <h2 className="text-xl font-semibold mb-4">Propose transaction</h2>

          <div className="space-y-3">
            <div>
              <label className="text-sm font-medium mb-1 block">Target</label>
              <AddressInput value={target} onChange={setTarget} placeholder="0x... (or this multisig for admin)" />
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="text-sm font-medium mb-1 block">Value (ETH)</label>
                <input
                  type="text"
                  className="input input-bordered w-full"
                  value={valueEth}
                  onChange={e => setValueEth(e.target.value)}
                />
              </div>
              <div>
                <label className="text-sm font-medium mb-1 block">Expires in (mins)</label>
                <input
                  type="number"
                  min="1"
                  className="input input-bordered w-full"
                  value={deadlineMins}
                  onChange={e => setDeadlineMins(e.target.value)}
                />
              </div>
            </div>
            <div>
              <label className="text-sm font-medium mb-1 block">Calldata</label>
              <input
                type="text"
                className="input input-bordered w-full font-mono text-sm"
                value={callData}
                onChange={e => setCallData(e.target.value)}
                placeholder="0x"
              />
            </div>

            <details className="bg-base-100 rounded-xl p-3">
              <summary className="cursor-pointer text-sm font-medium">Quick admin actions (fills the form)</summary>
              <div className="mt-3 space-y-2">
                <div className="flex gap-2 items-center">
                  <AddressInput value={adminAddr} onChange={setAdminAddr} placeholder="signer address" />
                  <button className="btn btn-xs" onClick={() => buildAdminCall("addEoa", adminAddr)}>
                    add EOA
                  </button>
                  <button className="btn btn-xs" onClick={() => buildAdminCall("remove", adminAddr)}>
                    remove
                  </button>
                </div>
                <div className="flex gap-2 items-center">
                  <input
                    type="number"
                    min="1"
                    className="input input-bordered input-sm"
                    placeholder="new threshold"
                    value={adminThreshold}
                    onChange={e => setAdminThreshold(e.target.value)}
                  />
                  <button className="btn btn-xs" onClick={() => buildAdminCall("changeThreshold", adminThreshold)}>
                    change threshold
                  </button>
                </div>
              </div>
            </details>

            {execHash && (
              <div className="bg-base-100 rounded-xl p-3">
                <p className="text-xs opacity-60">Hash to sign</p>
                <p className="font-mono text-xs break-all">{execHash}</p>
              </div>
            )}
          </div>
        </div>

        {/* Collect signatures */}
        <div className="bg-base-200 rounded-3xl p-6">
          <h2 className="text-xl font-semibold mb-1">Collect signatures</h2>
          <p className="text-sm opacity-70 mb-4">
            {signatures.length} / {threshold} collected
          </p>

          <div className="flex gap-2 flex-wrap">
            <button
              className="btn btn-primary"
              onClick={handleSign}
              disabled={!execHash || !connectedAddress || !(signersList as string[] | undefined)?.includes(connectedAddress ?? zeroAddress)}
            >
              Sign with connected wallet
            </button>
            {connectedAddress && !(signersList as string[] | undefined)?.includes(connectedAddress) && (
              <p className="text-xs opacity-60 self-center">connected address is not a signer</p>
            )}
          </div>

          {signatures.length > 0 && (
            <div className="mt-4 space-y-2">
              {sortedSigs.map(s => (
                <div key={s.signer} className="bg-base-100 rounded-lg p-2 flex justify-between items-center gap-2">
                  <Address
                    address={s.signer}
                    chain={targetNetwork}
                    blockExplorerAddressLink={
                      targetNetwork.id === hardhat.id ? `/blockexplorer/address/${s.signer}` : undefined
                    }
                  />
                  <span className="font-mono text-xs opacity-60 truncate flex-1">{s.data.slice(0, 22)}…</span>
                  <button
                    className="btn btn-xs btn-ghost"
                    onClick={() => setSignatures(prev => prev.filter(x => x.signer !== s.signer))}
                  >
                    remove
                  </button>
                </div>
              ))}
            </div>
          )}

          <div className="mt-4">
            <button
              className="btn btn-success w-full"
              onClick={handleExecute}
              disabled={!execHash || signatures.length < threshold || isExecuting}
            >
              {isExecuting ? <span className="loading loading-spinner loading-sm" /> : `Execute (${signatures.length}/${threshold})`}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
};

export default MultisigPage;
