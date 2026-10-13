import { useEffect, useState } from "react";
import {
  Activity,
  ArrowUpRight,
  Check,
  CircleHelp,
  ExternalLink as ExternalIcon,
  Layers3,
  RefreshCw,
  ShieldCheck,
  Wallet,
  WifiOff,
} from "lucide-react";
import { DEX, EXPLORER, shortAddress } from "./chain";
import { AddressDisplay, ExternalLink, Modal } from "./components";
import { Dashboard } from "./Dashboard";
import { useMarkets, useWallet, readLocal, saveLocal } from "./hooks";
import { FeaturedStocks, MarketList } from "./MarketList";
import { stocks } from "./stocks";
import type { Stock } from "./stocks";
import { Trade } from "./Trade";

type Page = "markets" | "portfolio" | "watchlist";
function currentPage(): Page {
  return location.hash === "#portfolio"
    ? "portfolio"
    : location.hash === "#watchlist"
      ? "watchlist"
      : "markets";
}
export default function App() {
  const [page, setPage] = useState<Page>(currentPage);
  const [selected, setSelected] = useState(stocks[1]);
  const [walletOpen, setWalletOpen] = useState(false);
  const [helpOpen, setHelpOpen] = useState(false);
  const [favorites, setFavorites] = useState<string[]>(() => {
    const value = readLocal<unknown>("imd-watchlist", []);
    return Array.isArray(value)
      ? value.filter(
          (v): v is string =>
            typeof v === "string" && stocks.some((s) => s.symbol === v),
        )
      : [];
  });
  const [confirmed, setConfirmed] = useState(0);
  const { snapshot, loading, error, notice, setNotice, refresh } = useMarkets();
  const wallet = useWallet();
  useEffect(() => {
    const listener = () => setPage(currentPage());
    window.addEventListener("hashchange", listener);
    return () => window.removeEventListener("hashchange", listener);
  }, []);
  function chooseStock(stock: Stock) {
    setSelected(stock);
    if (page === "portfolio") location.hash = "markets";
    requestAnimationFrame(() => {
      if (window.innerWidth < 1000) {
        document
          .getElementById("trade")
          ?.scrollIntoView({ behavior: "instant", block: "start" });
        document
          .getElementById("receive-stock")
          ?.focus({ preventScroll: true });
      }
    });
  }
  function toggleFavorite(symbol: string) {
    setFavorites((old) => {
      const next = old.includes(symbol)
        ? old.filter((s) => s !== symbol)
        : [...old, symbol];
      saveLocal("imd-watchlist", next);
      return next;
    });
  }
  const enabled = snapshot
    ? Object.values(snapshot.markets).filter((m) => m.enabled).length
    : undefined;
  return (
    <>
      <a
        className="skip-link"
        href="#main"
        onClick={(e) => {
          e.preventDefault();
          document.getElementById("main")?.focus();
        }}
      >
        Skip to content
      </a>
      <header className="site-header">
        <div className="header-inner">
          <a href="#markets" className="brand" aria-label="IMD Stocks home">
            <img src="./favicon.svg" alt="" width="34" height="34" />
            <span>
              imd<span className="brand-divider">/</span>
              <span className="brand-product">stocks</span>
            </span>
          </a>
          <nav aria-label="Main navigation">
            <a
              href="#markets"
              className={page === "markets" ? "active" : ""}
              aria-current={page === "markets" ? "page" : undefined}
            >
              Markets
            </a>
            <a
              href="#portfolio"
              className={page === "portfolio" ? "active" : ""}
              aria-current={page === "portfolio" ? "page" : undefined}
            >
              Portfolio
            </a>
            <a
              href="#watchlist"
              className={page === "watchlist" ? "active" : ""}
              aria-current={page === "watchlist" ? "page" : undefined}
            >
              Watchlist
              {favorites.length > 0 && (
                <span className="nav-count">{favorites.length}</span>
              )}
            </a>
          </nav>
          <div className="header-actions">
            <span className="network-label">
              <span className="eth-glyph" aria-hidden="true">
                ◆
              </span>
              Ethereum
            </span>
            <button
              className="wallet-button"
              onClick={() => setWalletOpen(true)}
              aria-label={
                wallet.account ? `Wallet ${wallet.account}` : "Connect wallet"
              }
            >
              <Wallet size={16} />
              <span>
                {wallet.account
                  ? shortAddress(wallet.account)
                  : "Connect wallet"}
              </span>
            </button>
          </div>
        </div>
      </header>
      <main id="main" tabIndex={-1} className="main-shell">
        <div className="page-heading">
          <div>
            <h1>
              {page === "portfolio"
                ? "Your portfolio"
                : page === "watchlist"
                  ? "Your watchlist"
                  : "Buy tokenized stocks"}
            </h1>
            <p>
              {page === "portfolio"
                ? "Your balances and purchases, directly from Ethereum."
                : page === "watchlist"
                  ? "Follow the stocks you care about. Saved on this device."
                  : "The companies you know. In the wallet you own."}
            </p>
          </div>
          <button
            className="text-button help-button"
            onClick={() => setHelpOpen(true)}
          >
            <CircleHelp size={16} />
            <span>How it works</span>
            <ArrowUpRight size={15} />
          </button>
        </div>
        {page !== "portfolio" && (
          <div className="market-summary">
            <div>
              <Layers3 size={17} />
              <span>
                <strong>50</strong> tokenized stocks
              </span>
            </div>
            <div>
              <Activity size={17} />
              <span>
                <strong>{enabled ?? "…"}</strong> available to buy
              </span>
            </div>
            <div className="fee-summary">
              <span className="percent-icon">%</span>
              <span>
                <strong>0.5%</strong> DEX fee
              </span>
            </div>
            <div className="connection-status">
              <span
                className={`status-dot ${error ? "offline" : snapshot ? "connected" : ""}`}
              />
              <span>
                {error
                  ? "Connection unavailable"
                  : snapshot
                    ? snapshot.paused
                      ? "Trading paused"
                      : "Ethereum connected"
                    : "Connecting to Ethereum"}
              </span>
            </div>
          </div>
        )}
        {error && (
          <div className="network-error" role="alert">
            <WifiOff size={18} />
            <span>
              Live data is unavailable. Trading is disabled until the connection
              recovers.
            </span>
            <button
              className="secondary-button"
              disabled={loading}
              onClick={() => void refresh()}
            >
              <RefreshCw size={15} />
              {loading ? "Retrying…" : "Retry connection"}
            </button>
          </div>
        )}
        {notice && (
          <div className="config-notice" role="status">
            <Check size={17} />
            <span>{notice}</span>
            <button className="text-button" onClick={() => setNotice("")}>
              Dismiss
            </button>
          </div>
        )}
        {page === "portfolio" ? (
          <Dashboard
            account={wallet.account}
            snapshot={snapshot}
            onConnect={() => setWalletOpen(true)}
            onSelect={chooseStock}
            refreshKey={confirmed}
          />
        ) : (
          <div className="trading-layout">
            <Trade
              stock={selected}
              onSelect={chooseStock}
              snapshot={snapshot}
              networkError={error}
              wallet={wallet}
              onConnect={() => setWalletOpen(true)}
              refresh={refresh}
              onConfirmed={() => setConfirmed((v) => v + 1)}
            />
            <div className="catalog-column">
              {page === "markets" && (
                <FeaturedStocks snapshot={snapshot} onSelect={chooseStock} />
              )}
              <MarketList
                key={page}
                snapshot={snapshot}
                selected={selected}
                onSelect={chooseStock}
                favorites={favorites}
                toggleFavorite={toggleFavorite}
                watchlist={page === "watchlist"}
              />
              <div className="ownership-note">
                <ShieldCheck size={23} strokeWidth={1.5} />
                <div>
                  <h3>Always in your custody</h3>
                  <p>
                    Pay with IMD. Receive stock tokens directly in your wallet.
                    Every DEX purchase burns a share of the fee.
                  </p>
                </div>
              </div>
            </div>
          </div>
        )}
      </main>
      <footer className="site-footer">
        <div>
          <span className="footer-brand">imd / stocks</span>
          <span className="quiet">Tokenized equities on Ethereum</span>
        </div>
        <div>
          <span
            className="config-version"
            title="Updates automatically from the deployed contract"
          >
            {snapshot ? `Config v${snapshot.version}` : "Config unavailable"}
            <RefreshCw size={12} />
          </span>
          <ExternalLink href={`${EXPLORER}/address/${DEX}`}>
            DEX contract
          </ExternalLink>
          <button className="text-button" onClick={() => setHelpOpen(true)}>
            About & risks
          </button>
        </div>
      </footer>
      {walletOpen && (
        <Modal
          title={wallet.account ? "Your wallet" : "Connect your wallet"}
          busy={wallet.connecting}
          onClose={() => setWalletOpen(false)}
        >
          {wallet.account ? (
            <>
              <div className="wallet-connected">
                <span className="wallet-emblem">
                  <Wallet size={26} />
                </span>
                <h3>{wallet.walletName}</h3>
                <span
                  className={
                    wallet.chainId === 1 ? "available" : "warning-text"
                  }
                >
                  {wallet.chainId === 1
                    ? "Connected to Ethereum"
                    : "Switch to Ethereum to buy"}
                </span>
              </div>
              <AddressDisplay address={wallet.account} label="Wallet address" />
              {wallet.chainId !== 1 && (
                <button
                  className="primary-button"
                  onClick={() => void wallet.switchChain()}
                >
                  Switch to Ethereum
                </button>
              )}
              <button
                className="secondary-button"
                onClick={() => {
                  wallet.disconnect();
                  setWalletOpen(false);
                }}
              >
                Disconnect wallet
              </button>
            </>
          ) : (
            <>
              <p className="modal-description">
                Choose a browser wallet to buy stocks with IMD.
              </p>
              {wallet.options.length ? (
                <div className="wallet-list">
                  {wallet.options.map((option) => (
                    <button
                      className="wallet-option"
                      key={option.info.uuid}
                      disabled={wallet.connecting}
                      onClick={() => {
                        void wallet.connect(option).then((ok) => {
                          if (ok) setWalletOpen(false);
                        });
                      }}
                    >
                      <Wallet size={22} />
                      <span>
                        {wallet.connecting
                          ? "Waiting for wallet…"
                          : option.info.name}
                      </span>
                      <ArrowUpRight size={18} />
                    </button>
                  ))}
                </div>
              ) : (
                <div className="no-wallet">
                  <Wallet size={32} />
                  <h3>No wallet detected</h3>
                  <p>
                    Open this site in your wallet’s browser, or install a
                    browser wallet and reload.
                  </p>
                  <button
                    className="secondary-button"
                    onClick={() => {
                      window.dispatchEvent(
                        new Event("eip6963:requestProvider"),
                      );
                      wallet.setError(
                        "Wallet discovery refreshed. If you just installed a wallet, reload this page.",
                      );
                    }}
                  >
                    <RefreshCw size={16} />
                    Check for wallets
                  </button>
                  <ExternalLink href="https://ethereum.org/wallets/find-wallet/">
                    Find an Ethereum wallet
                  </ExternalLink>
                </div>
              )}
              <p className="wallet-explainer">
                <ShieldCheck size={16} />
                Connecting does not move funds. You confirm every transaction in
                your wallet.
              </p>
            </>
          )}
          {wallet.error && (
            <p className="inline-error" role="alert">
              {wallet.error}
            </p>
          )}
        </Modal>
      )}
      {helpOpen && (
        <Modal
          title="Stocks, in your wallet"
          onClose={() => setHelpOpen(false)}
        >
          <p className="modal-description">
            Buy tokenized stocks using IMD on Ethereum.
          </p>
          <ol className="help-steps">
            <li>
              <span>1</span>
              <div>
                <h3>Connect your wallet</h3>
                <p>
                  Use an Ethereum wallet with IMD for purchases and ETH for gas.
                </p>
              </div>
            </li>
            <li>
              <span>2</span>
              <div>
                <h3>Choose an available stock</h3>
                <p>
                  Enter an IMD amount. The DEX quotes its configured Uniswap v3
                  route and refreshes every 30 seconds.
                </p>
              </div>
            </li>
            <li>
              <span>3</span>
              <div>
                <h3>Review and confirm</h3>
                <p>
                  Approve the exact IMD amount, then confirm a separate
                  purchase. Stock tokens arrive in your wallet.
                </p>
              </div>
            </li>
          </ol>
          <h3>Understand what you’re buying</h3>
          <p>
            These are third-party stock tokens, not shares purchased on a stock
            exchange. Issuer eligibility, transfer and redemption restrictions
            may apply. Prices and liquidity can differ from the underlying
            stock. This catalog is not a ranking or an endorsement.
          </p>
          <h3>Fees and execution</h3>
          <p>
            The DEX charges 0.5% of your IMD, rounded up in base units. Its
            configured split burns part and pays the creator the rest. Pool fees
            and price impact are additional and reflected in quotes; ETH gas is
            separate. The site supports purchases only.
          </p>
          <h3>Automatic configuration updates</h3>
          <p>
            Every 30 seconds, the site reads the contract version, markets and
            routes again. A changed version invalidates earlier quotes. A
            transaction always includes the version you reviewed and a minimum
            output.
          </p>
          <AddressDisplay address={DEX} label="DEX contract" />
          <ExternalLink href={`${EXPLORER}/address/${DEX}#code`}>
            View the contract <ExternalIcon size={14} />
          </ExternalLink>
        </Modal>
      )}
    </>
  );
}
