import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  erc20Abi,
  fallback,
  formatUnits,
  http,
  keccak256,
  parseUnits,
  zeroAddress,
} from "viem";
import type { Address, Hex } from "viem";
import { mainnet } from "viem/chains";
import { dexAbi } from "./abi";
import deployment from "./deployment.json";
import { stocks } from "./stocks";

export const DEX = deployment.address as Address;
export const EXPLORER = deployment.explorer;
export const QUOTE_TTL = 30_000;
export const client = createPublicClient({
  chain: mainnet,
  transport: fallback(
    deployment.rpcUrls.map((url) =>
      http(url, {
        batch: { wait: 20, batchSize: 50 },
        timeout: 12_000,
        retryCount: 0,
      }),
    ),
  ),
  pollingInterval: 4_000,
});
export type Fees = {
  swapAmount: bigint;
  fee: bigint;
  burnAmount: bigint;
  creatorAmount: bigint;
};
export type Quote = {
  stock: Address;
  amount: bigint;
  output: bigint;
  fees: Fees;
  version: bigint;
  decimals: number;
  at: number;
  block: bigint;
  path: Hex;
};
export type Market = {
  enabled: boolean;
  path: Hex;
  decimals?: number;
  reference?: bigint;
  priceError?: string;
  error?: string;
};
export type Snapshot = {
  block: bigint;
  at: number;
  version: bigint;
  paused: boolean;
  imd: Address;
  router: Address;
  quoter: Address;
  creator: Address;
  burnShareBps: number;
  decimals?: number;
  markets: Record<string, Market>;
  configured: boolean;
};
const read = { address: DEX, abi: dexAbi } as const;
export const same = (a?: string, b?: string) =>
  a?.toLowerCase() === b?.toLowerCase();
export const isSet = (address: Address) => !same(address, zeroAddress);
export const tokenLink = (address: string) => `${EXPLORER}/token/${address}`;
export const addressLink = (address: string) =>
  `${EXPLORER}/address/${address}`;
export const shortAddress = (address: string) =>
  `${address.slice(0, 6)}…${address.slice(-4)}`;
