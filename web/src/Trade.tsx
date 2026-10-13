import { useCallback, useEffect, useRef, useState } from "react";
import {
  ArrowDown,
  ArrowRight,
  CheckCircle2,
  ChevronDown,
  CircleHelp,
  Clock3,
  RefreshCw,
  Route,
  Settings2,
  ShieldCheck,
  Wallet,
} from "lucide-react";
import {
  createWalletClient,
  custom,
  erc20Abi,
  formatUnits,
  parseEventLogs,
} from "viem";
import type { Address, Hash } from "viem";
import { mainnet } from "viem/chains";
import { dexAbi } from "./abi";
import {
  checkQuote,
  client,
  DEX,
  displayUnits,
  errorMessage,
  EXPLORER,
  getQuote,
  isSet,
  minimumOutput,
  parseAmount,
  QUOTE_TTL,
  routeHops,
  same,
  shortAddress,
} from "./chain";
import type { Quote, Snapshot } from "./chain";
import type { Stock } from "./stocks";
import { stocks } from "./stocks";
import { AddressDisplay, ExternalLink, Modal, StockMark } from "./components";
import { readLocal, saveLocal } from "./hooks";
import type { useWallet } from "./hooks";

type Props = {
  stock: Stock;
  onSelect: (stock: Stock) => void;
  snapshot?: Snapshot;
  networkError: string;
  wallet: ReturnType<typeof useWallet>;
  onConnect: () => void;
  refresh: () => Promise<void>;
  onConfirmed: () => void;
};
type Pending = {
  hash: Hash;
  kind: "approval" | "purchase";
  account: Address;
  token: Address;
  stock: Address;
  amount: string;
  approvalAmount?: string;
};
export function Trade({
  stock,
  onSelect,
  snapshot,
  networkError,
  wallet,
  onConnect,
  refresh,
  onConfirmed,
}: Props) {
  const [amount, setAmount] = useState("1000");
  const [slippage, setSlippage] = useState(50);
  const [auto, setAuto] = useState(true);
  const [settings, setSettings] = useState(false);
  const [quote, setQuote] = useState<Quote>();
  const [quoteError, setQuoteError] = useState("");
  const [quoting, setQuoting] = useState(false);
  const [quoteTick, setQuoteTick] = useState(0);
  const [now, setNow] = useState(Date.now());
  const [balance, setBalance] = useState<bigint>();
  const [allowance, setAllowance] = useState<bigint>();
  const [balanceError, setBalanceError] = useState("");
  const [review, setReview] = useState<Quote>();
  const [reviewApproval, setReviewApproval] = useState(false);
  const activeAccount = useRef(wallet.account);
  activeAccount.current = wallet.account;
  const [busy, setBusy] = useState(false);
  const [step, setStep] = useState("");
  const [txError, setTxError] = useState("");
  const [success, setSuccess] = useState("");
  const [pending, setPending] = useState<Pending>();
  const [lastHash, setLastHash] = useState<Hash>();
  const [routeNames, setRouteNames] = useState<Record<string, string>>({});
  const sequence = useRef(0);
  const market = snapshot?.markets[stock.address];
  const configured = !!snapshot?.configured;
  const wrongChain = !!wallet.account && wallet.chainId !== 1;
  const decimals = snapshot?.decimals;
  let inputError = "";
  let parsed = 0n;
  if (decimals !== undefined) {
    try {
      parsed = parseAmount(amount, decimals);
    } catch (e) {
      inputError = errorMessage(e);
    }
  }
  const autoRef = useRef(auto);
  autoRef.current = auto;
  const previousSnapshot = useRef<number | undefined>(undefined);
  useEffect(() => {
    const at = snapshot?.at;
    if (at === undefined || at === previousSnapshot.current) return;
    const hadSnapshot = previousSnapshot.current !== undefined;
    previousSnapshot.current = at;
    if (hadSnapshot && autoRef.current) setQuoteTick((tick) => tick + 1);
  }, [snapshot?.at]);
  const version = snapshot?.version;
  const unquotable = !snapshot
    ? "Connecting to Ethereum…"
    : networkError
      ? "Live network data is unavailable. Retry the connection."
      : !configured
        ? "The DEX owner is completing setup."
        : snapshot.paused
          ? "Trading is paused by the DEX owner."
          : !isSet(snapshot.quoter)
            ? "A quote provider has not been configured."
            : market?.error
              ? "Market status is unavailable. Retry the connection."
              : !market?.enabled
                ? "This stock is not yet listed on the DEX."
                : "";
  const refreshBalance = useCallback(async () => {
    if (!wallet.account || !snapshot?.imd || !isSet(snapshot.imd)) {
      setBalance(undefined);
      setAllowance(undefined);
      return;
    }
    const account = wallet.account;
    const [b, a] = await Promise.all([
      client.readContract({
        address: snapshot.imd,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [account],
      }),
      client.readContract({
        address: snapshot.imd,
        abi: erc20Abi,
        functionName: "allowance",
        args: [account, DEX],
      }),
    ]);
    return { balance: b, allowance: a };
  }, [wallet.account, snapshot?.imd]);
  useEffect(() => {
    let active = true;
    setBalance(undefined);
    setAllowance(undefined);
    setBalanceError("");
    void refreshBalance()
      .then((value) => {
        if (active && value) {
          setBalance(value.balance);
          setAllowance(value.allowance);
        }
      })
      .catch(() => {
        if (active) setBalanceError("Balance unavailable. Refresh to retry.");
      });
    return () => {
      active = false;
    };
  }, [refreshBalance, snapshot?.at, quoteTick]);
  useEffect(() => {
    setReview(undefined);
    setTxError("");
    setSuccess("");
    setLastHash(undefined);
    const saved = wallet.account
      ? readLocal<Pending | undefined>(
          `imd-pending-${wallet.account.toLowerCase()}`,
          undefined,
        )
      : undefined;
    setPending(
      saved &&
        same(saved.account, wallet.account) &&
        /^0x[0-9a-f]{64}$/i.test(saved.hash)
        ? saved
        : undefined,
    );
  }, [wallet.account, wallet.chainId]);
  useEffect(() => {
    const id = ++sequence.current;
    setQuote(undefined);
    setQuoteError("");
    if (unquotable || parsed <= 0n) {
      setQuoting(false);
      return;
    }
    setQuoting(true);
    const timer = setTimeout(() => {
      void getQuote(stock.address, parsed)
        .then((next) => {
          if (id !== sequence.current) return;
          if (next.version !== version) {
            void refresh();
            throw new Error("Configuration changed. Refreshing the quote…");
          }
          setQuote(next);
        })
        .catch((e) => {
          if (id === sequence.current) setQuoteError(errorMessage(e));
        })
        .finally(() => {
          if (id === sequence.current) setQuoting(false);
        });
    }, 350);
    return () => {
      clearTimeout(timer);
      sequence.current++;
    };
  }, [stock.address, parsed, unquotable, version, quoteTick, refresh]);
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
  useEffect(() => {
    let active = true;
    const tokens = routeHops(market?.path ?? "0x").map((h) => h.token);
    void Promise.all(
      tokens.map(async (address) => {
        try {
          return [
            address,
            await client.readContract({
              address,
              abi: erc20Abi,
              functionName: "symbol",
            }),
          ] as const;
        } catch {
          return [address, shortAddress(address)] as const;
        }
      }),
    ).then((entries) => {
      if (active) setRouteNames(Object.fromEntries(entries));
    });
    return () => {
      active = false;
    };
  }, [market?.path]);
  const age = quote ? now - quote.at : Infinity;
  const expired = age >= QUOTE_TTL;
  const insufficient = balance !== undefined && parsed > balance;
  const needApproval = allowance !== undefined && allowance < parsed;
  const route = routeHops(market?.path ?? "0x");
  function renew() {
    setQuoteTick((t) => t + 1);
    void refresh();
  }
  function startReview() {
    setTxError("");
    setSuccess("");
    if (!quote || expired) {
      renew();
      return;
    }
    setReviewApproval(needApproval);
    setReview(quote);
  }
  function remember(value: Pending) {
    saveLocal(`imd-pending-${value.account.toLowerCase()}`, value);
    if (same(activeAccount.current, value.account)) setPending(value);
  }
  async function settle(p: Pending, wait = true) {
    setStep("Waiting for confirmation…");
    setLastHash(p.hash);
    const receipt = wait
      ? await client.waitForTransactionReceipt({
          hash: p.hash,
          confirmations: 1,
          timeout: 120_000,
          onReplaced: ({ transaction }) => {
            p = { ...p, hash: transaction.hash };
            remember(p);
            setLastHash(transaction.hash);
          },
        })
      : await client.getTransactionReceipt({ hash: p.hash });
    // A receipt proves completion; do not clear an unresolved transaction on network failure.
    saveLocal(`imd-pending-${p.account.toLowerCase()}`, null);
    if (!same(activeAccount.current, p.account)) {
      onConfirmed();
      return;
    }
    setPending(undefined);
    if (receipt.status !== "success")
      throw new Error(
        "The transaction reverted. No purchase completed. Refresh the quote before trying again.",
      );
    const matched =
      p.kind === "purchase"
        ? parseEventLogs({
            abi: dexAbi,
            eventName: "StockPurchased",
            logs: receipt.logs,
          }).some(
            (log) =>
              same(log.address, DEX) &&
              same(log.args.buyer, p.account) &&
              same(log.args.stock, p.stock) &&
              log.args.grossIMD.toString() === p.amount,
          )
        : parseEventLogs({
            abi: erc20Abi,
            eventName: "Approval",
            logs: receipt.logs,
          }).some(
            (log) =>
              same(log.address, p.token) &&
              same(log.args.owner, p.account) &&
              same(log.args.spender, DEX) &&
              log.args.value.toString() === p.approvalAmount,
          );
    if (!matched)
      throw new Error(
        "The transaction was replaced or cancelled without the expected action. Refresh and review before trying again.",
      );
    setReview(undefined);
    setStep("");
    if (p.kind === "approval")
      setSuccess(
        "IMD approval confirmed. Review a fresh quote to complete your purchase.",
      );
    else {
      setSuccess("Purchase confirmed. Your stock tokens are in your wallet.");
      onConfirmed();
    }
    renew();
  }
  async function execute() {
    if (busy || pending || !review || !wallet.account || !wallet.provider)
      return;
    setBusy(true);
    setTxError("");
    setSuccess("");
    const account = wallet.account;
    const session = wallet.session.current;
    const reviewed = review;
    try {
      setStep("Checking your purchase…");
      await wallet.assertSession(account, session);
      const checked = await checkQuote(reviewed, account);
      if (checked.allowance < reviewed.amount !== reviewApproval)
        throw new Error(
          "Your spending allowance changed. Close this review and review the action again.",
        );
      const w = createWalletClient({
        account,
        chain: mainnet,
        transport: custom(wallet.provider),
      });
      let hash: Hash;
      let kind: Pending["kind"];
      let approvalAmount: bigint | undefined;
      if (checked.allowance < reviewed.amount) {
        kind = "approval";
        // Reset existing non-zero allowance first for ERC-20s that require it. Never grant unlimited approval.
        approvalAmount = checked.allowance > 0n ? 0n : reviewed.amount;
        const { request } = await client.simulateContract({
          address: checked.imd,
          abi: erc20Abi,
          functionName: "approve",
          args: [DEX, approvalAmount],
          account,
        });
        await wallet.assertSession(account, session);
        setStep(
          approvalAmount === 0n
            ? "Confirm allowance reset in your wallet…"
            : "Confirm exact IMD approval in your wallet…",
        );
        hash = await w.writeContract(request);
      } else {
        kind = "purchase";
        const minimum = minimumOutput(reviewed.output, slippage);
        const latest = await client.getBlock();
        const { request } = await client.simulateContract({
          address: DEX,
          abi: dexAbi,
          functionName: "buyStock",
          args: [
            reviewed.stock,
            reviewed.amount,
            minimum,
            latest.timestamp + 300n,
            reviewed.version,
          ],
          account,
        });
        await wallet.assertSession(account, session);
        if (Date.now() - reviewed.at >= QUOTE_TTL)
          throw new Error(
            "This quote expired during validation. Refresh and review again.",
          );
        setStep("Confirm purchase in your wallet…");
        hash = await w.writeContract(request);
      }
      const p = {
        hash,
        kind,
        account,
        token: checked.imd,
        stock: reviewed.stock,
        amount: reviewed.amount.toString(),
        approvalAmount: approvalAmount?.toString(),
      };
      remember(p);
      await settle(p);
    } catch (e) {
      if (wallet.session.current === session) setTxError(errorMessage(e));
    } finally {
      setBusy(false);
      setStep("");
    }
  }
  async function checkPending() {
    if (!pending || busy) return;
    setBusy(true);
    setTxError("");
    try {
      await settle(pending, false);
    } catch (e) {
      setTxError(errorMessage(e));
    } finally {
      setBusy(false);
      setStep("");
    }
  }
  const reviewExpired = !!review && now - review.at >= QUOTE_TTL;
  const reviewChanged = !!review && review.version !== snapshot?.version;
  const canTrade =
    !!quote &&
    !expired &&
    !unquotable &&
    !insufficient &&
    !inputError &&
    balance !== undefined &&
    allowance !== undefined &&
    !balanceError;
  const buttonLabel = !wallet.account
    ? "Connect wallet to buy"
    : wrongChain
      ? "Switch to Ethereum"
      : pending
        ? "Check confirmation"
        : unquotable
          ? snapshot?.paused
            ? "Trading paused"
            : market?.enabled
              ? "Trading unavailable"
              : "Stock unavailable"
          : inputError
            ? "Enter an IMD amount"
            : insufficient
              ? "Insufficient IMD"
              : quoting
                ? "Getting quote…"
                : quoteError
                  ? "Retry quote"
                  : expired
                    ? "Refresh quote"
                    : needApproval
                      ? "Review IMD approval"
                      : "Review purchase";
  return (
    <section id="trade" className="trade-panel" aria-labelledby="trade-title">
      <div className="section-title">
        <h2 id="trade-title">Buy stock</h2>
        <button
          className={`icon-button ${settings ? "active" : ""}`}
          aria-label="Trade settings"
          aria-expanded={settings}
          onClick={() => setSettings(!settings)}
        >
          <Settings2 size={19} />
        </button>
      </div>
      {settings && (
        <div className="trade-settings">
          <label htmlFor="slippage">Slippage tolerance</label>
          <select
            id="slippage"
            value={slippage}
            onChange={(e) => setSlippage(Number(e.target.value))}
          >
            <option value={10}>0.1%</option>
            <option value={50}>0.5%</option>
            <option value={100}>1%</option>
            <option value={300}>3%</option>
          </select>
          <p className="quiet">
            Your purchase reverts if output falls below the minimum.
          </p>
          <label className="check-label">
            <input
              type="checkbox"
              checked={auto}
              onChange={(e) => {
                setAuto(e.target.checked);
                if (e.target.checked) setQuoteTick((tick) => tick + 1);
              }}
            />
            Refresh quotes automatically
          </label>
        </div>
      )}
      <div className="pay-field">
        <div className="field-label">
          <label htmlFor="pay-amount">You pay</label>
          <span className="quiet">
            Balance:{" "}
            {balance !== undefined && decimals !== undefined
              ? displayUnits(balance, decimals, 4)
              : wallet.account
                ? "Unavailable"
                : "Not connected"}
          </span>
        </div>
        <div className="amount-line">
          <input
            id="pay-amount"
            name="amount"
            inputMode="decimal"
            autoComplete="off"
            type="text"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            aria-invalid={!!inputError}
            aria-describedby="amount-error"
          />
          <span className="token-chip">
            <span className="imd-dot" aria-hidden="true">
              i
            </span>
            IMD
          </span>
        </div>
        <div className="field-label">
          <span className="quiet">Identity.md</span>
          <button
            className="text-button"
            disabled={balance === undefined || decimals === undefined}
            onClick={() => {
              if (balance !== undefined && decimals !== undefined)
                setAmount(formatUnits(balance, decimals));
            }}
          >
            Use max
          </button>
        </div>
      </div>
      <div id="amount-error" className="inline-error">
        {inputError}
      </div>
      <div className="swap-direction" aria-hidden="true">
        <ArrowDown size={18} />
      </div>
      <div className="receive-field">
        <div className="field-label">
          <label htmlFor="receive-stock">You receive</label>
          <span className="quiet">Estimated</span>
        </div>
        <div className="receive-stock">
          <StockMark stock={stock} small />
          <div className="stock-select">
            <select
              id="receive-stock"
              value={stock.symbol}
              aria-describedby="receive-stock-name"
              onChange={(e) =>
                onSelect(stocks.find((s) => s.symbol === e.target.value)!)
              }
            >
              {/* Short visible text keeps the control within narrow layouts; the full name stays in the accessible label and the line below. */}
              {stocks.map((s) => (
                <option
                  value={s.symbol}
                  key={s.symbol}
                  aria-label={`${s.name} · ${s.symbol}`}
                >
                  {s.symbol}
                </option>
              ))}
            </select>
            <ChevronDown size={16} aria-hidden="true" />
          </div>
        </div>
        <p id="receive-stock-name" className="selected-stock-name">
          {stock.name}
        </p>
        <div className="output-line">
          <span
            className={`output numeric ${quote ? "" : "quiet"}`}
            title={
              quote ? formatUnits(quote.output, quote.decimals) : undefined
            }
          >
            {quote ? displayUnits(quote.output, quote.decimals) : "—"}
          </span>
          <span className="quiet">{stock.symbol}</span>
        </div>
      </div>
      <div className="quote-clock">
        <span>
          <Clock3 size={13} aria-hidden="true" />
          {quoting
            ? "Updating quote…"
            : quote
              ? expired
                ? "Quote expired"
                : `${auto ? "Auto refresh" : "Quote expires"} in ${Math.max(0, Math.ceil((QUOTE_TTL - age) / 1000))}s`
              : auto
                ? "Quotes refresh every 30s"
                : "Manual quote refresh"}
        </span>
        <button
          className="icon-button"
          aria-label="Refresh quote"
          disabled={quoting}
          onClick={renew}
        >
          <RefreshCw size={15} />
        </button>
      </div>
      <button
        className="primary-button trade-action"
        disabled={
          busy ||
          (!!wallet.account &&
            !wrongChain &&
            !pending &&
            (!!unquotable ||
              !!inputError ||
              insufficient ||
              quoting ||
              (!canTrade && !expired && !quoteError)))
        }
        onClick={() => {
          if (!wallet.account) onConnect();
          else if (wrongChain) void wallet.switchChain();
          else if (pending) void checkPending();
          else startReview();
        }}
      >
        {!wallet.account && <Wallet size={17} />} {busy ? step : buttonLabel}
        {canTrade && !wrongChain && <ArrowRight size={17} />}
      </button>
      <div className="trade-message" role="status">
        {unquotable || quoteError || balanceError || ""}
      </div>
      {wallet.error && (
        <p className="inline-error" role="alert">
          {wallet.error}
        </p>
      )}
      {txError && (
        <p className="inline-error" role="alert">
          {txError}
        </p>
      )}
      {success && (
        <p className="success-message" role="status">
          <CheckCircle2 size={16} />
          {success}
        </p>
      )}
      {(pending || lastHash) && (
        <ExternalLink href={`${EXPLORER}/tx/${pending?.hash ?? lastHash}`}>
          {pending ? "View pending transaction" : "View transaction"}
        </ExternalLink>
      )}
      <dl className="trade-details">
        <div>
          <dt>
            DEX fee <CircleHelp size={13} aria-hidden="true" />
          </dt>
          <dd>
            {quote && decimals !== undefined
              ? `${displayUnits(quote.fees.fee, decimals)} IMD`
              : "0.5%"}
            {quote && <span className="quiet"> (0.5%)</span>}
          </dd>
        </div>
        <div>
          <dt>Slippage tolerance</dt>
          <dd>{slippage / 100}%</dd>
        </div>
        {quote && (
          <div>
            <dt>Minimum received</dt>
            <dd
              title={formatUnits(
                minimumOutput(quote.output, slippage),
                quote.decimals,
              )}
            >
              {displayUnits(
                minimumOutput(quote.output, slippage),
                quote.decimals,
              )}{" "}
              {stock.symbol}
            </dd>
          </div>
        )}
      </dl>
      <details className="route-details">
        <summary>
          <span>
            <Route size={16} />
            Auto route
          </span>
          <span className="quiet">
            {route.length
              ? `${route.length - 1} hop${route.length > 2 ? "s" : ""}`
              : "No route"}{" "}
            <ChevronDown size={14} />
          </span>
        </summary>
        <p>The DEX automatically uses its owner-configured Uniswap v3 route.</p>
        {route.map((hop, i) => (
          <div className="route-hop" key={hop.token}>
            {i > 0 && <span className="quiet">↓ {hop.fee}% pool fee</span>}
            <ExternalLink href={`${EXPLORER}/token/${hop.token}`}>
              {routeNames[hop.token] ?? shortAddress(hop.token)}
            </ExternalLink>
            <code>{hop.token}</code>
          </div>
        ))}
      </details>
      <p className="trade-footnote">
        <ShieldCheck size={15} />
        <span>Stock tokens go directly to your wallet.</span>
      </p>
      <details className="asset-details">
        <summary>About {stock.symbol}</summary>
        <p>
          Tokenized stock exposure. Issuer restrictions may apply. This DEX
          provides purchases only; token listing does not verify backing or
          redemption rights.
        </p>
        <AddressDisplay address={stock.address} label="Stock token" />
      </details>
      {review && wallet.account && (
        <Modal
          title={
            reviewApproval ? "Approve IMD spending" : "Review your purchase"
          }
          busy={busy}
          onClose={() => setReview(undefined)}
        >
          <p className="modal-description">
            {reviewApproval
              ? allowance && allowance > 0n
                ? "Reset your existing allowance first. Then approve only the IMD needed for this purchase."
                : "Allow this DEX to spend the exact IMD amount below. A separate confirmation completes the purchase."
              : "Review the minimum you will receive before confirming in your wallet."}
          </p>
          <dl className="review-details">
            <div>
              <dt>You pay</dt>
              <dd>
                {decimals !== undefined
                  ? formatUnits(review.amount, decimals)
                  : ""}{" "}
                IMD
              </dd>
            </div>
            <div>
              <dt>Estimated output</dt>
              <dd>
                {formatUnits(review.output, review.decimals)}{" "}
                {stocks.find((s) => same(s.address, review.stock))?.symbol}
              </dd>
            </div>
            <div>
              <dt>Minimum received</dt>
              <dd>
                {formatUnits(
                  minimumOutput(review.output, slippage),
                  review.decimals,
                )}{" "}
                {stocks.find((s) => same(s.address, review.stock))?.symbol}
              </dd>
            </div>
            <div>
              <dt>DEX fee</dt>
              <dd>
                {decimals !== undefined
                  ? formatUnits(review.fees.fee, decimals)
                  : ""}{" "}
                IMD (0.5%)
              </dd>
            </div>
            <div>
              <dt>Burned IMD</dt>
              <dd>
                {decimals !== undefined
                  ? formatUnits(review.fees.burnAmount, decimals)
                  : ""}
              </dd>
            </div>
            <div>
              <dt>Creator receives</dt>
              <dd>
                {decimals !== undefined
                  ? formatUnits(review.fees.creatorAmount, decimals)
                  : ""}{" "}
                IMD
              </dd>
            </div>
            <div>
              <dt>Network</dt>
              <dd>Ethereum</dd>
            </div>
            <div>
              <dt>Purchase deadline</dt>
              <dd>5 minutes after validation</dd>
            </div>
          </dl>
          <AddressDisplay address={wallet.account!} label="Your wallet" />
          <AddressDisplay address={DEX} label="DEX spender" />
          {snapshot && (
            <AddressDisplay address={snapshot.creator} label="Fee recipient" />
          )}
          <p className="quiet">
            Pool fees and price impact are included in the quote. Ethereum gas
            is paid separately in ETH. Quote uses configuration v
            {review.version.toString()}.
          </p>
          {(reviewExpired || reviewChanged) && (
            <p className="warning-message" role="status">
              {reviewChanged
                ? "The DEX configuration changed."
                : "This quote expired."}{" "}
              Close this review and refresh your quote.
            </p>
          )}
          {txError && (
            <p className="inline-error" role="alert">
              {txError}
            </p>
          )}
          {pending && (
            <ExternalLink href={`${EXPLORER}/tx/${pending.hash}`}>
              View pending transaction
            </ExternalLink>
          )}
          <button
            className="primary-button"
            disabled={
              busy || reviewExpired || reviewChanged || !!pending || wrongChain
            }
            onClick={() => void execute()}
          >
            {busy
              ? step
              : reviewApproval
                ? allowance && allowance > 0n
                  ? "Reset IMD allowance"
                  : "Approve exact IMD amount"
                : "Confirm purchase"}
          </button>
          <button
            className="secondary-button"
            disabled={busy}
            onClick={() => {
              setReview(undefined);
              renew();
            }}
          >
            Back to quote
          </button>
        </Modal>
      )}
    </section>
  );
}
