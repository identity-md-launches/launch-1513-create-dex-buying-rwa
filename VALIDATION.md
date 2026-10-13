# Website validation

Status: **Complete for the stated website scope.** Checks below were run by the worker on 2026-10-13. They are not independent certification. No contract was deployed, initialized, upgraded or changed, and no real wallet transaction was signed or sent.

## Scope and assumptions

The implementation extends the existing Solidity project with a Vite/React/TypeScript site in `web/` and a production static export in `dist/`. The supplied 50-stock catalog is preserved. Native browser wallets, IMD-only purchases, indicative prices, automatic quote renewal, owner-configured routes, a user portfolio and automatic `configVersion` synchronization are implemented.

The existing contract has a single owner-controlled route per stock. “Auto route” therefore selects that route; it does not assert an independently optimized cross-DEX route. “Auto upgrade configVersion” is implemented as automatic state/route refresh and quote invalidation, not an administrative transaction. There is no price oracle or USD feed in the pinned contract; the site quotes IMD per token at a disclosed reference input. Unavailable routes and reads remain explicitly unavailable.

Important live observation: the deployment manifest describes the initial paused/unconfigured state, but the actual contract had already been configured. Read-only verification at Ethereum block **26182972**, `2026-10-13T10:28:43.446Z`, returned **unpaused, configVersion 10, burnShareBps 3000**. NVIDIA was the only enabled route among the 50 supplied tokens during browser validation. Live quotes were successfully read in the production browser; screenshots are dated evidence, not current price promises.

## Contract and transaction verification

`web/scripts/verify-contracts.mjs` builds the ABI and runtime from the pinned, unchanged source using `forge inspect` and compares canonical ABI hashes. The initial checkout was exactly source commit `7933edf6f604a63d8b4de3f6c4455bfecbe3f87d`.

| Item | Observed result |
| --- | --- |
| Ethereum chain ID | 1 |
| DEX | `0xf66c6c7a09e741843d4ede8795ac4267e3823037` |
| ABI hash, excluding `0x` | `f6010972b0d0d9921d0fa669a45d5cf65fa77fea787747255a5d70df92e3ae75` matches supplied attestation |
| Compiled and deployed runtime hash | `0x746cd8aacdef39b53cd5eb110af6c5ae6a630ab9b17adc1d650ca04f3aa25344` matches |
| Configuration source | Actual DEX reads; no guessed router, creator or IMD address |
| Before a transaction | Runtime and chain checked, wallet account/chain rechecked, quote age and version checked, balance/allowance read, contract call simulated |
| Spend protection | Exact gross approval; reset an existing insufficient nonzero allowance before a new approval; no unlimited approval |
| Purchase encoding | Supplied stock, exact gross IMD, floor-rounded positive minimum output, latest block timestamp + 300 seconds, reviewed version |
| Confirmation | Successful receipt **and** expected `Approval` / `StockPurchased` log from the expected contract/account |
| Slow confirmation | Persist hash per account; explicit confirmation check; no automatic resubmission |

Full read evidence is in [contract-verification.json](docs/website-validation/contract-verification.json). Runtime verification also runs in the application before enabling trading and again before writes. Public RPC responses are a trust dependency; this is not cryptographic verification of an RPC's truthfulness.

## Commands and actual results

Commands ran from the repository root unless noted. Temporary dependencies and browsers were installed under `/tmp`, with a removable `web/node_modules` symlink during the build. No dependency directory is delivered.

