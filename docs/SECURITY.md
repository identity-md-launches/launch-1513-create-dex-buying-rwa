# Validation and trust boundaries

This is the implementation author's local review record, not an independent security audit.

## Value flow

The DEX accepts an exact gross IMD amount from the caller, approves exactly the net amount to the configured router, and delivers stock directly to the caller. The supply-reducing burn and creator payment occur in the same transaction. There is no fee withdrawal queue or pending purchase balance. Errors revert token transfers, burns, approvals, and events atomically.

Balance differences are checked at the input transfer, router spend, stock receipt, burn, creator payment, and final DEX balance. Preexisting donations are excluded from the purchase accounting. Router allowances are zero at transaction completion. Reentrancy protection covers buying, quoting, recovery, and all configuration/pausing functions; even a router that is also the owner cannot alter a market during a purchase.

## Local checks

| Area | Evidence |
| --- | --- |
| Fee conservation | Example purchases, dust boundaries, creator-as-buyer, full-range uint256 fuzzing of fee arithmetic using an independent long-division reference, randomized successful purchase accounting. |
| Stateful conservation | Multi-buyer handler interleaves purchases, venue failures, donations, recoveries, fee-split changes, pause/unpause, and market disable/re-enable. Invariants check total supply plus burned equals minted, exact creator/router/donation balances, stock delivery, and zero router allowance. Default campaign: 128 runs × 32 actions. |
| Real protocol integration | Offline deployment of published v3-core 1.0.1 factory/pool bytecode and v3-periphery 1.4.4 router/quoter bytecode. Tests create liquidity locally, compare quotes with purchases, exercise direct/multihop paths, missing pools, adverse price movement, slippage, and randomized inputs. IMD and stocks remain explicit test doubles. |
| Atomic failure | Missing allowance, wrong payment asset, expired orders, zero minimum output, missing/disabled markets, rejected stock transfers, creator transfer failures, burn failures, no-op burns, deceptive router outputs, incomplete input spending, and insufficient output all revert without collecting fees. |
| Token edge cases | Non-returning ERC20 methods succeed; false returns, observed transfer taxes, and extra buyer debits fail. Recipient restrictions propagate. No general compatibility claim for rebasing or malicious tokens. |
| Reentrancy | Callbacks attempted from transferFrom, transfer, approve, burn, and the router are rejected. A router made owner cannot reenter configuration. |
| Administration | Non-owner rejection across every administrative entry, pause requirements, explicit owner constructor, two-step handover/cancellation, disabled renunciation, invalid addresses/splits/paths (including the creator never being the router or quoter and vice versa), immutable chosen IMD, recoveries, configuration-version invalidation, vanished dependencies. |
| Quote honesty | Exhausted single-hop and intermediate-hop liquidity on real v3 bytecode is rejected by `quoteBuy` (`InsufficientLiquidity`) where QuoterV2 alone would report a partial fill; quoters returning the wrong number of hop prices are rejected (`InvalidQuote`); orders inside available liquidity quote and execute identically. |
| Fee scope | A real-bytecode test records that every DEX purchase pays the fee and that a swap sent straight to the public pool does not, documenting the boundary stated in the README. |
| Deployment policy | Factory-based constructor rehearsal with the supplied launch owner and no configured dependencies. Runtime and initcode size bounds plus disassembled runtime scan rejecting DELEGATECALL, CALLCODE, and SELFDESTRUCT. No library links, proxies, constructor external calls, or payable construction. |

All tests use local state and deterministic setup, with no environment access, RPC, FFI, or filesystem permissions. Compiler: Solidity 0.8.26. `forge build`, `forge test`, and `forge fmt --check` are the required commands. Dependencies and test fixtures are vendored for offline verification.

## Reviewed lint findings

Foundry's heuristic lints flag external calls/events despite the shared OpenZeppelin reentrancy guard. They also flag the deliberate deadline check, exact balance-delta conservation checks, bounded path-validation loops, and division-before-multiplication. The fee decomposition includes the remainder term, so it equals full-precision floor division without overflowing. The router's return value and received balances are checked. Of the quote metadata, the per-hop price after the simulated swap is checked against the v3 tick-math bounds to reject partial fills; the crossed-tick counts and gas estimate are discarded. These findings were reviewed against the code and adversarial tests, rather than disabled globally.

Slither and Mythril are not installed and were not run. No independent audit, mainnet fork, issuer onboarding, or production address/code verification is claimed.

## Remaining external assumptions

- The 0.5% fee, burn, and creator payment are enforced on every purchase through `buyStock` and on nothing else. Listed stocks trade on public Uniswap pools the DEX does not own or gate; a direct pool swap pays only Uniswap's fee. This is a documented boundary of the approved design (see the README's "Scope of the fee"), not a configuration the owner can close.

- The owner correctly identifies IMD, compatible original v3 router/QuoterV2 contracts, and genuine stock assets. Code existence is not authentication. IMD is set once; a mistaken choice requires redeployment.
- IMD supports public `burn(uint256)` from the DEX's balance and reports honest balances and supply. It is not taxed or rebasing. This has not been checked on a production IMD deployment because no canonical address was provided.
- Listed routes have liquidity and tokens support their intended issuer/AMM transfer paths. An issuer or venue pause may make a purchase unavailable, but cannot create a partially settled purchase here.
- The creator receives IMD successfully; a blocked recipient causes the whole trade to fail. Resolve through the owner-controlled recipient setting while paused.
- User-supplied slippage and deadline are meaningful. Quotes are market simulations, not a stock-value oracle, and can change before execution. There is no additional TWAP or USD oracle check.
- Administrative reconfiguration is immediate while paused. The version check prevents queued orders from silently accepting changed settings, but users still trust the owner to list authentic assets and choose sound external contracts.
- Tokens sent directly to the DEX are recoverable by the owner. The application offers no deposit-account promise. Forced ETH has no recovery path.
