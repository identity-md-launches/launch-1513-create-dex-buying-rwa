# IMD Stocks design system

## Overview

IMD Stocks is a wallet-connected buying interface for the supplied catalog of 50 tokenized stocks. The visual idea is a quiet, dark trading desk with one lime purchase action. The interface puts an actionable quote alongside a searchable catalog on desktop, and puts the quote first on phones. Portfolio and Watchlist are hash-routed views within the same static page.

The implementation lives in `web/src/`; `dist/` contains the production export. This document describes the final source, rather than a proposed design. Desktop and mobile examples are saved in `docs/website-validation/`. There is one dark theme and one English locale.

## Colors

`web/src/style.css:1` defines a small hex palette and semantic aliases. Use the semantic tokens in components.

| Token | Value | Role |
| --- | --- | --- |
| `--bg` | `#0b1013` | Page background |
| `--surface` | `#11181b` | Fields, feature buttons, modal |
| `--surface-raised` | `#161f22` | Secondary emphasis and active icons |
| `--hover` | `#1b262a` | Hover, neutral selected state, disabled primary action |
| `--border` | `#2c383d` | Structural separators and control boundaries |
| `--text` | `#edf2ef` | Primary text |
| `--muted` | `#99a7a3` | Secondary labels and unavailable data |
| `--accent`, `--focus` | `#baf266` | Primary action and keyboard focus |
| `--accent-hover` | `#a6db55` | Primary action hover |
| `--on-accent` | `#17210d` | Text on the lime action |
| `--success` | `#8cdaa9` | Confirmed action or available route, always accompanied by text |
| `--warning` | `#ecc28a` | Expired review and incomplete reads |
| `--danger` | `#f2a1a1` | Errors |

The token primitives are `--neutral-*`, `--lime-*`, `--green-300`, `--amber-300`, and `--red-300`. Stock initials have six separate identity color pairs in `.stock-mark`: silver, lime, red, blue, orange and green. They identify stocks; they do not report performance. Selected table rows use `#121e1b` and ordinary row dividers use `#202a2e`.

Computed contrast for the declared solid pairs is 16.90:1 for primary text/page, 7.66:1 for muted text/page, 7.19:1 for muted text/surface, and 12.69:1 for action text/lime. The focus color is 13.65:1 against the surface and 11.77:1 against hover. The rendered taste probe also passed its text contrast checks. These measurements are specific pairs, not a claim of complete accessibility certification.

## Typography

The system stack is `ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`. No font download or external font service is required. The installed system font may differ across devices. Monospace is reserved for complete contract addresses and route bytes.

| Token | Base size | Use |
| --- | --- | --- |
| `--text-xs` | 12px / .75rem | Metadata, balances, table headings, explanatory text |
| `--text-sm` | 14px / .875rem | Body, buttons, stock names |
| `--text-base` | 16px / 1rem | Small headings, prominent labels, mobile form controls |
| `--text-lg` | 20px / 1.25rem | Section headings and brand |
| `--text-xl` | 28px / 1.75rem | Trade amounts, mobile page title, portfolio totals |
| `--text-display` | 36px / 2.25rem | Desktop page title |

Weights are 400 and 600. Body line height is 1.5; page headings use 1.15, section headings 1.3, small headings 1.4, and longer modal explanations 1.65. Page headings track at `-.04em`, section headings at `-.02em`; content uses natural tracking and sentence case. Headings use balanced wrapping. Prices, countdowns and balances use tabular numerals.

At widths up to 37rem, search, stock selection, sector selection and slippage controls use 16px type. Long names wrap in the stock table. Addresses wrap with `overflow-wrap: anywhere` and remain selectable and copyable. The header uses a compact wallet address with the complete address available in its wallet dialog. Quote previews are abbreviated for legibility; the transaction review shows exact decimal amounts.

## Layout

The spacing scale is 4, 8, 12, 16, 20, 24, 32, 40 and 48px, exposed as `--space-*`. Related controls generally use 8–12px gaps; sections use 24–32px. Dense data controls also use component-specific values.

`.header-inner` and `.main-shell` have a 1380px maximum width. Desktop gutters are 40px. `.trading-layout` has a flexible catalog and a 366px trade column separated by 32px. The trade form comes first in the DOM; CSS places it in the right column on wide screens. This preserves a useful keyboard order when the layout becomes one column. The trade column is not sticky and cannot cover page content.

