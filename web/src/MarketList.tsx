import { useMemo, useState } from "react";
import {
  ArrowDown,
  ArrowUpRight,
  ChevronLeft,
  ChevronRight,
  Search,
  SlidersHorizontal,
  Star,
} from "lucide-react";
import { stocks, sectors } from "./stocks";
import type { Stock } from "./stocks";
import { displayUnits } from "./chain";
import type { Snapshot } from "./chain";
import { StockMark } from "./components";
export function MarketList({
  snapshot,
  selected,
  onSelect,
  favorites,
  toggleFavorite,
  watchlist = false,
}: {
  snapshot?: Snapshot;
  selected: Stock;
  onSelect: (stock: Stock) => void;
  favorites: string[];
  toggleFavorite: (symbol: string) => void;
  watchlist?: boolean;
}) {
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState("all");
  const [sector, setSector] = useState("all");
  const [page, setPage] = useState(0);
  const [sort, setSort] = useState("rank");
  const filtered = useMemo(
    () =>
      stocks
        .filter(
          (stock) =>
            (!watchlist || favorites.includes(stock.symbol)) &&
            (filter !== "available" ||
              snapshot?.markets[stock.address]?.enabled) &&
            (sector === "all" || stock.sector === sector) &&
            `${stock.name} ${stock.symbol} ${stock.address}`
              .toLowerCase()
              .includes(search.toLowerCase().trim()),
        )
        .sort((a, b) =>
          sort === "name" ? a.name.localeCompare(b.name) : a.rank - b.rank,
        ),
    [search, filter, sector, sort, snapshot, favorites, watchlist],
  );
  const pages = Math.ceil(filtered.length / 10);
  const activePage = Math.min(page, Math.max(0, pages - 1));
  const shown = filtered.slice(activePage * 10, activePage * 10 + 10);
  function reset() {
    setSearch("");
    setFilter("all");
    setSector("all");
    setPage(0);
  }
  return (
    <section className="market-section" aria-labelledby="market-title">
      <div className="section-title">
        <div className="heading-group">
          <h2 id="market-title">
            {watchlist ? "Your watchlist" : "Explore stocks"}
          </h2>
          <span className="count">
            {watchlist ? favorites.length : stocks.length}
          </span>
        </div>
        <span className="quiet desktop-only">Prices in IMD</span>
      </div>
      <div className="market-tools">
        <div className="search-field">
          <Search size={18} aria-hidden="true" />
          <label className="sr-only" htmlFor="stock-search">
            Search stocks
          </label>
          <input
            id="stock-search"
            type="search"
            value={search}
            placeholder="Search name, symbol or address"
            onChange={(e) => {
              setSearch(e.target.value);
              setPage(0);
            }}
          />
        </div>
        <div className="sector-field">
          <SlidersHorizontal size={16} aria-hidden="true" />
          <label htmlFor="sector" className="sr-only">
            Filter by sector
          </label>
          <select
            id="sector"
            value={sector}
            onChange={(e) => {
              setSector(e.target.value);
              setPage(0);
            }}
          >
            <option value="all">All sectors</option>
            {sectors.map((s) => (
              <option key={s}>{s}</option>
            ))}
          </select>
        </div>
      </div>
      <div className="table-options">
        <div
          className="filter-tabs"
          role="group"
          aria-label="Trading availability"
        >
          <button
            aria-pressed={filter === "all"}
            className={filter === "all" ? "active" : ""}
            onClick={() => {
              setFilter("all");
              setPage(0);
            }}
          >
            All stocks
          </button>
          <button
            aria-pressed={filter === "available"}
            className={filter === "available" ? "active" : ""}
            onClick={() => {
              setFilter("available");
              setPage(0);
            }}
          >
            Available to buy
          </button>
        </div>
        <label className="sort-label">
          <span className="sr-only">Sort stocks</span>
          <select
            value={sort}
            onChange={(e) => {
              setSort(e.target.value);
              setPage(0);
            }}
          >
            <option value="rank">Catalog order</option>
            <option value="name">Name A–Z</option>
          </select>
        </label>
      </div>
      <table className="stock-table">
        <caption className="sr-only">
          Tokenized stocks. Prices are indicative IMD per token for a 1,000 IMD
          purchase.
        </caption>
        <thead>
          <tr>
            <th scope="col" className="rank-col">
              #
            </th>
            <th scope="col">Stock</th>
            <th scope="col" className="price-col">
              Price <ArrowDown size={12} aria-hidden="true" />
            </th>
            <th scope="col" className="status-col">
              Availability
            </th>
            <th scope="col">
              <span className="sr-only">Watchlist</span>
            </th>
          </tr>
        </thead>
        <tbody>
          {shown.map((stock) => {
            const market = snapshot?.markets[stock.address];
            const price =
              market?.reference && market.decimals !== undefined
                ? displayUnits(
                    (1000n * 10n ** BigInt(market.decimals + 6)) /
                      market.reference,
                    6,
                    4,
                  )
                : null;
            return (
              <tr
                key={stock.symbol}
                className={stock.symbol === selected.symbol ? "selected" : ""}
              >
                <td className="rank-col quiet">{stock.rank}</td>
                <td>
                  <button
                    className="stock-name"
                    aria-label={`Buy ${stock.name}`}
                    onClick={() => onSelect(stock)}
                  >
                    <StockMark stock={stock} small />
                    <span>
                      <strong>{stock.name}</strong>
                      <span className="quiet stock-symbol">{stock.symbol}</span>
                    </span>
                  </button>
                </td>
                <td className="price-col">
                  <span className="numeric">
                    {price ?? <span className="quiet">Unavailable</span>}
                  </span>
                  {price && <span className="quiet price-unit">IMD</span>}
                </td>
                <td className="status-col">
                  <span
                    className={`market-status ${market?.enabled ? "available" : ""}`}
                  >
                    {!market
                      ? "Checking"
                      : market.error
                        ? "Unknown"
                        : market.enabled
                          ? "Available"
                          : "Not listed"}
                  </span>
                </td>
                <td className="star-col">
                  <button
                    className={`icon-button favorite ${favorites.includes(stock.symbol) ? "saved" : ""}`}
                    aria-label={`${favorites.includes(stock.symbol) ? "Remove" : "Add"} ${stock.name} ${favorites.includes(stock.symbol) ? "from" : "to"} watchlist`}
                    aria-pressed={favorites.includes(stock.symbol)}
                    onClick={() => toggleFavorite(stock.symbol)}
                  >
                    <Star
                      size={17}
                      fill={
                        favorites.includes(stock.symbol)
                          ? "currentColor"
                          : "none"
                      }
                    />
                  </button>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      {!shown.length && (
        <div className="empty-state">
          <Search size={24} />
          <h3>
            {watchlist && favorites.length === 0
              ? "Keep your stocks close"
              : "No matching stocks"}
          </h3>
          <p>
            {watchlist && favorites.length === 0
              ? "Select a star in Markets to save a stock on this device."
              : `No stocks match ${search ? `“${search}”` : "these filters"}. Try a different search.`}
          </p>
          {!(watchlist && favorites.length === 0) && (
            <button className="secondary-button" onClick={reset}>
              Clear filters
            </button>
          )}
        </div>
      )}
      <div className="table-footer">
        <span className="quiet" role="status">
          {filtered.length
            ? `${activePage * 10 + 1}–${Math.min((activePage + 1) * 10, filtered.length)} of ${filtered.length} stocks`
            : "0 stocks"}
        </span>
        <div className="pagination">
          <button
            className="icon-button"
            aria-label="Previous stocks"
            disabled={activePage === 0}
            onClick={() => setPage(activePage - 1)}
          >
            <ChevronLeft size={18} />
          </button>
          <span>
            {pages ? activePage + 1 : 0} / {pages}
          </span>
          <button
            className="icon-button"
            aria-label="Next stocks"
            disabled={activePage + 1 >= pages}
            onClick={() => setPage(activePage + 1)}
          >
            <ChevronRight size={18} />
          </button>
        </div>
      </div>
      <p className="market-note">
        Indicative prices for a 1,000 IMD buy, including the 0.5% DEX fee. Gas
        is extra. A catalog entry does not guarantee an enabled route or
        liquidity.
      </p>
    </section>
  );
}
export function FeaturedStocks({
  snapshot,
  onSelect,
}: {
  snapshot?: Snapshot;
  onSelect: (stock: Stock) => void;
}) {
  return (
    <section aria-label="Featured stocks" className="featured-grid">
      {[stocks[0], stocks[1], stocks[2], stocks[3]].map((stock) => {
        const m = snapshot?.markets[stock.address];
        return (
          <button
            className="featured-stock"
            key={stock.symbol}
            onClick={() => onSelect(stock)}
            aria-label={`Explore ${stock.name}`}
          >
            <div className="feature-head">
              <StockMark stock={stock} small />
              <ArrowUpRight className="quiet" size={16} aria-hidden="true" />
            </div>
            <strong>{stock.name}</strong>
            <div className="feature-bottom">
              <span className="quiet">{stock.symbol}</span>
              <span className={m?.enabled ? "available" : "quiet"}>
                {m?.enabled ? "Buy" : "Explore"}
              </span>
            </div>
          </button>
        );
      })}
    </section>
  );
}
