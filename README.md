# IMD Stock DEX

`IMDStockDex` buys existing, owner-listed tokenized stocks using **IMD only**, through the original **Uniswap v3 SwapRouter**. Each successful purchase charges a fixed **0.5% application fee** in IMD. The configured portion is burned by reducing IMD's supply; the rest is transferred to the configured creator in the same transaction. Purchased stocks go directly to the buyer.

This is a contracts-only Ethereum application. It does not issue stock tokens, create liquidity pools, or implement a sell/redemption flow. Uniswap supplies execution prices and liquidity. Listing a token does not establish its issuer, backing, or redemption rights.

## Build and check

From this repository's root, with Foundry and Solidity **0.8.26** available:

```sh
forge build
forge test
forge fmt --check
```

All Solidity dependencies and the Uniswap integration fixtures are ordinary vendored files. No install, RPC, fork, environment variables, keys, FFI, or filesystem cheatcodes are required. `foundry.toml` pins the compiler, optimizer, Cancun EVM target, and `bytecode_hash = "none"`. Compiler binaries are not included.

Tests cover actual Uniswap v3 bytecode as well as adversarial token/router doubles, randomized fee arithmetic, and stateful accounting invariants. See [validation and trust boundaries](docs/SECURITY.md) and [dependency provenance](THIRD_PARTY.md).

## Purchase and price semantics

1. Read `market(stock)`, the current configuration, and `previewFees(grossIMD)`.
2. Simulate `quoteBuy(stock, grossIMD)` using **eth_call**, obtaining the stock amount, fee breakdown, and `configVersion`. It is intentionally not `view`: Uniswap QuoterV2 uses simulated pool swaps. Quoting is available while paused so the owner can check configuration before opening trading.
3. Choose a positive `minStockOut` and an absolute Unix `deadline`. Refresh the quote if market conditions or configuration change. The quote is indicative, not an oracle or guaranteed execution price.
4. Approve the DEX for the gross IMD amount.
5. From the buyer's wallet call:

```solidity
dex.buyStock(stock, grossIMD, minStockOut, deadline, quotedConfigVersion);
```

There is no payment-token argument, arbitrary recipient, or user-supplied routing calldata. The DEX always pulls its configured IMD from `msg.sender`, uses the owner's listed route, and sends stock to `msg.sender`. ETH and other payment assets are rejected. The deadline is inclusive (`block.timestamp <= deadline`). A configuration version mismatch reverts; there is no wildcard version.

The DEX approves the router for exactly the net amount, clears that allowance afterward, and checks that the router spent the entire amount. It checks the buyer's actual stock balance increase against both the minimum and the router's reported output. Partial-input execution reverts. The subsequent burn and creator transfer must also succeed. Any failure rolls back the whole purchase, including stock transfers and fees; transaction gas is still paid.

Prices are the **stock-token output for a given IMD input**, not USD stock-market prices or issuer NAV. Uniswap pool fees and price impact are additional to the application's 0.5% fee and are reflected in the quote. Values are raw token units: integrations must read each token's decimals and format appropriately. No assumption that all tokens have 18 decimals is made by the DEX.

## Fee economics and assumptions

The input is a **gross budget inclusive of the fee**. The brief does not specify the split between burning and the creator, so trading requires the owner to choose it; there is no assumed default or recipient.

For gross IMD `G` and the owner-selected burn share `S` (1–9,999 basis points of the fee):

```text
fee          = ceil(G / 200)                 // 0.5%, rounded up in IMD base units
swapAmount   = G - fee
burnAmount   = floor(fee * S / 10,000)
creatorPaid  = fee - burnAmount
```

Fee rounding up prevents splitting purchases into fee-free dust orders. Burn rounding goes down; the creator receives the remaining fee dust. An order must produce a positive swap amount, burn amount, and creator payment, otherwise `AmountTooSmall` reverts. `previewFees` exposes the exact calculation and rejects such orders. Arithmetic supports the full uint256 input range without intermediate multiplication overflow.

Illustration only: with a **60% burn / 40% creator** policy and a gross budget of **1,000 IMD**, **995 IMD** is swapped, **3 IMD** is burned, and **2 IMD** goes to the creator. The owner must set the actual policy.

**IMD compatibility is a deployment prerequisite.** The canonical IMD must be a standard, non-rebasing ERC20 supporting `burn(uint256)` on the caller's own balance, with no privileged burner role required. Every purchase checks that both the DEX's balance and `totalSupply()` decreased by the burn amount. A missing, paused, privileged, or no-op burn fails the purchase. Sending tokens to a dead address is not substituted for burning. This assignment supplied no IMD address, so its real implementation has not been verified. If the actual token cannot support this burn interface, this implementation must not be enabled for it.

IMD's identity is **set once** and cannot be replaced. Check it before calling `setIMD`; an incorrectly selected IMD requires a new application deployment. Standard ERC20s that omit boolean return data are supported. Transfer-tax and rebasing assets are unsupported; exact balance checks reject observed discrepancies. A malicious token can lie about balances or supply, so issuer/implementation validation remains essential.

## Deployment

Deploy exactly one application, Solidity name **`IMDStockDex`**, from `src/IMDStockDex.sol`. Do not deploy test mocks, fixtures, or the test constructor factory.

| Constructor argument | Type | Launch value |
| --- | --- | --- |
| `initialOwner` | `address` | `$owner`, resolving to `0xa82b930352712ad04de22c16114c12bb54b66e59` |