| Command / check | Result |
| --- | --- |
| `npm install --prefix /tmp/imd-frontend --cache /tmp/imd-npm-cache --no-audit --no-fund` | Success; 83 packages. Frontend manifest and resulting lockfile preserved under `web/`. |
| Copy delivered manifest/lockfile to `/tmp/imd-clean-install`, then `npm ci --prefix /tmp/imd-clean-install --cache /tmp/imd-npm-cache --no-audit --no-fund` | Exit 0; clean locked install, 83 packages. |
| `npm --prefix web run typecheck` | Exit 0 (`tsc --noEmit`). |
| `npm --prefix web run build` | Exit 0. Final Vite output: HTML 1.41kB, CSS 29.87kB, JS chunks 11.79kB / 258.24kB / 261.23kB, plus local icon, share image and license text. No chunk-size warning after splitting Ethereum dependencies. |
| `node web/scripts/verify-contracts.mjs --record` | Exit 0; ABI, pinned runtime and live Ethereum runtime match. |
| `node test/scratch/interactions.mjs` | Exit 0; 15/15 production-export scenarios in Chromium 154.0.8037.0. |
| `TEST_ENGINE=webkit WEBKIT_PATH=/tmp/imd-webkit-libs/run-webkit.sh node test/scratch/interactions.mjs` | Exit 0; the same 15/15 scenarios in WebKit 26.6. |
| `IMD_PLAYWRIGHT=/opt/imd-tools/mcp-suite/node_modules/playwright/index.mjs node .imd/reads/skills/design-critic/scripts/taste.mjs --out test/scratch/taste` | Exit 0; 16/16 pinned taste checks pass. |
| `node test/scratch/a11y.mjs` | Exit 0; axe-core 4.11.0 found zero violations on five inspected views/states with WCAG 2 A/AA, 2.1 A/AA and 2.2 AA tags. |
| `node test/scratch/stress.mjs` | Exit 0; no page overflow at 1440px with 200% root text size, RTL direction or forced colors. |
| MCP browser inspection at `/preview/` | Final live export inspected at 390 × 844 and 1440 × 1000. Main action bottom at 618.17px on the 390px screen. Local assets and Ethereum RPC returned 200; browser reported 0 console warnings/errors. |

The worker wrote bounded, self-contained test servers and fixtures in `test/scratch/`, as provided by the assignment. Those test harnesses are removed before submission; their final results are preserved in `docs/website-validation/`. The standard build and contract verification script remain reproducible from submitted source. The taste inputs are likewise supplied by the assignment, not application dependencies.

WebKit initially lacked host libraries and an EGL implementation. Ubuntu library packages were downloaded and extracted under `/tmp/imd-webkit-libs`, without installing into system directories or the repository. A wrapper selected those libraries and the matching Mesa version; WebKit then completed the suite. No browser archives, `.deb` files, dependency caches or wrappers are part of the submission.

## Interaction coverage

Both engine reports contain the following 15 passed scenarios. They exercised the production bundle through a `/preview/` subpath with RPC interception and a test-only EIP-1193/EIP-6963 provider. All external traffic was blocked or intercepted in these tests; the wallet fixture could not broadcast to Ethereum.

1. Catalog search by name, sector filtering, paging, empty search recovery, available-stock filtering, saved watchlist persistence/removal, and selected-stock updates.
2. No-wallet dialog, Escape dismissal, focus return and keyboard order from settings into the amount field.
3. Rejected connection, retry, wrong chain, explicit network switch and account-change invalidation.
4. Exact approval followed by a separately reviewed purchase; assertion of spender, amount, stock, minimum output, deadline and version.
5. Reset of a nonzero insufficient allowance and recovery after a declined transaction request.
6. Invalid/exponential/overprecision amounts, balance limits, max amount, slippage selection and expiry of a transaction review.
7. Configuration changes before submission, automatic version refresh and disabling a removed market.
8. Portfolio token balances, empty onchain history, a 51-line CSV (header + 50 stocks), and skip-link route preservation.
9. Reverted transaction without a false success state.
10. Canceled/unrelated receipt without a false success state.
11. Offline RPC recovery and disabling trading for mismatched deployed runtime.
12. Paused, unconfigured and absent-quoter states.
13. Automatic/manual quote renewal and rejection of stale asynchronous results after input edits.
14. Confirmation timeout, pending-hash persistence across reload and confirmation without another submission.
15. Reflow at 320, 390, 768, 1024 and 1440px, first-screen mobile action, reduced-motion behavior and no uncaught page errors.

