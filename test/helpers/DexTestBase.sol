// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDStockDex} from "../../src/IMDStockDex.sol";
import {MockToken} from "../mocks/MockTokens.sol";
import {MockVenue} from "../mocks/MockVenue.sol";

abstract contract DexTestBase is Test {
    IMDStockDex internal dex;
    MockToken internal imd;
    MockToken internal stock;
    MockToken internal bridge;
    MockVenue internal venue;
    address internal owner = makeAddr("launch owner");
    address internal buyer = makeAddr("buyer");
    address internal creator = makeAddr("creator");
    uint256 internal constant GROSS = 1000 ether;
    uint256 internal constant INITIAL = 1_000_000 ether;

    function setUp() public virtual {
        imd = new MockToken("IMD", 18);
        stock = new MockToken("STOCK", 18);
        bridge = new MockToken("BRIDGE", 6);
        venue = new MockVenue();
        dex = new IMDStockDex(owner);
        vm.startPrank(owner);
        dex.setIMD(address(imd));
        dex.setRouter(address(venue));
        dex.setQuoter(address(venue));
        dex.setFeeDistribution(creator, 6000);
        dex.setMarket(address(stock), _path());
        dex.unpause();
        vm.stopPrank();
        imd.mint(buyer, INITIAL);
        stock.mint(address(venue), INITIAL * 10);
        vm.prank(buyer);
        imd.approve(address(dex), INITIAL);
    }

    function _buy(uint256 gross, uint256 minimum) internal returns (uint256) {
        uint256 version = dex.configVersion();
        vm.prank(buyer);
        return dex.buyStock(address(stock), gross, minimum, block.timestamp + 1 hours, version);
    }

    function _buyReverts(bytes4 reason, uint256 gross, uint256 minimum) internal {
        _buyReverts(abi.encodePacked(reason), gross, minimum);
    }

    function _buyReverts(bytes memory reason, uint256 gross, uint256 minimum) internal {
        uint256 version = dex.configVersion();
        vm.prank(buyer);
        vm.expectRevert(reason);
        dex.buyStock(address(stock), gross, minimum, block.timestamp + 1 hours, version);
    }

    function _path() internal view returns (bytes memory) {
        return abi.encodePacked(address(imd), uint24(3000), address(stock));
    }

    function _buyCalldata() internal view returns (bytes memory) {
        return abi.encodeCall(
            dex.buyStock, (address(stock), GROSS, 1, block.timestamp + 1 hours, dex.configVersion())
        );
    }

    function _assertUnchanged() internal view {
        assertEq(imd.balanceOf(buyer), INITIAL);
        assertEq(imd.balanceOf(address(venue)), 0);
        assertEq(imd.balanceOf(creator), 0);
        assertEq(imd.balanceOf(address(dex)), 0);
        assertEq(stock.balanceOf(buyer), 0);
        assertEq(imd.totalSupply(), INITIAL);
        assertEq(imd.allowance(address(dex), address(venue)), 0);
    }
}
