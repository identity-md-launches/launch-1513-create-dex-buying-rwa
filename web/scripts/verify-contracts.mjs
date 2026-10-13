import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createPublicClient, http, keccak256, toHex } from "viem";
import { mainnet } from "viem/chains";
const root = new URL("../../", import.meta.url);
const abi = JSON.parse(
  execFileSync("forge", ["inspect", "IMDStockDex", "abi", "--json"], {
    cwd: root,
    encoding: "utf8",
  }),
);
const runtime = execFileSync(
  "forge",
  ["inspect", "IMDStockDex", "deployedBytecode"],
  { cwd: root, encoding: "utf8" },
).trim();
const canonical = (v) =>
  Array.isArray(v)
    ? v.map(canonical)
    : v && typeof v === "object"
      ? Object.fromEntries(
          Object.keys(v)
            .sort()
            .map((k) => [k, canonical(v[k])]),
        )
      : v;
const pinned = JSON.parse(
  readFileSync(new URL("../src/deployment.json", import.meta.url)),
);
const hash = keccak256(toHex(JSON.stringify(canonical(abi))));
if (hash.slice(2) !== pinned.abiHash) throw new Error(`ABI mismatch: ${hash}`);
const runtimeHash = keccak256(runtime);
if (runtimeHash !== pinned.runtimeHash)
  throw new Error(`Runtime mismatch: ${runtimeHash}`);
const { dexAbi: bundled } = await import("../src/abi.ts");
if (keccak256(toHex(JSON.stringify(canonical(bundled)))) !== hash) {
  throw new Error("Bundled ABI differs from compiled source");
}
const client = createPublicClient({
  chain: mainnet,
  transport: http(pinned.rpcUrls[0], { timeout: 15000, retryCount: 1 }),
});
const chainId = await client.getChainId();
const code = await client.getCode({ address: pinned.address });
if (chainId !== 1 || !code || keccak256(code) !== runtimeHash)
  throw new Error("Live runtime / chain mismatch");
const state = Object.fromEntries(
  await Promise.all(
    [
      "paused",
      "configVersion",
      "imd",
      "router",
      "quoter",
      "creator",
      "burnShareBps",
    ].map(async (functionName) => [
      functionName,
      String(
        await client.readContract({
          address: pinned.address,
          abi,
          functionName,
        }),
      ),
    ]),
  ),
);
const report = {
  chainId,
  sourceCommit: pinned.sourceCommit,
  address: pinned.address,
  abiHash: hash,
  runtimeHash,
  checkedAt: new Date().toISOString(),
  block: String(await client.getBlockNumber()),
  state,
};
console.log(JSON.stringify(report, null, 2));
if (process.argv.includes("--record"))
  writeFileSync(
    new URL("../../artifacts/contract-verification.json", import.meta.url),
    JSON.stringify(report, null, 2) + "\n",
  );