| Breakpoint | Implemented adaptation |
| --- | --- |
| 85rem / 1360px | Trade column becomes 346px; gap becomes 24px; network utility and table availability column collapse |
| 64rem / 1024px | Gutters become 24px; trade column becomes 330px; featured stocks become two columns; rank and table sort control collapse |
| 54rem / 864px | Trade moves above catalog in one column; pay and receive fields sit side by side; featured stocks return to four columns; full table columns return where space allows |
| 37rem / 592px | Gutters become 16px; header navigation gets a second row; pay/receive stack; featured stocks use two columns; table hides rank and availability while preserving stock, price and watchlist actions |

At 390 × 844 the title, amount, stock selector and primary wallet action are visible without scrolling. Rendered reflow was tested at 320, 390, 768, 1024 and 1440px. Additional checks cover 200% root text enlargement, an RTL mirror, and forced colors at 1440px. These are not physical-device or browser-native zoom tests.

## Elevation & Depth

The interface is flat. Structural borders divide navigation, table rows and the desktop trade column. There are no shadows or gradient text. Trade fields have their own surface fill; there is no outer filled card wrapping those fields. Feature buttons have one border each.

Native `<dialog>` provides the modal top layer and background inertness. Its backdrop is black at 76% opacity. Dialogs are limited to `calc(100dvh - 40px)` and scroll internally. No fixed action covers underlying content.

## Shapes

Buttons and search fields use 8px corners, feature buttons 10px, trade input groups 9px, and dialogs 16px. Stock initials use 9–10px corners, reduced to 7px in narrow table rows. Status dots and the IMD marker are circular. Radii distinguish controls and identity marks without wrapping every content group in another card.

## Components

- `App.tsx`: shared header, hash navigation, market summary, help and wallet content. The brand links to Markets; `aria-current` identifies the current view. The skip link focuses the current main content without changing the hash route.
- `Trade.tsx`: amount, native stock selector, settings, quote countdown, fees, expandable route, transaction review and persistent transaction state. Default slippage is 0.5%, with 0.1%, 1% and 3% alternatives. Quote expiry and owner configuration changes invalidate a review. Disabling automatic refresh preserves the current quote until it expires; explicit refresh is always available.
- `MarketList.tsx`: search by name, symbol or address, native sector selection, availability filters, catalog/name sorting, ten-row pagination and watchlist stars. Empty search results have a clear-filter action. Unlisted tokens remain in the catalog and show unavailable prices. `FeaturedStocks` reuses the first four supplied catalog entries; these are not performance recommendations.
- `Dashboard.tsx`: disconnected call to connect, IMD balance, known stock count, ERC-20 holdings, CSV export and paginated purchase events. Empty, partial-read, error and loading states never substitute fabricated balances.
- `components.tsx`: `StockMark`, `ExternalLink`, `AddressDisplay` and `Modal`. The modal uses native focus containment, Escape and return-to-trigger focus. Busy signing/confirmation prevents accidental dismissal. Address copying reports a fallback when Clipboard API access fails.
- `hooks.ts`: EIP-6963 discovery with an injected-provider fallback, wallet account/chain event handling, local watchlists and recurring verified contract reads. These hooks own state; the CSS does not imply live data on its own.

Primary actions use `.primary-button`, secondary actions `.secondary-button`, quiet utilities `.text-button`, and named icon actions `.icon-button`. Most compact targets are 36px; major actions are 46–48px high. The measured controls meet the probe's 24px-or-spacing threshold, but many compact controls are below its optional 44px comfort target.

Focus uses a 2px lime outline offset by 4px. A search wrapper uses `:focus-within`; forced-colors mode uses system highlight and button borders. Buttons, inputs, selects, links and disclosures are native elements. Errors use alerts or field descriptions; countdown ticks are not continuously announced. There are no autoplay or infinite animations. Hover transitions are 120ms with `cubic-bezier(.2,0,0,1)` and are enabled only when reduced motion is not requested; press scale is .96 for primary and secondary buttons.

## Do's and Don'ts

Use the shared shell, heading and semantic tokens for another page. Give it a hash route, one page heading, and clear empty/loading/error states. Reuse native controls and the existing button hierarchy. Keep exact transaction facts in the review, and distinguish unavailable data from zero.

Keep onchain status separate from the supplied stock catalog. Do not add decorative price charts, guessed performance, fabricated balances, a second accent system or extra type sizes. Preserve the trade-first mobile order and the complete-address disclosure. Do not turn issuer names or catalog order into claims of endorsement or market-cap ranking.

Design guidance was adapted from Jakub Krehel's Better Interface (MIT). Documentation guidance was adapted from Paul Bakaus's Impeccable at commit `9d715cc4f5564a990ca8345abfdd5df6dc9b41c8` (Apache-2.0). The pinned combined notices and licenses are preserved in `docs/design-guidance-LICENSE`. Review evidence and unperformed checks are recorded in `VALIDATION.md`.