Target chain: **Ethereum mainnet, chain ID 1**. The nonpayable constructor accepts one static argument, assigns that explicit owner, and starts paused. It makes no external calls and requires no other deployed contract. No factory, `msg.sender`, or `tx.origin` is assigned ownership implicitly. It deploys without ETH and without a proxy or linked library.

The launch service supplies the manifest and confirmed address after acceptance; this repository intentionally supplies neither `launch.json` nor guessed deployment addresses. No broadcast script or signer is needed for local verification.

## After launch

The launch owner's wallet performs these ordinary administrative transactions. External contract addresses are deliberately **unset**, not filled with stand-ins. Unset required dependencies cause `NotConfigured`; an absent quote service causes `QuoterNotConfigured`.

| Setter/action | Required setting and where to obtain it |
| --- | --- |
| `setIMD(token)` | The canonical **Ethereum IMD** address from the requester/official IMD deployment record. Verify chain, code, implementation, identity, balance semantics, and the `burn(uint256)` behavior before this one-time choice. |
| `setRouter(router)` | The original Uniswap v3 **SwapRouter** from [Uniswap's Ethereum deployment reference](https://docs.uniswap.org/contracts/v3/reference/deployments/ethereum-deployments). Verify deployed code, verified ABI, and factory on chain. **SwapRouter02 and Universal Router have different ABIs and are not compatible with this integration.** |
| `setQuoter(quoter)` | **QuoterV2** for the same factory, from the same official deployment reference, after on-chain verification. Required for `quoteBuy`; purchases themselves do not consult it. |
| `setFeeDistribution(creator, burnShareBps)` | The creator's actual recipient address and the agreed proportional split, supplied by the requester/owner. Both shares must be nonzero. The recipient must be able to receive IMD. |
| `setMarket(stock, path)` | Each authentic stock-token contract address from its issuer's official deployment records, plus a verified, liquid Uniswap v3 path beginning with IMD and ending at that stock. Check every intermediate token, fee tier, pool, transfer restriction, and liquidity condition. For Ondo assets start with [Ondo's official documentation](https://docs.ondo.finance/); eligibility and AMM compatibility must be verified for the particular token. |
| `unpause()` | Enable purchases after settings, quotes, realistic transaction simulation, and the release review pass. The DEX checks global configuration; the owner is responsible for listing usable markets. |

All configuration setters require the owner and a paused application. They emit setting-specific events and increment `configVersion`. Pause, unpause, and market disable also increment the version, preventing old transactions from unexpectedly becoming executable after a reconfiguration/reopening. Configure in the order above and quote again after unpausing.

Paths use the original v3 forward encoding, **not** ABI encoding of an array:

```solidity
// These are variables containing verified addresses, not placeholder deployed addresses.
bytes memory direct = abi.encodePacked(imdAddress, uint24(poolFee), stockAddress);
bytes memory viaIntermediate = abi.encodePacked(
    imdAddress, uint24(firstPoolFee), intermediateToken, uint24(secondPoolFee), stockAddress
);
```

There can be 1–4 hops. Tokens must have code, addresses cannot repeat, and fees must be positive and below 1,000,000. These structural checks do not prove a pool exists or has liquidity. A successful quote is also not a guarantee of future liquidity.

## Operational responsibilities and powers

- **Owner:** authenticate IMD and every stock issuer; choose the creator and split; verify compatible router/quoter contracts, stock transfer eligibility, routes, and liquidity; monitor upstream upgrades/pauses; pause globally or call `disableMarket(stock)` immediately when needed. Route enabling/editing, router changes, creator changes, and split changes require a pause. The owner cannot change the 50 bps application fee or replace IMD after it is set.
- **Custody:** no user deposits or pending claims exist. Successful trades leave no new IMD or stock at the DEX. Preexisting donations are preserved. While paused, the owner can use `recoverToken(token, recipient, amount)` to recover tokens sent outside the purchase flow, including IMD. Direct token transfers to the DEX are donations, not purchases or protected deposits. Forced ETH is not recoverable.
- **Creator:** receives its fee share atomically. If IMD blocks the creator or a creator transfer fails, the entire purchase reverts without leaving funds queued. The owner must resolve the restriction or set an authorized replacement recipient while paused.
- **Buyers/integrators:** select a suitable minimum output and short deadline, display the gross/net fee breakdown and route, use the returned configuration version, verify token decimals, and refresh quotes. A very loose minimum remains exposed to adverse execution/MEV. The contract does not authenticate an off-chain quote or enforce an oracle price band.
- **Issuers/venues:** retain their external token and protocol powers. Stock transfers may be restricted, paused, or subject to eligibility checks. This DEX preserves those restrictions; it does not perform issuer onboarding or create a right to redeem underlying shares. Only assets compatible with both the buyer and AMM route should be enabled.
- **Administration handover:** `transferOwnership(nextOwner)` followed by `acceptOwnership()` by that recipient. Transferring to zero cancels a pending handover without changing the current owner. Renouncing ownership is disabled to avoid trapping configuration or incident response.
- **Release:** the launch operator and an independent contributor must review the selected deployment settings and external integrations before release with funds. The local tests do not certify token authenticity, current mainnet liquidity, or the requester's IMD burn compatibility.

Reference ABIs: [Uniswap SwapRouter](https://github.com/Uniswap/v3-periphery/blob/v1.4.4/contracts/interfaces/ISwapRouter.sol) and [QuoterV2](https://github.com/Uniswap/v3-periphery/blob/v1.4.4/contracts/interfaces/IQuoterV2.sol). The minimal interfaces in this repository preserve their argument and return layouts.