Results: [Chromium](docs/website-validation/interactions-chromium.json), [WebKit](docs/website-validation/interactions-webkit.json), [accessibility](docs/website-validation/accessibility.json), [stress checks](docs/website-validation/stress.json), [taste summary](docs/website-validation/taste.json).

## Better Interface review

The pinned workflow and core principles of all six domains were read before implementation. Applicable form, keyboard/focus, screen-reader semantics, motion/reflow and documentation guidance was also consulted. The visual idea is a dark trading desk with a single lime purchase action. Review covered actual rendered screens and interactions as well as source. It was not delegated to other agents.

| Domain | Coverage and evidence | Unperformed or not applicable |
| --- | --- | --- |
| Accessibility — Checked | Native controls and labels; named icon buttons; skip link; native dialog focus containment/return; keyboard purchase entry; field errors; role/status messages; axe on five states; visible focus inspected in the browser. | No screen-reader session, hardware input-device check or comprehensive WCAG audit. Connected wallet review was exercised functionally, not included in the five-state axe scan. |
| Layout — Checked | Desktop/mobile screenshots; 320/390/768/1024/1440 reflow; trade-first mobile DOM order; header wrap at 200% text; RTL overflow; no sticky element covering text. | Browser-native 200% zoom and a physical phone were not tested. RTL was a layout stress test, not a localized product. Pseudo-localization was not performed. |
| Writing — Checked | “Unavailable” distinguished from zero; unlisted/paused/network states; recovery actions; exact spend, minimum receipt and fee wording; local-only watchlist explained; no invented market history or portfolio value. | Issuer legal terms/authenticity are not established by this UI review. |
| Typography — Checked | Six-size scale, two weights, system-font fallback, tabular data, 16px mobile controls, long names and complete address wrapping; exact amounts in review. | Font appearance on physical iOS/Android was not verified. There is no custom webfont to load. |
| Colors — Checked | Rendered taste contrast passes; explicit status words; single primary action; declared contrast pairs calculated in DESIGN.md; forced-colors reflow. | No light theme exists. An exhaustive focus-color audit across every possible wallet/provider state was not performed. |
| UI — Checked | Loading, disabled, empty, retry, wrong-chain, review, pending, success and failure states exercised; flat surfaces; native disclosures; reduced motion with no running animation. | No autoplay/media/carousel exists. No 10%-speed animation-panel review was needed for a staged animation because none is implemented; short hover/press transitions were inspected normally. |

Taste found all 46 measured mobile controls at least 24px or adequately spaced. Thirty compact controls were below its optional 44px comfort target; this remains an explicit density tradeoff. The first screen contains 16 measured prose words at 390px, below the 60-word threshold.

## Findings, corrections and rechecks

Source locations refer to the final source, where the correction can be inspected.

| Severity | Source | Finding / evidence | Correction and final recheck |
| --- | --- | --- | --- |
| High | `web/src/App.tsx:248`, `web/src/style.css:377` | Initial CSS moved the form above the catalog on mobile while keyboard/DOM order still visited the catalog first. | Trade is first in the DOM; desktop grid places it in column 2. Keyboard sequence passed in both engines. |
| High | `web/src/style.css:728`, `web/src/style.css:771` | Initial taste run flagged two nested filled form surfaces within a filled outer trade card on the first screen. | Removed the outer card treatment; kept useful input surfaces and a desktop structural separator. Final chrome check passes with 0 nested cards and 0 border-plus-shadow surfaces. |
| Medium | `web/src/chain.ts:401` | A raw injected-wallet rejection did not use the recoverable wording used by viem errors. | Normalize code 4001 and rejection messages. Rejection/retry scenario passes in both engines. |
| High | `web/src/Trade.tsx:284` | A successful receipt alone could mislabel an unrelated replacement as an approved purchase. | Require matching contract, event, account, stock/amount or approval fields. Reverted and unrelated-receipt scenarios both pass. |
| Medium | `web/src/Trade.tsx:117` | Switching automatic refresh off changed an effect dependency and could launch an unexpected new quote. The expanded Chromium timer test exposed the race. | Separate the auto-refresh flag from quote dependency identity; gate new snapshot refreshes via a ref. Manual/automatic and stale-result tests pass in both engines. |
| High | `web/src/style.css:202` | At 200% root text size, the header extended to 1616px in a 1440px viewport. | Allow header wrapping with a smaller row gap. Recheck reports 1440px scroll width and no overflow. |
| Medium | `web/src/Trade.tsx:182`, `web/src/Trade.tsx:350`, `web/src/Trade.tsx:754` | Changing account or chain during review could leave a review attached to the preceding wallet state. | Invalidate the review, recheck provider session before writes, and require an account to render it. Account-change test passes; completion is only displayed for its associated account. |

