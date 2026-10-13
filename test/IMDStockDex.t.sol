// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IMDStockDex} from "../src/IMDStockDex.sol";
import {MockToken} from "./mocks/MockTokens.sol";
import {MockVenue} from "./mocks/MockVenue.sol";

import {DexTestBase} from "./helpers/DexTestBase.sol";

contract IMDStockDexTest is DexTestBase {
    function test_buyUsesOnlyIMDAndDistributesExactFee() public {
        uint256 supplyBefore = imd.totalSupply();
        uint256 output = _buy(GROSS, 1990 ether);
        assertEq(output, 1990 ether);
        assertEq(stock.balanceOf(buyer), output);
        assertEq(imd.balanceOf(buyer), INITIAL - GROSS);
        assertEq(imd.balanceOf(address(venue)), 995 ether);
        assertEq(imd.balanceOf(creator), 2 ether);
        assertEq(supplyBefore - imd.totalSupply(), 3 ether);
        assertEq(imd.balanceOf(address(dex)), 0);
        assertEq(stock.balanceOf(address(dex)), 0);
        assertEq(imd.allowance(address(dex), address(venue)), 0);
        assertEq(venue.lastAmountIn(), 995 ether);
        assertEq(venue.lastMinimum(), 1990 ether);
        assertEq(venue.lastRecipient(), buyer);
        assertEq(venue.lastDeadline(), block.timestamp + 1 hours);
        assertEq(venue.lastPath(), _path());
    }

    function test_purchaseEventAccountsForEveryFeeUnit() public {
        uint256 version = dex.configVersion();
        vm.expectEmit(true, true, false, true, address(dex));
        emit IMDStockDex.StockPurchased(
            buyer, address(stock), GROSS, 1990 ether, 5 ether, 3 ether, 2 ether, creator, version
        );
        _buy(GROSS, 1);
    }

    function test_quoteUsesNetInputAndMatchesExecution() public {
        (uint256 out, IMDStockDex.FeeBreakdown memory fees, uint256 version) =
            dex.quoteBuy(address(stock), GROSS);
        assertEq(out, 1990 ether);
        assertEq(fees.swapAmount, 995 ether);
        assertEq(fees.fee, 5 ether);
        assertEq(fees.burnAmount, 3 ether);
        assertEq(fees.creatorAmount, 2 ether);
        assertEq(version, dex.configVersion());
        assertEq(_buy(GROSS, out), out);
    }

    function test_multipleHopsForwardedExactly() public {
        bytes memory path =
            abi.encodePacked(address(imd), uint24(3000), address(bridge), uint24(500), address(stock));
        vm.startPrank(owner);
        dex.pause();
        dex.setMarket(address(stock), path);
        dex.unpause();
        vm.stopPrank();
        _buy(GROSS, 1);
        assertEq(venue.lastPath(), path);
    }

    function test_decimalsAreRawUnitsNotAssumedEighteen() public {
        MockToken stock6 = new MockToken("SIX", 6);
        stock6.mint(address(venue), 10_000e6);
        vm.startPrank(owner);
        dex.pause();
        dex.setMarket(address(stock6), abi.encodePacked(address(imd), uint24(500), address(stock6)));
        dex.unpause();
        vm.stopPrank();
        venue.setRate(1, 1e12);
        uint256 version = dex.configVersion();
        vm.prank(buyer);
        uint256 out = dex.buyStock(address(stock6), GROSS, 995e6, block.timestamp, version);
        assertEq(out, 995e6);
        assertEq(stock6.balanceOf(buyer), 995e6);
    }

    function test_exactDeadlineIsAllowed() public {
        uint256 version = dex.configVersion();
        vm.prank(buyer);
        dex.buyStock(address(stock), GROSS, 1, block.timestamp, version);
    }

    function test_creatorCanBuyAndReceivesItsShare() public {
        imd.mint(creator, GROSS);
        uint256 version = dex.configVersion();
        vm.startPrank(creator);
        imd.approve(address(dex), GROSS);
        dex.buyStock(address(stock), GROSS, 1, block.timestamp, version);
        vm.stopPrank();
        assertEq(imd.balanceOf(creator), 2 ether);
        assertEq(stock.balanceOf(creator), 1990 ether);
    }

    function test_existingDonationsAreNotSpent() public {
        imd.mint(address(dex), 777);
        stock.mint(address(dex), 999);
        _buy(GROSS, 1);
        assertEq(imd.balanceOf(address(dex)), 777);
        assertEq(stock.balanceOf(address(dex)), 999);
    }

    function test_missingAllowanceRevertsWithoutFees() public {
        vm.prank(buyer);
        imd.approve(address(dex), 0);
        _buyReverts(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(dex), 0, GROSS),
            GROSS,
            1
        );
        _assertUnchanged();
    }

    function test_cannotSpendAnotherBuyersAllowance() public {
        address attacker = makeAddr("attacker");
        uint256 version = dex.configVersion();
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(dex), 0, GROSS)
        );
        dex.buyStock(address(stock), GROSS, 1, block.timestamp, version);
        _assertUnchanged();
    }

    function test_stockApprovalCannotPayForPurchase() public {
        address other = makeAddr("stock holder");
        stock.mint(other, GROSS);
        vm.prank(other);
        stock.approve(address(dex), GROSS);
        uint256 version = dex.configVersion();
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(dex), 0, GROSS)
        );
        dex.buyStock(address(stock), GROSS, 1, block.timestamp, version);
        assertEq(stock.balanceOf(other), GROSS);
    }

    function test_expiredDeadlineReverts() public {
        vm.warp(1234);
        uint256 version = dex.configVersion();
        vm.prank(buyer);
        vm.expectRevert(IMDStockDex.DeadlineExpired.selector);
        dex.buyStock(address(stock), GROSS, 1, 1233, version);
        _assertUnchanged();
    }

    function test_zeroMinimumReverts() public {
        _buyReverts(IMDStockDex.ZeroMinimumOutput.selector, GROSS, 0);
        _assertUnchanged();
    }

    function test_tinyAndZeroPurchasesRevert() public {
        for (uint256 i; i <= 200; ++i) {
            vm.expectRevert(IMDStockDex.AmountTooSmall.selector);
            dex.previewFees(i);
        }
        _buyReverts(IMDStockDex.AmountTooSmall.selector, 0, 1);
        _assertUnchanged();
    }

    function test_feeRoundsUpAndSplitConservesDust() public {
        IMDStockDex.FeeBreakdown memory fees = dex.previewFees(201);
        assertEq(fees.fee, 2);
        assertEq(fees.burnAmount, 1);
        assertEq(fees.creatorAmount, 1);
        assertEq(fees.swapAmount, 199);
        _buy(201, 398);
        assertEq(imd.balanceOf(creator), 1);
        assertEq(imd.totalSupply(), INITIAL - 1);
    }

    function test_venueSlippageRevertsAllEffects() public {
        _buyReverts(MockVenue.TooLittleReceived.selector, GROSS, 1990 ether + 1);
        _assertUnchanged();
    }

    function test_dexChecksSlippageEvenIfRouterIgnoresMinimum() public {
        venue.setFaults(false, true, 0, 0);
        _buyReverts(
            abi.encodeWithSelector(IMDStockDex.InsufficientOutput.selector, 1990 ether, 2000 ether),
            GROSS,
            2000 ether
        );
        _assertUnchanged();
    }

    function test_routerCannotLieAboutOutput() public {
        venue.setFaults(false, false, 0, 1);
        _buyReverts(
            abi.encodeWithSelector(IMDStockDex.UnexpectedTokenBalance.selector, address(stock)), GROSS, 1
        );
        _assertUnchanged();
    }

    function test_partialInputSwapRevertsInsteadOfStrandingFunds() public {
        venue.setFaults(false, false, 1, 0);
        _buyReverts(
            abi.encodeWithSelector(IMDStockDex.UnexpectedTokenBalance.selector, address(imd)), GROSS, 1
        );
        _assertUnchanged();
    }

    function test_failedVenueRevertsWithoutFees() public {
        venue.setFaults(true, false, 0, 0);
        _buyReverts(MockVenue.VenueFailure.selector, GROSS, 1);
        _assertUnchanged();
    }

    function test_blockedStockRecipientRevertsWithoutFees() public {
        stock.setBlockedRecipient(buyer);
        _buyReverts(MockToken.Blocked.selector, GROSS, 1);
        _assertUnchanged();
    }

    function test_creatorTransferFailureRevertsSwapAndBurn() public {
        imd.setBlockedRecipient(creator);
        _buyReverts(MockToken.Blocked.selector, GROSS, 1);
        _assertUnchanged();
    }

    function test_burnFailureRevertsSwapAndCreatorPayment() public {
        imd.setBurnMode(false, true);
        _buyReverts(MockToken.BurnDisabled.selector, GROSS, 1);
        _assertUnchanged();
    }

    function test_noOpBurnCannotPretendToReduceSupply() public {
        imd.setBurnMode(true, false);
        _buyReverts(IMDStockDex.InvalidBurn.selector, GROSS, 1);
        _assertUnchanged();
    }

    function test_noReturnTokensSupported() public {
        imd.setReturnMode(false, true);
        stock.setReturnMode(false, true);
        _buy(GROSS, 1);
        assertEq(stock.balanceOf(buyer), 1990 ether);
        assertEq(imd.balanceOf(creator), 2 ether);
    }

    function test_falseReturnTokenRejected() public {
        imd.setReturnMode(true, false);
        _buyReverts(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)), GROSS, 1
        );
        _assertUnchanged();
    }

    function test_inputTransferTaxRejected() public {
        imd.setTransferTax(100, false, address(dex));
        _buyReverts(
            abi.encodeWithSelector(IMDStockDex.UnexpectedTokenBalance.selector, address(imd)), GROSS, 1
        );
        _assertUnchanged();
    }

    function test_extraTaxOnBuyerRejected() public {
        imd.setTransferTax(100, true, address(dex));
        _buyReverts(
            abi.encodeWithSelector(IMDStockDex.UnexpectedTokenBalance.selector, address(imd)), GROSS, 1
        );
        _assertUnchanged();
    }

    function test_creatorTransferTaxRejected() public {
        imd.setTransferTax(100, false, creator);
        _buyReverts(
            abi.encodeWithSelector(IMDStockDex.UnexpectedTokenBalance.selector, address(imd)), GROSS, 1
        );
        _assertUnchanged();
    }

    function test_outputTransferTaxRejected() public {
        stock.setTransferTax(100, false, buyer);
        _buyReverts(
            abi.encodeWithSelector(IMDStockDex.UnexpectedTokenBalance.selector, address(stock)), GROSS, 1
        );
        _assertUnchanged();
    }

    function test_routerCannotReenterPurchase() public {
        venue.setCallback(address(dex), _buyCalldata());
        _buy(GROSS, 1);
        assertFalse(venue.callbackSucceeded());
        assertEq(
            venue.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(stock.balanceOf(buyer), 1990 ether);
    }

    function testFuzz_tokenCallbacksCannotReenter(uint8 point) public {
        point = uint8(bound(point, 1, 4));
        imd.setCallback(address(dex), _buyCalldata(), point);
        _buy(GROSS, 1);
        assertFalse(imd.callbackSucceeded());
        assertEq(
            imd.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(imd.totalSupply(), INITIAL - 3 ether);
    }

    function test_nativeETHIsRejected() public {
        vm.deal(buyer, 1 ether);
        bytes memory data = _buyCalldata();
        vm.prank(buyer);
        (bool ok,) = address(dex).call{value: 1}(data);
        assertFalse(ok);
        vm.prank(buyer);
        (ok,) = address(dex).call{value: 1}("");
        assertFalse(ok);
        _assertUnchanged();
    }

    function test_pausedDexRejectsPurchases() public {
        vm.prank(owner);
        dex.pause();
        _buyReverts(Pausable.EnforcedPause.selector, GROSS, 1);
        _assertUnchanged();
    }

    function test_unlistedStockRejected() public {
        uint256 version = dex.configVersion();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IMDStockDex.MarketNotEnabled.selector, address(bridge)));
        dex.buyStock(address(bridge), GROSS, 1, block.timestamp, version);
        _assertUnchanged();
    }

    function test_disabledStockRejected() public {
        vm.prank(owner);
        dex.disableMarket(address(stock));
        (, bool enabled) = dex.market(address(stock));
        assertFalse(enabled);
        _buyReverts(abi.encodeWithSelector(IMDStockDex.MarketNotEnabled.selector, address(stock)), GROSS, 1);
        _assertUnchanged();
    }

    function test_pendingPurchaseCannotAcceptChangedCreatorOrSplit() public {
        uint256 stale = dex.configVersion();
        vm.startPrank(owner);
        dex.pause();
        dex.setFeeDistribution(makeAddr("new creator"), 3000);
        dex.unpause();
        vm.stopPrank();
        uint256 current = dex.configVersion();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IMDStockDex.ConfigurationChanged.selector, stale, current));
        dex.buyStock(address(stock), GROSS, 1, block.timestamp, stale);
        _assertUnchanged();
        _buy(GROSS, 1);
        assertEq(imd.balanceOf(makeAddr("new creator")), 3.5 ether);
    }

    function test_routerReplacementLeavesNoOldAllowance() public {
        _buy(GROSS, 1);
        MockVenue next = new MockVenue();
        stock.mint(address(next), INITIAL);
        vm.startPrank(owner);
        dex.pause();
        dex.setRouter(address(next));
        dex.unpause();
        vm.stopPrank();
        _buy(GROSS, 1);
        assertEq(imd.allowance(address(dex), address(venue)), 0);
        assertEq(imd.allowance(address(dex), address(next)), 0);
        assertEq(imd.balanceOf(address(next)), 995 ether);
    }

    function testFuzz_feeConservationAcrossInputRange(uint256 gross, uint16 split) public {
        // Minimum covers even a 1 bps burn allocation, without an arbitrary decimal assumption.
        gross = bound(gross, 2_000_000, type(uint256).max);
        split = uint16(bound(split, 1, 9999));
        vm.startPrank(owner);
        dex.pause();
        dex.setFeeDistribution(creator, split);
        vm.stopPrank();
        IMDStockDex.FeeBreakdown memory fees = dex.previewFees(gross);
        assertEq(fees.swapAmount + fees.burnAmount + fees.creatorAmount, gross);
        assertEq(fees.fee, gross / 200 + (gross % 200 == 0 ? 0 : 1));
        assertEq(fees.burnAmount + fees.creatorAmount, fees.fee);
        assertGt(fees.burnAmount, 0);
        assertGt(fees.creatorAmount, 0);
        // Full precision independent reference from forge-std's stdMath library is not needed:
        // fee is small enough that multiplying its quotient is safe; check rounding via mulDiv.
        assertEq(fees.burnAmount, _mulDivReference(fees.fee, split, 10_000));
    }

    function testFuzz_purchaseConservesFunds(uint256 gross) public {
        gross = bound(gross, 201, INITIAL);
        IMDStockDex.FeeBreakdown memory fees = dex.previewFees(gross);
        _buy(gross, 1);
        assertEq(
            imd.balanceOf(buyer) + imd.balanceOf(creator) + imd.balanceOf(address(venue)), imd.totalSupply()
        );
        assertEq(imd.totalSupply() + fees.burnAmount, INITIAL);
        assertEq(imd.balanceOf(creator), fees.creatorAmount);
        assertEq(imd.balanceOf(address(venue)), fees.swapAmount);
        assertEq(stock.balanceOf(buyer), fees.swapAmount * 2);
        assertEq(imd.balanceOf(address(dex)), 0);
    }

    // Exact binary long division of a 256-bit amount scaled by a small fraction, using additive
    // quotient/remainder accumulation. Independent of previewFees' arithmetic decomposition.
    function _mulDivReference(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 q) {
        uint256 remainder;
        for (uint256 i = 256; i > 0; --i) {
            q *= 2;
            remainder = remainder * 2 + ((x >> (i - 1)) & 1) * y;
            q += remainder / denominator;
            remainder %= denominator;
        }
    }
}
