// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IMDStockDex} from "../src/IMDStockDex.sol";
import {MockToken} from "./mocks/MockTokens.sol";
import {MockVenue} from "./mocks/MockVenue.sol";

contract AccountingHandler is Test {
    IMDStockDex public dex;
    MockToken public imd;
    MockToken public stock;
    MockVenue public venue;
    address public creator = makeAddr("invariant creator");
    address public recoveryRecipient = makeAddr("invariant recovery recipient");
    address[3] public buyers;
    uint256 public minted;
    uint256 public burned;
    uint256 public paidCreator;
    uint256 public swapped;
    uint256 public stockPurchased;
    uint256 public donated;
    uint256 public recovered;
    uint256 public successfulBuys;
    uint256 public failedBuys;

    constructor() {
        imd = new MockToken("IMD", 18);
        stock = new MockToken("STOCK", 18);
        venue = new MockVenue();
        // This test handler is intentionally the administrator of its own local fixture.
        dex = new IMDStockDex(address(this));
        dex.setIMD(address(imd));
        dex.setRouter(address(venue));
        dex.setFeeDistribution(creator, 6000);
        dex.setMarket(address(stock), _path());
        dex.unpause();
        stock.mint(address(venue), 1e36);
        for (uint256 i; i < buyers.length; ++i) {
            buyers[i] = makeAddr(string.concat("invariant buyer ", vm.toString(i)));
        }
    }

    function buy(uint256 gross, uint8 buyerSeed, bool failVenue) external {
        (, bool enabled) = dex.market(address(stock));
        if (dex.paused() || !enabled) return;
        gross = bound(gross, 2_000_000, 1e24);
        address buyer = buyers[buyerSeed % buyers.length];
        imd.mint(buyer, gross);
        minted += gross;
        IMDStockDex.FeeBreakdown memory fees = dex.previewFees(gross);
        uint256 version = dex.configVersion();
        venue.setFaults(failVenue, false, 0, 0);
        vm.startPrank(buyer);
        imd.approve(address(dex), gross);
        if (failVenue) {
            vm.expectRevert(MockVenue.VenueFailure.selector);
            dex.buyStock(address(stock), gross, 1, block.timestamp, version);
            ++failedBuys;
        } else {
            uint256 received =
                dex.buyStock(address(stock), gross, fees.swapAmount * 2, block.timestamp, version);
            burned += fees.burnAmount;
            paidCreator += fees.creatorAmount;
            swapped += fees.swapAmount;
            stockPurchased += received;
            ++successfulBuys;
        }
        vm.stopPrank();
        venue.setFaults(false, false, 0, 0);
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        imd.mint(address(dex), amount);
        minted += amount;
        donated += amount;
    }

    function recoverDonation(uint256 amount) external {
        if (donated == recovered) return;
        amount = bound(amount, 1, donated - recovered);
        bool wasPaused = dex.paused();
        if (!wasPaused) dex.pause();
        dex.recoverToken(address(imd), recoveryRecipient, amount);
        recovered += amount;
        if (!wasPaused) dex.unpause();
    }

    function togglePause() external {
        if (dex.paused()) dex.unpause();
        else dex.pause();
    }

    function toggleMarket() external {
        (, bool enabled) = dex.market(address(stock));
        if (enabled) {
            dex.disableMarket(address(stock));
        } else {
            bool wasPaused = dex.paused();
            if (!wasPaused) dex.pause();
            dex.setMarket(address(stock), _path());
            if (!wasPaused) dex.unpause();
        }
    }

    function changeSplit(uint16 split) external {
        split = uint16(bound(split, 1, 9999));
        bool wasPaused = dex.paused();
        if (!wasPaused) dex.pause();
        dex.setFeeDistribution(creator, split);
        if (!wasPaused) dex.unpause();
    }

    function _path() private view returns (bytes memory) {
        return abi.encodePacked(address(imd), uint24(3000), address(stock));
    }
}

contract AccountingInvariantTest is StdInvariant, Test {
    AccountingHandler internal handler;

    function setUp() public {
        handler = new AccountingHandler();
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.recoverDonation.selector;
        selectors[3] = handler.togglePause.selector;
        selectors[4] = handler.toggleMarket.selector;
        selectors[5] = handler.changeSplit.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_supplyAndDistributionConserveEveryIMDUnit() public view {
        MockToken token = handler.imd();
        uint256 buyerBalances;
        for (uint256 i; i < 3; ++i) {
            buyerBalances += token.balanceOf(handler.buyers(i));
        }
        assertEq(token.totalSupply() + handler.burned(), handler.minted());
        assertEq(token.balanceOf(handler.creator()), handler.paidCreator());
        assertEq(token.balanceOf(address(handler.venue())), handler.swapped());
        assertEq(token.balanceOf(handler.recoveryRecipient()), handler.recovered());
        assertEq(token.balanceOf(address(handler.dex())), handler.donated() - handler.recovered());
        assertEq(
            buyerBalances + handler.paidCreator() + handler.swapped() + handler.donated(), token.totalSupply()
        );
    }

    function invariant_noResidualRouterApprovalOrStockCustody() public view {
        assertEq(handler.imd().allowance(address(handler.dex()), address(handler.venue())), 0);
        assertEq(handler.stock().balanceOf(address(handler.dex())), 0);
        uint256 buyerStock;
        for (uint256 i; i < 3; ++i) {
            buyerStock += handler.stock().balanceOf(handler.buyers(i));
        }
        assertEq(buyerStock, handler.stockPurchased());
        assertEq(buyerStock, handler.swapped() * 2);
    }
}
