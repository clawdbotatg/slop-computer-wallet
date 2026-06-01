"use client";

import { useState } from "react";
import Link from "next/link";
import { Address, AddressInput } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { keccak256, stringToHex, zeroAddress } from "viem";
import { hardhat } from "viem/chains";
import { useAccount } from "wagmi";
import {
  useScaffoldEventHistory,
  useScaffoldReadContract,
  useScaffoldWriteContract,
  useTargetNetwork,
} from "~~/hooks/scaffold-eth";

const ZERO_BYTES32 = "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

const Home: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const { targetNetwork } = useTargetNetwork();
  const [signers, setSigners] = useState<string[]>([""]);
  const [threshold, setThreshold] = useState<string>("1");
  const [saltLabel, setSaltLabel] = useState<string>("");
  const [predicted, setPredicted] = useState<string>("");

  const saltHex = saltLabel ? keccak256(stringToHex(saltLabel)) : ZERO_BYTES32;

  // Factory now binds msg.sender into the effective salt to prevent front-running, so the
  // prediction depends on which account will deploy the multisig.
  const deployerForPredict = (connectedAddress ?? zeroAddress) as `0x${string}`;
  const { data: predictedAddress, refetch: refetchPredicted } = useScaffoldReadContract({
    contractName: "MultisigFactory",
    functionName: "getMultisigAddress",
    args: [deployerForPredict, saltHex],
  });

  const { writeContractAsync: writeFactoryAsync, isMining } = useScaffoldWriteContract({
    contractName: "MultisigFactory",
  });

  const { data: createdEvents, isLoading: eventsLoading } = useScaffoldEventHistory({
    contractName: "MultisigFactory",
    eventName: "MultisigCreated",
    watch: true,
    fromBlock: 0n,
  });

  const validSigners = signers.map(s => s.trim()).filter(s => /^0x[a-fA-F0-9]{40}$/.test(s));
  const thresholdNum = Number(threshold);
  const canDeploy =
    validSigners.length > 0 &&
    thresholdNum >= 1 &&
    thresholdNum <= validSigners.length &&
    validSigners.length === signers.filter(s => s.trim()).length;

  const updateSigner = (i: number, value: string) => {
    setSigners(prev => prev.map((s, idx) => (idx === i ? value : s)));
  };

  const handlePredict = async () => {
    const r = await refetchPredicted();
    if (r.data) setPredicted(r.data);
  };

  const handleDeploy = async () => {
    if (!canDeploy) return;
    try {
      await writeFactoryAsync({
        // args: accounts, passkeyQxs, passkeyQys, credentialIdHashes, threshold, salt
        functionName: "createMultisig",
        args: [validSigners as `0x${string}`[], [], [], [], BigInt(thresholdNum), saltHex],
      });
      refetchPredicted();
    } catch (e) {
      console.error("deploy error", e);
    }
  };

  return (
    <div className="flex flex-col items-center pt-10 px-4">
      <div className="max-w-2xl w-full">
        <h1 className="text-4xl font-bold text-center mb-2">slop computer wallet</h1>
        <p className="text-center text-lg opacity-70 mb-8">
          A simple multisig with EOA + passkey signers, ERC-1271 ready.
        </p>

        <div className="bg-base-200 rounded-3xl p-6 mb-8">
          <h2 className="text-2xl font-semibold mb-4">Deploy a new multisig</h2>

          <div className="space-y-4">
            <div>
              <label className="text-sm font-medium mb-1 block">EOA signers</label>
              <div className="space-y-2">
                {signers.map((s, i) => (
                  <div key={i} className="flex gap-2 items-center">
                    <div className="flex-1">
                      <AddressInput
                        value={s}
                        onChange={v => updateSigner(i, v)}
                        placeholder={`Signer ${i + 1} address`}
                      />
                    </div>
                    {signers.length > 1 && (
                      <button
                        className="btn btn-square btn-sm btn-ghost"
                        onClick={() => setSigners(prev => prev.filter((_, idx) => idx !== i))}
                      >
                        ✕
                      </button>
                    )}
                  </div>
                ))}
                <div className="flex gap-2">
                  <button className="btn btn-xs" onClick={() => setSigners(prev => [...prev, ""])}>
                    + add signer
                  </button>
                  {connectedAddress && (
                    <button
                      className="btn btn-xs btn-ghost"
                      onClick={() =>
                        setSigners(prev =>
                          prev.includes(connectedAddress)
                            ? prev
                            : prev[prev.length - 1] === ""
                              ? [...prev.slice(0, -1), connectedAddress]
                              : [...prev, connectedAddress],
                        )
                      }
                    >
                      + use connected
                    </button>
                  )}
                </div>
                <p className="text-xs opacity-60">
                  Passkey signers can be added later by the multisig itself via execTransaction.
                </p>
              </div>
            </div>

            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="text-sm font-medium mb-1 block">Threshold</label>
                <input
                  type="number"
                  min="1"
                  className="input input-bordered w-full"
                  value={threshold}
                  onChange={e => setThreshold(e.target.value)}
                />
                <p className="text-xs opacity-60 mt-1">
                  Sigs required out of {validSigners.length || "?"} signers
                </p>
              </div>
              <div>
                <label className="text-sm font-medium mb-1 block">Salt label</label>
                <input
                  type="text"
                  className="input input-bordered w-full"
                  placeholder="anything unique"
                  value={saltLabel}
                  onChange={e => setSaltLabel(e.target.value)}
                />
                <p className="text-xs opacity-60 mt-1 break-all">{saltHex.slice(0, 18)}…</p>
              </div>
            </div>

            <div className="flex gap-2">
              <button className="btn btn-secondary flex-1" onClick={handlePredict}>
                Predict address
              </button>
              <button className="btn btn-primary flex-1" onClick={handleDeploy} disabled={!canDeploy || isMining}>
                {isMining ? <span className="loading loading-spinner loading-sm" /> : "Deploy multisig"}
              </button>
            </div>

            {(predicted || predictedAddress) && (
              <div className="bg-base-100 rounded-xl p-4">
                <p className="text-sm font-medium mb-2">Predicted address (for this salt):</p>
                <Address
                  address={(predicted || predictedAddress) as `0x${string}`}
                  chain={targetNetwork}
                  blockExplorerAddressLink={
                    targetNetwork.id === hardhat.id
                      ? `/blockexplorer/address/${predicted || predictedAddress}`
                      : undefined
                  }
                />
              </div>
            )}
          </div>
        </div>

        <div className="bg-base-200 rounded-3xl p-6">
          <h2 className="text-2xl font-semibold mb-4">Deployed multisigs</h2>

          {eventsLoading ? (
            <div className="flex justify-center py-8">
              <span className="loading loading-spinner loading-lg" />
            </div>
          ) : createdEvents && createdEvents.length > 0 ? (
            <div className="space-y-3">
              {createdEvents.map((ev, i) => (
                <Link
                  key={`${ev.transactionHash}-${ev.logIndex}-${i}`}
                  href={`/${ev.args.multisig}`}
                  className="bg-base-100 rounded-xl p-4 flex justify-between items-center hover:bg-base-300 transition-colors"
                >
                  <Address
                    address={ev.args.multisig}
                    chain={targetNetwork}
                    blockExplorerAddressLink={
                      targetNetwork.id === hardhat.id ? `/blockexplorer/address/${ev.args.multisig}` : undefined
                    }
                  />
                  <div className="text-sm opacity-70">threshold {ev.args.threshold?.toString()}</div>
                </Link>
              ))}
            </div>
          ) : (
            <p className="text-center py-8 opacity-60">No multisigs deployed yet</p>
          )}
        </div>
      </div>
    </div>
  );
};

export default Home;
