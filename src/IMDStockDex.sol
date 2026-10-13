// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBurnableIMD} from "./interfaces/IBurnableIMD.sol";
import {IUniswapV3Router, IUniswapV3Quoter} from "./interfaces/IUniswapV3.sol";

/// @title IMDStockDex
/// @notice Buy owner-listed tokenized stocks with IMD through Uniswap v3. The 50 bps fee is
///         split between a verifiable supply-reducing burn and the configured creator, atomically.
/// @dev No token issuance, price oracle, inventory, user deposits, or arbitrary router calldata.
contract IMDStockDex is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant FEE_BPS = 50;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_HOPS = 4;
    uint256 private constant FEE_DIVISOR = BPS / FEE_BPS;

    IERC20 public imd;
    IUniswapV3Router public router;
    IUniswapV3Quoter public quoter;
    address public creator;
    uint16 public burnShareBps;
    uint256 public configVersion;

    struct Market {
        bytes path;
        bool enabled;
    }

    struct FeeBreakdown {
        uint256 swapAmount;
        uint256 fee;
        uint256 burnAmount;
        uint256 creatorAmount;
    }

    mapping(address stock => Market) private markets;

    error NotConfigured();
    error QuoterNotConfigured();
    error IMDAlreadyConfigured();
    error InvalidAddress();
    error NotAContract(address account);
    error InvalidSplit();
    error InvalidPath();
    error MarketNotEnabled(address stock);
    error AmountTooSmall();
    error ZeroMinimumOutput();
    error DeadlineExpired();
    error ConfigurationChanged(uint256 expected, uint256 actual);
    error UnexpectedTokenBalance(address token);
    error InsufficientOutput(uint256 received, uint256 minimum);
    error InvalidBurn();
    error RenounceDisabled();

    event IMDConfigured(address indexed token);
    event RouterConfigured(address indexed router);
    event QuoterConfigured(address indexed quoter);
    event FeeDistributionConfigured(address indexed creator, uint16 burnShareBps);
    event MarketConfigured(address indexed stock, bytes path);
    event MarketDisabled(address indexed stock);
    event ConfigurationVersionChanged(uint256 indexed version);
    event StockPurchased(
        address indexed buyer,
        address indexed stock,
        uint256 grossIMD,
        uint256 stockReceived,
        uint256 fee,
        uint256 burned,
        uint256 creatorPaid,
        address creator,
        uint256 configVersion
    );
    event TokenRecovered(address indexed token, address indexed recipient, uint256 amount);

    /// @param initialOwner Explicit launch owner; never inferred from the deploying factory.
    /// @dev No dependency calls or code checks in the constructor. Starts paused and unconfigured.
    constructor(address initialOwner) Ownable(initialOwner) {
        _pause();
    }

    /// @notice Select the canonical IMD once, after verifying its identity and burn compatibility.
    function setIMD(address token) external nonReentrant onlyOwner whenPaused {
        if (address(imd) != address(0)) revert IMDAlreadyConfigured();
        _requireContract(token);
        if (
            token == address(this) || token == creator || token == address(router) || token == address(quoter)
        ) {
            revert InvalidAddress();
        }
        imd = IERC20(token);
        _bumpVersion();
        emit IMDConfigured(token);
    }

    function setRouter(address newRouter) external nonReentrant onlyOwner whenPaused {
        _requireContract(newRouter);
        if (newRouter == address(this) || newRouter == address(imd)) revert InvalidAddress();
        router = IUniswapV3Router(newRouter);
        _bumpVersion();
        emit RouterConfigured(newRouter);
    }

    function setQuoter(address newQuoter) external nonReentrant onlyOwner whenPaused {
        _requireContract(newQuoter);
        if (newQuoter == address(this) || newQuoter == address(imd)) revert InvalidAddress();
        quoter = IUniswapV3Quoter(newQuoter);
        _bumpVersion();
        emit QuoterConfigured(newQuoter);
    }

    /// @notice Shares are of the 0.5% fee, not of the purchase. Both beneficiaries must have a share.
    function setFeeDistribution(address newCreator, uint16 newBurnShareBps)
        external
        nonReentrant
        onlyOwner
        whenPaused
    {
        if (newCreator == address(0) || newCreator == address(this) || newCreator == address(imd)) {
            revert InvalidAddress();
        }
        if (newBurnShareBps == 0 || newBurnShareBps >= BPS) revert InvalidSplit();
        creator = newCreator;
        burnShareBps = newBurnShareBps;
        _bumpVersion();
        emit FeeDistributionConfigured(newCreator, newBurnShareBps);
    }

    /// @notice List a genuine stock token and its forward v3 route: IMD | fee | token [| fee | token].
    /// @dev The owner attests stock authenticity and usable pools; code checks do not establish either.
    function setMarket(address stock, bytes calldata path) external nonReentrant onlyOwner whenPaused {
        if (address(imd) == address(0)) revert NotConfigured();
        if (stock == address(this) || stock == address(imd)) revert InvalidAddress();
        _requireContract(stock);
        _validatePath(stock, path);
        markets[stock] = Market(path, true);
        _bumpVersion();
        emit MarketConfigured(stock, path);
    }

    /// @notice A problematic listing can be disabled immediately without pausing other markets.
    function disableMarket(address stock) external nonReentrant onlyOwner {
        if (!markets[stock].enabled) revert MarketNotEnabled(stock);
        markets[stock].enabled = false;
        _bumpVersion();
        emit MarketDisabled(stock);
    }

    function market(address stock) external view returns (bytes memory path, bool enabled) {
        Market storage selected = markets[stock];
        return (selected.path, selected.enabled);
    }

    function pause() external nonReentrant onlyOwner {
        _pause();
        _bumpVersion();
    }

    function unpause() external nonReentrant onlyOwner {
        _requireConfigured();
        _unpause();
        _bumpVersion();
    }

    /// @notice Gross input includes the fee. Rounds the fee up to prevent fee avoidance by splitting.
    /// @dev Burn rounds down, creator gets the remainder. Tiny orders that cannot fund both revert.
    ///      Division-first decomposition avoids overflow even for uint256.max gross input.
    function previewFees(uint256 grossIMD) public view returns (FeeBreakdown memory fees) {
        if (creator == address(0) || burnShareBps == 0) revert NotConfigured();
        fees.fee = grossIMD / FEE_DIVISOR + (grossIMD % FEE_DIVISOR == 0 ? 0 : 1);
        fees.swapAmount = grossIMD - fees.fee;
        fees.burnAmount = (fees.fee / BPS) * burnShareBps + (fees.fee % BPS) * burnShareBps / BPS;
        fees.creatorAmount = fees.fee - fees.burnAmount;
        if (fees.swapAmount == 0 || fees.burnAmount == 0 || fees.creatorAmount == 0) revert AmountTooSmall();
    }

    /// @notice Simulate via eth_call for an indicative stock amount, fees, and a buy configuration version.
    /// @dev A quote is not an oracle or a price guarantee. The buyer must choose minStockOut and deadline.
    function quoteBuy(address stock, uint256 grossIMD)
        external
        nonReentrant
        returns (uint256 stockOut, FeeBreakdown memory fees, uint256 version)
    {
        _requireConfigured();
        if (address(quoter) == address(0)) revert QuoterNotConfigured();
        bytes memory path = _marketPath(stock);
        fees = previewFees(grossIMD);
        version = configVersion;
        (stockOut,,,) = quoter.quoteExactInput(path, fees.swapAmount);
    }

    /// @notice Spend the caller's approved IMD and deliver listed stock directly to the caller.
    /// @param expectedVersion The configVersion read when preparing this purchase. No wildcard value.
    /// @dev Any failed swap, transfer, burn, or balance check rolls back every effect, including fees.
    function buyStock(
        address stock,
        uint256 grossIMD,
        uint256 minStockOut,
        uint256 deadline,
        uint256 expectedVersion
    ) external nonReentrant returns (uint256 stockOut) {
        _requireConfigured();
        _requireNotPaused();
        if (expectedVersion != configVersion) revert ConfigurationChanged(expectedVersion, configVersion);
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (minStockOut == 0) revert ZeroMinimumOutput();
        bytes memory path = _marketPath(stock);
        FeeBreakdown memory fees = previewFees(grossIMD);

        uint256 initialBalance = imd.balanceOf(address(this));
        uint256 buyerBalance = imd.balanceOf(msg.sender);
        imd.safeTransferFrom(msg.sender, address(this), grossIMD);
        _requireIncrease(imd, address(this), initialBalance, grossIMD);
        _requireDecrease(imd, msg.sender, buyerBalance, grossIMD);

        stockOut = _swap(stock, path, fees.swapAmount, minStockOut, deadline);
        _burn(fees.burnAmount);
        _payCreator(fees.creatorAmount);
        if (imd.balanceOf(address(this)) != initialBalance) revert UnexpectedTokenBalance(address(imd));

        emit StockPurchased(
            msg.sender,
            stock,
            grossIMD,
            stockOut,
            fees.fee,
            fees.burnAmount,
            fees.creatorAmount,
            creator,
            expectedVersion
        );
    }

    /// @notice Recover tokens sent outside buyStock. Successful trades never leave user funds here.
    function recoverToken(address token, address recipient, uint256 amount)
        external
        nonReentrant
        onlyOwner
        whenPaused
    {
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
        IERC20(token).safeTransfer(recipient, amount);
        emit TokenRecovered(token, recipient, amount);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function _swap(address stock, bytes memory path, uint256 amountIn, uint256 minimum, uint256 deadline)
        private
        returns (uint256 stockOut)
    {
        uint256 stockBefore = IERC20(stock).balanceOf(msg.sender);
        uint256 imdBefore = imd.balanceOf(address(this));
        imd.forceApprove(address(router), amountIn);
        uint256 reported = router.exactInput(
            IUniswapV3Router.ExactInputParams({
                path: path,
                recipient: msg.sender,
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minimum
            })
        );
        imd.forceApprove(address(router), 0);
        _requireDecrease(imd, address(this), imdBefore, amountIn);

        uint256 stockAfter = IERC20(stock).balanceOf(msg.sender);
        if (stockAfter < stockBefore) revert UnexpectedTokenBalance(stock);
        stockOut = stockAfter - stockBefore;
        if (stockOut < minimum) revert InsufficientOutput(stockOut, minimum);
        if (stockOut != reported) revert UnexpectedTokenBalance(stock);
    }

    function _burn(uint256 amount) private {
        uint256 supplyBefore = imd.totalSupply();
        uint256 balanceBefore = imd.balanceOf(address(this));
        IBurnableIMD(address(imd)).burn(amount);
        uint256 supplyAfter = imd.totalSupply();
        if (supplyAfter > supplyBefore || supplyBefore - supplyAfter != amount) revert InvalidBurn();
        _requireDecrease(imd, address(this), balanceBefore, amount);
    }

    function _payCreator(uint256 amount) private {
        uint256 creatorBefore = imd.balanceOf(creator);
        uint256 balanceBefore = imd.balanceOf(address(this));
        imd.safeTransfer(creator, amount);
        _requireIncrease(imd, creator, creatorBefore, amount);
        _requireDecrease(imd, address(this), balanceBefore, amount);
    }

    function _requireConfigured() private view {
        if (address(imd) == address(0) || address(router) == address(0) || creator == address(0)) {
            revert NotConfigured();
        }
        // Detect vanished dependencies before accepting funds.
        _requireContract(address(imd));
        _requireContract(address(router));
    }

    function _marketPath(address stock) private view returns (bytes memory) {
        if (!markets[stock].enabled) revert MarketNotEnabled(stock);
        return markets[stock].path;
    }

    function _validatePath(address stock, bytes calldata path) private view {
        if (path.length < 43 || path.length > 20 + MAX_HOPS * 23 || (path.length - 20) % 23 != 0) {
            revert InvalidPath();
        }
        uint256 hops = (path.length - 20) / 23;
        if (_pathToken(path, 0) != address(imd) || _pathToken(path, hops * 23) != stock) {
            revert InvalidPath();
        }
        for (uint256 i; i <= hops; ++i) {
            address token = _pathToken(path, i * 23);
            _requireContract(token);
            if (token == address(this)) revert InvalidPath();
            // Disallow repeated tokens, so the route cannot loop through IMD or the stock.
            for (uint256 j; j < i; ++j) {
                if (token == _pathToken(path, j * 23)) revert InvalidPath();
            }
            if (i < hops) {
                uint24 poolFee = uint24(bytes3(path[i * 23 + 20:i * 23 + 23]));
                if (poolFee == 0 || poolFee >= 1_000_000) revert InvalidPath();
            }
        }
    }

    function _pathToken(bytes calldata path, uint256 offset) private pure returns (address) {
        return address(bytes20(path[offset:offset + 20]));
    }

    function _requireContract(address account) private view {
        if (account == address(0)) revert InvalidAddress();
        if (account.code.length == 0) revert NotAContract(account);
    }

    function _requireIncrease(IERC20 token, address account, uint256 beforeBalance, uint256 amount)
        private
        view
    {
        uint256 afterBalance = token.balanceOf(account);
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
            revert UnexpectedTokenBalance(address(token));
        }
    }

    function _requireDecrease(IERC20 token, address account, uint256 beforeBalance, uint256 amount)
        private
        view
    {
        uint256 afterBalance = token.balanceOf(account);
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) {
            revert UnexpectedTokenBalance(address(token));
        }
    }

    function _bumpVersion() private {
        emit ConfigurationVersionChanged(++configVersion);
    }
}
