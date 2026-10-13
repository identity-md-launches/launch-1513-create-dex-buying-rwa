import { useCallback, useEffect, useState } from "react";
import { ArrowRight, Download, Layers3, RefreshCw, Wallet } from "lucide-react";
import { erc20Abi, formatUnits } from "viem";
import type { Address } from "viem";
import {
  client,
  displayUnits,
  errorMessage,
  EXPLORER,
  isSet,
  loadActivity,
  loadHoldings,
  same,
} from "./chain";
import type { Activity, Holding, Snapshot } from "./chain";
import { stocks } from "./stocks";
import type { Stock } from "./stocks";
import { AddressDisplay, ExternalLink, StockMark } from "./components";
export function Dashboard({
  account,
  snapshot,
  onConnect,
  onSelect,
  refreshKey,
}: {
  account?: Address;
  snapshot?: Snapshot;
  onConnect: () => void;
  onSelect: (stock: Stock) => void;
  refreshKey: number;
}) {
  const [holdings, setHoldings] = useState<Holding[]>();
  const [activity, setActivity] = useState<Activity>();
  const [balance, setBalance] = useState<bigint>();
  const [error, setError] = useState("");
  const [holdingsError, setHoldingsError] = useState("");
  const [activityError, setActivityError] = useState("");
  const [loading, setLoading] = useState(false);
  const [more, setMore] = useState(false);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let active = true;
    setHoldings(undefined);
    setActivity(undefined);
    setBalance(undefined);
    setError("");
    setHoldingsError("");
    setActivityError("");
    if (!account) return;
    setLoading(true);
    const balances = loadHoldings(account)
      .then((v) => {
        if (active) setHoldings(v);
      })
      .catch((e) => {
        if (active) setHoldingsError(errorMessage(e));
      });
    const history = loadActivity(account)
      .then((v) => {
        if (active) setActivity(v);
      })
      .catch((e) => {
        if (active) setActivityError(errorMessage(e));
      });
    const imd =
      snapshot && isSet(snapshot.imd)
        ? client
            .readContract({
              address: snapshot.imd,
              abi: erc20Abi,
              functionName: "balanceOf",
              args: [account],
            })
            .then((v) => {
              if (active) setBalance(v);
            })
            .catch(() => {
              if (active)
                setError("IMD balance unavailable. Refresh to retry.");
            })
        : Promise.resolve();
    void Promise.all([balances, history, imd]).finally(() => {
      if (active) setLoading(false);
    });
    return () => {
      active = false;
    };
  }, [account, snapshot?.imd, tick, refreshKey]);
  const owned = holdings?.filter(
    (h) => h.balance !== undefined && h.balance > 0n,
  );
  const failures = holdings?.filter((h) => h.error).length ?? 0;
  const loadMore = useCallback(async () => {
    if (!account || !activity || more) return;
    setMore(true);
    setActivityError("");
    try {
      const older = await loadActivity(account, activity.fromBlock - 1n);
      setActivity({
        ...older,
        toBlock: activity.toBlock,
        events: [...activity.events, ...older.events],
      });
    } catch (e) {
      setActivityError(errorMessage(e));
    } finally {
      setMore(false);
    }
  }, [account, activity, more]);
  function download() {
    if (!holdings) return;
    const rows = [
      ["Symbol", "Name", "Token address", "Balance", "Status"],
      ...holdings.map((h) => {
        const stock = stocks.find((s) => same(s.address, h.address))!;
        return [
          stock.symbol,
          stock.name,
          h.address,
          h.balance !== undefined && h.decimals !== undefined
            ? formatUnits(h.balance, h.decimals)
            : "",
          h.error ?? "Read from Ethereum",
        ];
      }),
    ];
    const csv = rows
      .map((row) =>
        row.map((cell) => `"${cell.replaceAll('"', '""')}"`).join(","),
      )
      .join("\r\n");
    const url = URL.createObjectURL(
      new Blob([csv], { type: "text/csv;charset=utf-8" }),
    );
    const a = document.createElement("a");
    a.href = url;
    a.download = "imd-stock-balances.csv";
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  if (!account)
    return (
      <div className="dashboard-disconnected">
        <div className="dashboard-art" aria-hidden="true">
          <Layers3 size={64} strokeWidth={1} />
          <span className="art-dot one" />
          <span className="art-dot two" />
        </div>
        <h2>Your stocks. Your wallet.</h2>
        <p>
          Connect your Ethereum wallet to see stock balances and purchases
          through this DEX.
        </p>
        <button className="primary-button" onClick={onConnect}>
          <Wallet size={18} />
          Connect wallet
        </button>
        <p className="quiet">
          Connecting your wallet does not send a transaction.
        </p>
      </div>
    );
  return (
    <div className="dashboard">
      <div className="dashboard-account">
        <AddressDisplay address={account} label="Connected wallet" />
        <button
          className="secondary-button"
          disabled={loading}
          onClick={() => setTick((t) => t + 1)}
        >
          <RefreshCw size={16} />
          {loading ? "Refreshing…" : "Refresh balances"}
        </button>
      </div>
      <div className="portfolio-summary">
        <div>
          <span className="muted">Available IMD</span>
          <strong>
            {balance !== undefined && snapshot?.decimals !== undefined
              ? displayUnits(balance, snapshot.decimals, 4)
              : loading && !error
                ? "Loading…"
                : "Unavailable"}
          </strong>
        </div>
        <div>
          <span className="muted">Stocks held</span>
          <strong>
            {owned
              ? `${owned.length}${failures ? " known" : ""}`
              : holdingsError
                ? "Unavailable"
                : "Loading…"}
          </strong>
        </div>
        <div>
          <span className="muted">Purchases in loaded history</span>
          <strong>
            {activity
              ? activity.events.length
              : activityError
                ? "Unavailable"
                : "Loading…"}
          </strong>
        </div>
      </div>
      {error && (
        <p className="inline-error" role="alert">
          {error}
        </p>
      )}
      {holdingsError && (
        <p className="inline-error" role="alert">
          {holdingsError}
        </p>
      )}
      {failures > 0 && (
        <p className="warning-message">
          {failures} token balance{failures === 1 ? " is" : "s are"}{" "}
          unavailable. Counts include successfully read tokens only. Refresh to
          retry.
        </p>
      )}
      <section className="holdings-section">
        <div className="section-title">
          <h2>Stock balances</h2>
          <button
            className="secondary-button"
            disabled={!holdings}
            onClick={download}
          >
            <Download size={16} />
            Export CSV
          </button>
        </div>
        {!holdings && !holdingsError ? (
          <p role="status" className="loading-state">
            Reading token balances from Ethereum…
          </p>
        ) : owned?.length ? (
          <div className="holdings-list">
            {owned.map((h) => {
              const stock = stocks.find((s) => same(s.address, h.address))!;
              return (
                <div className="holding-row" key={h.address}>
                  <div className="stock-name">
                    <StockMark stock={stock} small />
                    <span>
                      <strong>{stock.name}</strong>
                      <span className="quiet stock-symbol">{stock.symbol}</span>
                    </span>
                  </div>
                  <span
                    className="numeric"
                    title={formatUnits(h.balance!, h.decimals!)}
                  >
                    {displayUnits(h.balance!, h.decimals!)}
                  </span>
                  <button
                    className="secondary-button"
                    onClick={() => onSelect(stock)}
                  >
                    Buy more
                    <ArrowRight size={15} />
                  </button>
                </div>
              );
            })}
          </div>
        ) : holdings ? (
          // Only a completed read with no owned tokens is an empty portfolio.
          <div className="empty-state">
            <Layers3 size={28} />
            <h3>No stock balances found</h3>
            <p>Balances cover the 50 stocks in this catalog.</p>
            <button
              className="secondary-button"
              onClick={() => onSelect(stocks[1])}
            >
              Explore stocks
              <ArrowRight size={16} />
            </button>
          </div>
        ) : (
          <div className="empty-state" role="status">
            <h3>Stock balances unavailable. Refresh to retry.</h3>
            <p>
              The balance read did not complete, so no holdings are shown.
            </p>
            <button
              className="secondary-button"
              disabled={loading}
              onClick={() => setTick((t) => t + 1)}
            >
              <RefreshCw size={16} />
              Retry balances
            </button>
          </div>
        )}
      </section>
      <section className="activity-section">
        <div className="section-title">
          <h2>Purchase activity</h2>
          <span className="quiet">Onchain history</span>
        </div>
        {activity && (
          <p className="quiet">
            Blocks {activity.fromBlock.toString()}–{activity.toBlock.toString()}
            . Only purchases through this DEX are included.
          </p>
        )}
        {activityError && (
          <div className="inline-error" role="alert">
            {activityError}
            <button
              className="text-button"
              onClick={() => setTick((t) => t + 1)}
            >
              Retry history
            </button>
          </div>
        )}
        {!activity && !activityError ? (
          <p className="loading-state" role="status">
            Loading purchases…
          </p>
        ) : activity?.events.length ? (
          <div className="activity-list">
            {activity.events.map((event) => {
              const stock = stocks.find((s) =>
                same(s.address, event.args.stock),
              );
              const h = holdings?.find((h) =>
                same(h.address, event.args.stock),
              );
              return (
                <div
                  className="activity-row"
                  key={`${event.transactionHash}-${event.logIndex}`}
                >
                  <div>
                    <strong>Bought {stock?.name ?? "stock token"}</strong>
                    <span className="quiet">
                      Block {event.blockNumber.toString()}
                    </span>
                  </div>
                  <span>
                    {event.args.stockReceived !== undefined &&
                    h?.decimals !== undefined
                      ? `${displayUnits(event.args.stockReceived, h.decimals)} ${stock?.symbol ?? "tokens"}`
                      : `${event.args.stockReceived ?? ""} base units`}
                  </span>
                  <ExternalLink
                    href={`${EXPLORER}/tx/${event.transactionHash}`}
                  >
                    Transaction
                  </ExternalLink>
                </div>
              );
            })}
          </div>
        ) : (
          activity && (
            <div className="empty-state">
              <h3>No purchases in this range</h3>
              <p>
                Completed DEX purchases will appear here after confirmation.
              </p>
            </div>
          )
        )}
        {activity?.hasMore && (
          <button
            className="secondary-button"
            disabled={more}
            onClick={() => void loadMore()}
          >
            {more ? "Loading history…" : "Load older purchases"}
          </button>
        )}
      </section>
    </div>
  );
}