All reproduced applicable high/medium findings above were fixed. No unresolved application defect was observed in the covered states. The review does not infer safety or behavior beyond those checks.

## Rendered evidence

The screenshots below were made from the final production export with live RPC reads, without a mock wallet. Both were opened and visually inspected. Their quotes are observations at capture time only.

- [390 × 844 mobile first screen](docs/website-validation/mobile-390.png): product, stock selector, IMD amount and primary action visible; action bottom measured at 618.17px.
- [1440 × 1000 desktop first screen](docs/website-validation/desktop-1440.png): catalog, price availability, quote form and network state visible.

Additional 320/768/1024, keyboard, empty-state, stress and mocked-flow screenshots were inspected or generated in `test/scratch/`; those disposable test files are not packaged as deliverables.

## Remaining limits

- No real approval/purchase or deployed-wallet integration was executed. Tests validate the client flow and encoded requests under controlled responses, not mainnet execution guarantees.
- Only NVIDIA was enabled during the live check. The other supplied stocks cannot be bought or priced through this DEX until their owner-controlled routes are enabled and quotable. The website intentionally does not fabricate those prices.
- No WalletConnect QR flow, fiat funding, stock sale/redemption, issuer verification, historical price series or USD portfolio valuation is provided by the pinned DEX or this scope.
- RPC rate limits, liquidity changes, token restrictions, wallet implementation differences and transaction replacement behavior in real extensions remain external integration risks.
- Public RPC reads and wallet access require connectivity. The shell, catalog, local watchlist and error recovery render offline; real balances and quotes do not.
- Static metadata includes all requested fields and a local PNG. A final host is not known in this assignment, so the publisher may need an absolute share-image URL for strict crawlers. No hosting or publishing was performed.
- Screen readers, physical devices, native browser zoom and exhaustive localization were not tested. The guide's unperformed optional checks are recorded rather than labeled passed.

## Packaging

The original Solidity, Foundry configuration and dependencies are unchanged. Source and frontend build configuration are isolated under `web/`; the required static export is in root `dist/`. `DESIGN.md`, this report and README instructions accompany the source. Saved test summaries and two compact screenshots are documentation, not runtime dependencies. Existing ignore files were not changed; no path-budget exception was needed.

The final path and byte audit is recorded in `docs/website-validation/package-audit.json`. It conservatively measures the complete visible submission file set, includes the existing project and the export, and checks for prohibited changes, dependencies, caches, symlinks and submodules. Scratch files and assignment inputs are excluded as specified by the task.

The final materialized file set is approximately **2.58 MiB** and the production export is **647,575 bytes**. A compressed snapshot of the full materialized submission is approximately **1 MiB**, kept outside the repository for measurement. Direct `git bundle create` could not finish: this partial clone tried to fetch a missing historical object into the read-only `.git/objects/pack` directory. No Git metadata was changed. The exact publisher-created Git bundle size is therefore unmeasured; the audited file set plus a 1 MiB metadata reserve is below 8 MiB.