export const displayUnits = (amount: bigint, decimals: number, max = 6) => {
  const exact = formatUnits(amount, decimals);
  const [whole, fraction] = exact.split(".");
  if (!fraction) return whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  if (whole === "0" && amount > 0n && Number(exact) < 10 ** -max)
    return `<${10 ** -max}`;
  return `${whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",")}.${fraction.slice(0, max)}`.replace(
    /\.?0+$/,
    (match) => (match.startsWith(".") ? "" : match),
  );
};
export function parseAmount(value: string, decimals: number): bigint {
  if (!/^(?:\d+)(?:\.\d*)?$/.test(value))
    throw new Error(
      "Enter a positive IMD amount, using numbers and a decimal point.",
    );
  if ((value.split(".")[1]?.length ?? 0) > decimals)
    throw new Error(`IMD supports up to ${decimals} decimal places.`);
  const amount = parseUnits(value, decimals);
  if (amount <= 0n) throw new Error("Enter an IMD amount greater than zero.");
  if (amount >= 2n ** 256n)
    throw new Error("This amount is too large. Enter a smaller amount.");
  return amount;
}
export function minimumOutput(output: bigint, slippageBps: number) {
  if (!Number.isInteger(slippageBps) || slippageBps < 10 || slippageBps > 300)
    throw new Error("Select a slippage tolerance between 0.1% and 3%.");
  const minimum = (output * BigInt(10_000 - slippageBps)) / 10_000n;
  if (!minimum)
    throw new Error(
      "The estimated output is too small. Increase your IMD amount.",
    );
  return minimum;
}
export function routeHops(path: Hex): { token: Address; fee?: number }[] {
  const hex = path.slice(2);
  if (hex.length < 86 || (hex.length - 40) % 46 !== 0 || hex.length > 224)
    return [];
  const hops: { token: Address; fee?: number }[] = [
    { token: `0x${hex.slice(0, 40)}` },
  ];
  for (let i = 40; i < hex.length; i += 46)
    hops.push({
      fee: parseInt(hex.slice(i, i + 6), 16) / 10_000,
      token: `0x${hex.slice(i + 6, i + 46)}`,
    });
  return hops;
}
export async function verifyDeployment() {
  const [id, code] = await Promise.all([
    client.getChainId(),
    client.getCode({ address: DEX }),
  ]);
  if (id !== 1 || !code || keccak256(code) !== deployment.runtimeHash)
    throw new Error(
      "Contract verification failed. Trading is disabled. Retry the connection.",
    );
}
export async function loadSnapshot(): Promise<Snapshot> {
  await verifyDeployment();
  const block = await client.getBlockNumber({ cacheTime: 0 });
  const [version, paused, imd, router, quoter, creator, burnShareBps] =
    await Promise.all([
      client.readContract({
        ...read,
        functionName: "configVersion",
        blockNumber: block,
      }),
      client.readContract({
        ...read,
        functionName: "paused",
        blockNumber: block,
      }),
      client.readContract({ ...read, functionName: "imd", blockNumber: block }),
      client.readContract({
        ...read,
        functionName: "router",
        blockNumber: block,
      }),
      client.readContract({
        ...read,
        functionName: "quoter",
        blockNumber: block,
      }),
      client.readContract({
        ...read,
        functionName: "creator",
        blockNumber: block,
      }),
      client.readContract({
        ...read,
        functionName: "burnShareBps",
        blockNumber: block,
      }),
    ]);
  const configured =
    isSet(imd) &&
    isSet(router) &&
    isSet(creator) &&
    burnShareBps > 0 &&
    burnShareBps < 10_000;
  const decimals = isSet(imd)
    ? await client.readContract({
        address: imd,
        abi: erc20Abi,
        functionName: "decimals",
        blockNumber: block,
      })
    : undefined;
  const entries = await Promise.all(
    stocks.map(async (stock) => {
      let market: Market;
      try {
        const [path, enabled] = await client.readContract({
          ...read,
          functionName: "market",
          args: [stock.address],
          blockNumber: block,
        });
        market = { path, enabled };
        if (enabled) {
          try {
            market.decimals = await client.readContract({
              address: stock.address,
              abi: erc20Abi,
              functionName: "decimals",
              blockNumber: block,
            });
            if (configured && isSet(quoter) && decimals !== undefined) {
              const { result } = await client.simulateContract({
                ...read,
                functionName: "quoteBuy",
                args: [stock.address, parseUnits("1000", decimals)],
                blockNumber: block,
              });
              if (result[2] !== version || result[0] === 0n)
                throw new Error("No executable quote.");
              market.reference = result[0];
            }
          } catch (e) {
            market.priceError = errorMessage(e);
          }
        }
      } catch {
        market = {
          enabled: false,
          path: "0x",
          error: "Market status unavailable",
        };
      }
      return [stock.address, market] as const;
    }),
  );
  return {
    block,
    at: Date.now(),
    version,
    paused,
    imd,
    router,
    quoter,
    creator,
    burnShareBps,
    decimals,
    markets: Object.fromEntries(entries),
    configured,
  };
}
export async function getQuote(stock: Address, amount: bigint): Promise<Quote> {
  const block = await client.getBlockNumber({ cacheTime: 0 });
  const [[path, enabled], decimals, { result }, paused] = await Promise.all([
    client.readContract({
      ...read,
      functionName: "market",
      args: [stock],
      blockNumber: block,
    }),
    client.readContract({
      address: stock,
      abi: erc20Abi,
      functionName: "decimals",
      blockNumber: block,
    }),
    client.simulateContract({
      ...read,
      functionName: "quoteBuy",
      args: [stock, amount],
      blockNumber: block,
    }),
    client.readContract({
      ...read,
      functionName: "paused",
      blockNumber: block,
    }),
  ]);
  if (paused)
    throw new Error(
      "Trading is paused by the DEX owner. You can still explore stocks.",
    );
  if (!enabled)
    throw new Error(
      "This stock has no enabled route. Choose an available stock.",
    );
  if (result[0] < 2n)
    throw new Error("The quoted output is too small. Try a larger amount.");
  return {
    stock,
    amount,
    output: result[0],
    fees: result[1],
    version: result[2],
    decimals,
    at: Date.now(),
    block,
    path,
  };
}
export async function checkQuote(quote: Quote, account: Address) {
  if (Date.now() - quote.at >= QUOTE_TTL)
    throw new Error("This quote expired. Refresh and review a new quote.");
  await verifyDeployment();
  const [version, paused] = await Promise.all([
    client.readContract({ ...read, functionName: "configVersion" }),
    client.readContract({ ...read, functionName: "paused" }),
  ]);
  if (version !== quote.version)
    throw new Error(
      "The DEX configuration changed. Refresh and review a new quote.",
    );
  if (paused)
    throw new Error("Trading was paused. Your purchase was not sent.");
  const imd = await client.readContract({ ...read, functionName: "imd" });
  const [balance, allowance] = await Promise.all([
    client.readContract({
      address: imd,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [account],
    }),
    client.readContract({
      address: imd,
      abi: erc20Abi,
      functionName: "allowance",
      args: [account, DEX],
    }),
  ]);
  if (balance < quote.amount)
    throw new Error("Insufficient IMD balance. Add IMD or lower the amount.");
  return { imd, balance, allowance };
}
export type Holding = {
  address: Address;
  balance?: bigint;
  decimals?: number;
  error?: string;
};
export async function loadHoldings(account: Address): Promise<Holding[]> {
  const block = await client.getBlockNumber({ cacheTime: 0 });
  return Promise.all(
    stocks.map(async (stock) => {
      try {
        const [balance, decimals] = await Promise.all([
          client.readContract({
            address: stock.address,
            abi: erc20Abi,
            functionName: "balanceOf",
            args: [account],
            blockNumber: block,
          }),
          client.readContract({
            address: stock.address,
            abi: erc20Abi,
            functionName: "decimals",
            blockNumber: block,
          }),
        ]);
        return { address: stock.address, balance, decimals };
      } catch {
        return { address: stock.address, error: "Balance unavailable" };
      }
    }),
  );
}
export async function loadActivity(account: Address, before?: bigint) {
  const toBlock = before ?? (await client.getBlockNumber({ cacheTime: 0 }));
  const deploymentBlock = BigInt(deployment.blockNumber);
  const fromBlock =
    toBlock - 20_000n > deploymentBlock ? toBlock - 20_000n : deploymentBlock;
  const ranges: { fromBlock: bigint; toBlock: bigint }[] = [];
  for (let start = fromBlock; start <= toBlock; start += 2_000n)
    ranges.push({
      fromBlock: start,
      toBlock: start + 1_999n < toBlock ? start + 1_999n : toBlock,
    });
  const pages = await Promise.all(
    ranges.map((range) =>
      client.getContractEvents({
        address: DEX,
        abi: dexAbi,
        eventName: "StockPurchased",
        args: { buyer: account },
        ...range,
      }),
    ),
  );
  return {
    events: pages
      .flat()
      .sort(
        (a, b) =>
          Number(b.blockNumber - a.blockNumber) || b.logIndex - a.logIndex,
      ),
    fromBlock,
    toBlock,
    hasMore: fromBlock > deploymentBlock,
  };
}
export type Activity = Awaited<ReturnType<typeof loadActivity>>;
export function errorMessage(error: unknown): string {
  if (
    (typeof error === "object" &&
      error !== null &&
      "code" in error &&
      error.code === 4001) ||
    (error instanceof Error && /user rejected|user denied/i.test(error.message))
  )
    return "The wallet request was declined. You can try again when ready.";
  const messages: Record<string, string> = {
    NotConfigured:
      "The owner has not finished configuring the DEX. Trading will be available after setup.",
    QuoterNotConfigured:
      "The owner has not configured a quote provider. Quotes are unavailable.",
    MarketNotEnabled:
      "This stock has no enabled route. Choose an available stock.",
    AmountTooSmall:
      "This amount is too small to cover the fee split. Increase the IMD amount.",
    ConfigurationChanged:
      "The DEX configuration changed. Refresh and review a new quote.",
    EnforcedPause:
      "Trading is paused by the DEX owner. You can still explore stocks.",
    InsufficientLiquidity:
      "The route cannot fill this amount. Try a smaller amount.",
    InvalidQuote: "The route did not return a valid quote. Try again later.",
    DeadlineExpired:
      "The purchase deadline expired. Refresh and review a new quote.",
    InsufficientOutput:
      "The price moved beyond your slippage tolerance. Refresh the quote.",
  };
  if (error instanceof BaseError) {
    const reverted = error.walk(
      (err) => err instanceof ContractFunctionRevertedError,
    );
    if (
      reverted instanceof ContractFunctionRevertedError &&
      reverted.data?.errorName &&
      messages[reverted.data.errorName]
    )
      return messages[reverted.data.errorName];
    if (/reject|denied|4001/i.test(error.message))
      return "The wallet request was declined. You can try again when ready.";
    if (/receipt|timed out/i.test(error.message))
      return "Confirmation is taking longer than expected. Check the transaction on Etherscan before trying again.";
    return "The network could not complete this request. Check your connection and try again.";
  }
  if (error instanceof Error) return error.message;
  return "The request could not be completed. Please try again.";
}
