// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMDStockDex} from "../src/IMDStockDex.sol";
import {DexTestBase} from "./helpers/DexTestBase.sol";
import {MockToken} from "./mocks/MockTokens.sol";
import {MockVenue} from "./mocks/MockVenue.sol";

contract ConstructorFactory {
    function deploy(address owner) external returns (IMDStockDex) {
        return new IMDStockDex{salt: keccak256("launch rehearsal")}(owner);
    }
}

contract ConfigurationTest is DexTestBase {
    function test_deploymentNeedsOnlyExplicitOwnerOnEmptyChain() public {
        ConstructorFactory factory = new ConstructorFactory();
        // This address is the owner supplied in the assignment; it need not have code or funds.
        address launchOwner = 0xA82B930352712AD04De22c16114C12BB54B66E59;
        IMDStockDex launched = factory.deploy(launchOwner);
        assertEq(launched.owner(), launchOwner);
        assertTrue(launched.paused());
        assertEq(address(launched.imd()), address(0));
        assertEq(address(launched.router()), address(0));
        assertEq(address(launched.quoter()), address(0));
        assertEq(launched.creator(), address(0));
        assertEq(launched.burnShareBps(), 0);
        assertEq(launched.configVersion(), 0);
    }

    function test_zeroOwnerConstructorRejected() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new IMDStockDex(address(0));
    }

    function test_runtimeFitsAndHasNoForbiddenOpcodes() public view {
        bytes memory code = address(dex).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        assertLe(type(IMDStockDex).creationCode.length + 32, 49_152);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
            }
        }
    }

    function test_unconfiguredTradingAndQuotesHaveClearErrors() public {
        IMDStockDex fresh = new IMDStockDex(owner);
        vm.expectRevert(IMDStockDex.NotConfigured.selector);
        fresh.buyStock(address(stock), GROSS, 1, block.timestamp, 0);
        vm.expectRevert(IMDStockDex.NotConfigured.selector);
        fresh.quoteBuy(address(stock), GROSS);
        vm.expectRevert(IMDStockDex.NotConfigured.selector);
        fresh.previewFees(GROSS);
        vm.startPrank(owner);
        vm.expectRevert(IMDStockDex.NotConfigured.selector);
        fresh.setMarket(address(stock), _path());
        vm.expectRevert(IMDStockDex.NotConfigured.selector);
        fresh.unpause();
        fresh.setIMD(address(imd));
        vm.expectRevert(IMDStockDex.NotConfigured.selector);
        fresh.unpause();
        fresh.setRouter(address(venue));
        vm.expectRevert(IMDStockDex.NotConfigured.selector);
        fresh.unpause();
        fresh.setFeeDistribution(creator, 6000);
        fresh.setMarket(address(stock), _path());
        fresh.unpause();
        vm.stopPrank();
        assertFalse(fresh.paused());
        vm.expectRevert(IMDStockDex.QuoterNotConfigured.selector);
        fresh.quoteBuy(address(stock), GROSS);
        uint256 version = fresh.configVersion();
        vm.startPrank(buyer);
        imd.approve(address(fresh), GROSS);
        fresh.buyStock(address(stock), GROSS, 1, block.timestamp, version);
        vm.stopPrank();
        vm.startPrank(owner);
        fresh.pause();
        fresh.setQuoter(address(venue));
        vm.stopPrank();
        (uint256 out,,) = fresh.quoteBuy(address(stock), GROSS);
        assertEq(out, 1990 ether);
    }

    function test_configurationChangesEmitEventsAndIncrementVersion() public {
        vm.startPrank(owner);
        dex.pause();
        uint256 version = dex.configVersion();
        vm.expectEmit(true, false, false, true, address(dex));
        emit IMDStockDex.ConfigurationVersionChanged(version + 1);
        vm.expectEmit(true, false, false, true, address(dex));
        emit IMDStockDex.FeeDistributionConfigured(buyer, 1000);
        dex.setFeeDistribution(buyer, 1000);
        assertEq(dex.configVersion(), version + 1);
        assertEq(dex.creator(), buyer);
        assertEq(dex.burnShareBps(), 1000);
        vm.stopPrank();
    }

    function test_allAdministrativeFunctionsRejectNonOwner() public {
        bytes[] memory actions = new bytes[](11);
        actions[0] = abi.encodeCall(dex.setIMD, (address(imd)));
        actions[1] = abi.encodeCall(dex.setRouter, (address(venue)));
        actions[2] = abi.encodeCall(dex.setQuoter, (address(venue)));
        actions[3] = abi.encodeCall(dex.setFeeDistribution, (buyer, 5000));
        actions[4] = abi.encodeCall(dex.setMarket, (address(stock), _path()));
        actions[5] = abi.encodeCall(dex.disableMarket, (address(stock)));
        actions[6] = abi.encodeCall(dex.pause, ());
        actions[7] = abi.encodeCall(dex.unpause, ());
        actions[8] = abi.encodeCall(dex.recoverToken, (address(imd), buyer, 1));
        actions[9] = abi.encodeCall(dex.transferOwnership, (buyer));
        actions[10] = abi.encodeCall(dex.renounceOwnership, ());
        for (uint256 i; i < actions.length; ++i) {
            vm.prank(buyer);
            (bool ok, bytes memory result) = address(dex).call(actions[i]);
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        }
    }

    function test_configurationAndRecoveryRequirePause() public {
        bytes[] memory actions = new bytes[](6);
        actions[0] = abi.encodeCall(dex.setIMD, (address(imd)));
        actions[1] = abi.encodeCall(dex.setRouter, (address(venue)));
        actions[2] = abi.encodeCall(dex.setQuoter, (address(venue)));
        actions[3] = abi.encodeCall(dex.setFeeDistribution, (buyer, 5000));
        actions[4] = abi.encodeCall(dex.setMarket, (address(stock), _path()));
        actions[5] = abi.encodeCall(dex.recoverToken, (address(imd), buyer, 1));
        for (uint256 i; i < actions.length; ++i) {
            vm.prank(owner);
            (bool ok, bytes memory result) = address(dex).call(actions[i]);
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(Pausable.ExpectedPause.selector));
        }
    }

    function test_IMDIdentityCannotBeChangedAfterConfiguration() public {
        vm.startPrank(owner);
        dex.pause();
        vm.expectRevert(IMDStockDex.IMDAlreadyConfigured.selector);
        dex.setIMD(address(bridge));
        vm.stopPrank();
        assertEq(address(dex.imd()), address(imd));
    }

    function test_dependenciesRequireNonzeroContractAddresses() public {
        IMDStockDex fresh = new IMDStockDex(owner);
        vm.startPrank(owner);
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        fresh.setIMD(address(0));
        vm.expectRevert(abi.encodeWithSelector(IMDStockDex.NotAContract.selector, buyer));
        fresh.setIMD(buyer);
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        fresh.setIMD(address(fresh));
        dex.pause();
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setRouter(address(0));
        vm.expectRevert(abi.encodeWithSelector(IMDStockDex.NotAContract.selector, buyer));
        dex.setRouter(buyer);
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setRouter(address(imd));
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setRouter(address(dex));
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setQuoter(address(0));
        vm.expectRevert(abi.encodeWithSelector(IMDStockDex.NotAContract.selector, buyer));
        dex.setQuoter(buyer);
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setQuoter(address(dex));
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setQuoter(address(imd));
        vm.stopPrank();
    }

    function test_invalidCreatorAndSplitRejected() public {
        vm.startPrank(owner);
        dex.pause();
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setFeeDistribution(address(0), 5000);
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setFeeDistribution(address(dex), 5000);
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setFeeDistribution(address(imd), 5000);
        vm.expectRevert(IMDStockDex.InvalidSplit.selector);
        dex.setFeeDistribution(creator, 0);
        vm.expectRevert(IMDStockDex.InvalidSplit.selector);
        dex.setFeeDistribution(creator, 10000);
        vm.expectRevert(IMDStockDex.InvalidSplit.selector);
        dex.setFeeDistribution(creator, type(uint16).max);
        vm.stopPrank();
    }

    function test_creatorCanNeverBeTheRouterOrQuoter() public {
        MockVenue other = new MockVenue();
        vm.startPrank(owner);
        dex.pause();
        // The configured router and quoter are rejected as creator, mirroring setIMD's guards.
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setFeeDistribution(address(venue), 5000);
        dex.setQuoter(address(other));
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setFeeDistribution(address(other), 5000);
        // And the current creator is rejected as router or quoter.
        dex.setQuoter(address(venue));
        dex.setFeeDistribution(address(other), 5000);
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setRouter(address(other));
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setQuoter(address(other));
        vm.stopPrank();
        assertEq(dex.creator(), address(other));
        assertEq(address(dex.router()), address(venue));
        assertEq(address(dex.quoter()), address(venue));
    }

    function test_quoteRejectsMissingOrExhaustedHopPrices() public {
        uint160 minLimit = 4295128739 + 1;
        uint160 maxLimit = 1461446703485210103287273052203988822378723970342 - 1;
        venue.setQuoteMetadata(0, uint160(1 << 96));
        vm.expectRevert(IMDStockDex.InvalidQuote.selector);
        dex.quoteBuy(address(stock), GROSS);
        venue.setQuoteMetadata(2, uint160(1 << 96));
        vm.expectRevert(IMDStockDex.InvalidQuote.selector);
        dex.quoteBuy(address(stock), GROSS);
        venue.setQuoteMetadata(type(uint256).max, minLimit);
        vm.expectRevert(IMDStockDex.InsufficientLiquidity.selector);
        dex.quoteBuy(address(stock), GROSS);
        venue.setQuoteMetadata(type(uint256).max, maxLimit);
        vm.expectRevert(IMDStockDex.InsufficientLiquidity.selector);
        dex.quoteBuy(address(stock), GROSS);
        venue.setQuoteMetadata(type(uint256).max, minLimit + 1);
        (uint256 out,,) = dex.quoteBuy(address(stock), GROSS);
        assertEq(out, 1990 ether);
        venue.setQuoteMetadata(type(uint256).max, maxLimit - 1);
        (out,,) = dex.quoteBuy(address(stock), GROSS);
        assertEq(out, 1990 ether);
    }

    function test_malformedPathsAndInvalidStocksRejected() public {
        bytes[] memory paths = new bytes[](8);
        paths[0] = hex"";
        paths[1] = abi.encodePacked(address(imd));
        paths[2] = abi.encodePacked(address(imd), uint24(3000), address(stock), bytes1(0));
        paths[3] = abi.encodePacked(address(stock), uint24(3000), address(imd));
        paths[4] = abi.encodePacked(address(imd), uint24(3000), address(bridge));
        paths[5] = abi.encodePacked(address(imd), uint24(0), address(stock));
        paths[6] = abi.encodePacked(address(imd), uint24(1_000_000), address(stock));
        paths[7] = abi.encodePacked(
            address(imd),
            uint24(3000),
            address(bridge),
            uint24(3000),
            address(imd),
            uint24(3000),
            address(stock)
        );
        vm.startPrank(owner);
        dex.pause();
        for (uint256 i; i < paths.length; ++i) {
            vm.expectRevert(IMDStockDex.InvalidPath.selector);
            dex.setMarket(address(stock), paths[i]);
        }
        bytes memory tooLong = new bytes(20 + 5 * 23);
        vm.expectRevert(IMDStockDex.InvalidPath.selector);
        dex.setMarket(address(stock), tooLong);
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setMarket(address(imd), _path());
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setMarket(address(dex), _path());
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setMarket(address(0), _path());
        vm.expectRevert(abi.encodeWithSelector(IMDStockDex.NotAContract.selector, buyer));
        dex.setMarket(buyer, _path());
        vm.expectRevert(abi.encodeWithSelector(IMDStockDex.NotAContract.selector, buyer));
        dex.setMarket(
            address(stock), abi.encodePacked(address(imd), uint24(3000), buyer, uint24(3000), address(stock))
        );
        vm.stopPrank();
    }

    function test_maximumFourHopRouteAccepted() public {
        MockToken middle2 = new MockToken("MIDDLE2", 18);
        MockToken middle3 = new MockToken("MIDDLE3", 18);
        bytes memory path = abi.encodePacked(
            address(imd),
            uint24(3000),
            address(bridge),
            uint24(500),
            address(middle2),
            uint24(100),
            address(middle3),
            uint24(10000),
            address(stock)
        );
        vm.startPrank(owner);
        dex.pause();
        dex.setMarket(address(stock), path);
        dex.unpause();
        vm.stopPrank();
        _buy(GROSS, 1);
        assertEq(venue.lastPath(), path);
    }

    function test_twoStepOwnershipRequiresAcceptanceAndCanBeCancelled() public {
        address nextOwner = makeAddr("next owner");
        vm.prank(owner);
        dex.transferOwnership(nextOwner);
        assertEq(dex.owner(), owner);
        assertEq(dex.pendingOwner(), nextOwner);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        dex.acceptOwnership();
        vm.prank(owner);
        dex.transferOwnership(address(0));
        assertEq(dex.pendingOwner(), address(0));
        assertEq(dex.owner(), owner);
        vm.prank(nextOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nextOwner));
        dex.acceptOwnership();
        vm.prank(owner);
        dex.transferOwnership(nextOwner);
        vm.prank(nextOwner);
        dex.acceptOwnership();
        assertEq(dex.owner(), nextOwner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        dex.pause();
        vm.prank(nextOwner);
        dex.pause();
    }

    function test_renounceCannotTrapConfiguration() public {
        vm.prank(owner);
        vm.expectRevert(IMDStockDex.RenounceDisabled.selector);
        dex.renounceOwnership();
        assertEq(dex.owner(), owner);
    }

    function test_recoverOnlyAccidentalTokensWhilePaused() public {
        imd.mint(address(dex), 777);
        stock.mint(address(dex), 888);
        vm.startPrank(owner);
        dex.pause();
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.recoverToken(address(imd), address(0), 777);
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.recoverToken(address(imd), address(dex), 777);
        dex.recoverToken(address(imd), buyer, 777);
        dex.recoverToken(address(stock), buyer, 888);
        vm.stopPrank();
        assertEq(imd.balanceOf(buyer), INITIAL + 777);
        assertEq(stock.balanceOf(buyer), 888);
    }

    function test_routerEvenAsOwnerCannotReenterConfiguration() public {
        vm.prank(owner);
        dex.transferOwnership(address(venue));
        vm.prank(address(venue));
        dex.acceptOwnership();
        venue.setCallback(address(dex), abi.encodeCall(dex.disableMarket, (address(stock))));
        _buy(GROSS, 1);
        assertFalse(venue.callbackSucceeded());
        assertEq(
            venue.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        (, bool enabled) = dex.market(address(stock));
        assertTrue(enabled);
    }

    function test_vanishedDependencyDetectedBeforeSpending() public {
        vm.etch(address(venue), hex"");
        _buyReverts(abi.encodeWithSelector(IMDStockDex.NotAContract.selector, address(venue)), GROSS, 1);
        _assertUnchanged();
    }

    function test_duplicateDisableRejected() public {
        vm.startPrank(owner);
        dex.disableMarket(address(stock));
        vm.expectRevert(abi.encodeWithSelector(IMDStockDex.MarketNotEnabled.selector, address(stock)));
        dex.disableMarket(address(stock));
        vm.stopPrank();
    }
}
