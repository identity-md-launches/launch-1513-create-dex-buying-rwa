// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMDStockDex} from "../src/IMDStockDex.sol";
import {MockToken} from "./mocks/MockTokens.sol";
import {UniswapV3FactoryBytecode} from "./fixtures/UniswapV3FactoryBytecode.sol";
import {SwapRouterBytecode} from "./fixtures/SwapRouterBytecode.sol";
import {QuoterV2Bytecode} from "./fixtures/QuoterV2Bytecode.sol";

interface IV3FactoryFixture {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IV3PoolFixture {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function initialize(uint160 sqrtPriceX96) external;
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
}

/// @notice Executes real v3 core/periphery bytecode, offline, with local IMD/stock token doubles.
/// @dev This verifies ABI, path encoding, callbacks, liquidity, quoting, and actual execution pricing.
contract UniswapV3IntegrationTest is Test {
    IMDStockDex internal dex;
    MockToken internal imd;
    MockToken internal stock;
    MockToken internal bridge;
    address internal factory;
    address internal router;
    address internal quoter;
    address internal buyer = makeAddr("integration buyer");
    address internal owner = makeAddr("integration owner");
    address internal creator = makeAddr("integration creator");
    mapping(address => bool) internal pools;

    function setUp() public {
        imd = new MockToken("IMD", 18);
        stock = new MockToken("STOCK", 18);
        bridge = new MockToken("BRIDGE", 18);
        factory = _deploy(UniswapV3FactoryBytecode.creationCode());
        // These swaps are ERC20-only; WETH9 is an unused constructor dependency in this fixture.
        router = _deploy(
            abi.encodePacked(SwapRouterBytecode.creationCode(), abi.encode(factory, address(bridge)))
        );
        quoter =
            _deploy(abi.encodePacked(QuoterV2Bytecode.creationCode(), abi.encode(factory, address(bridge))));
        imd.mint(address(this), 1e28);
        stock.mint(address(this), 1e28);
        bridge.mint(address(this), 1e28);
        _createPool(address(imd), address(stock));
        _createPool(address(imd), address(bridge));
        _createPool(address(bridge), address(stock));
        dex = new IMDStockDex(owner);
        vm.startPrank(owner);
        dex.setIMD(address(imd));
        dex.setRouter(router);
        dex.setQuoter(quoter);
        dex.setFeeDistribution(creator, 6000);
        dex.setMarket(address(stock), abi.encodePacked(address(imd), uint24(3000), address(stock)));
        dex.unpause();
        vm.stopPrank();
        imd.mint(buyer, 100_000 ether);
        vm.prank(buyer);
        imd.approve(address(dex), 100_000 ether);
    }

    function test_realSingleHopQuoteAndPurchase() public {
        uint256 gross = 1000 ether;
        uint256 supplyBefore = imd.totalSupply();
        (uint256 quoted, IMDStockDex.FeeBreakdown memory fees, uint256 version) =
            dex.quoteBuy(address(stock), gross);
        assertGt(quoted, 990 ether);
        assertLt(quoted, 995 ether); // AMM LP fee and price impact, in addition to the application's fee.
        vm.prank(buyer);
        uint256 bought = dex.buyStock(address(stock), gross, quoted, block.timestamp, version);
        assertEq(bought, quoted);
        assertEq(stock.balanceOf(buyer), quoted);
        assertEq(imd.balanceOf(creator), fees.creatorAmount);
        assertEq(supplyBefore - imd.totalSupply(), fees.burnAmount);
        assertEq(imd.balanceOf(address(dex)), 0);
        assertEq(imd.allowance(address(dex), router), 0);
    }

    function test_realMultihopQuoteAndPurchase() public {
        vm.startPrank(owner);
        dex.pause();
        dex.setMarket(
            address(stock),
            abi.encodePacked(address(imd), uint24(3000), address(bridge), uint24(3000), address(stock))
        );
        dex.unpause();
        vm.stopPrank();
        (uint256 quoted,, uint256 version) = dex.quoteBuy(address(stock), 1000 ether);
        assertGt(quoted, 985 ether);
        assertLt(quoted, 990 ether);
        vm.prank(buyer);
        uint256 bought = dex.buyStock(address(stock), 1000 ether, quoted, block.timestamp, version);
        assertEq(bought, quoted);
        assertEq(stock.balanceOf(buyer), quoted);
        assertEq(imd.balanceOf(creator), 2 ether);
        assertEq(imd.balanceOf(address(dex)), 0);
        assertEq(bridge.balanceOf(address(dex)), 0);
        assertEq(imd.allowance(address(dex), router), 0);
    }

    function test_realSlippageFailureRollsBack() public {
        uint256 balanceBefore = imd.balanceOf(buyer);
        uint256 supplyBefore = imd.totalSupply();
        (uint256 quoted,, uint256 version) = dex.quoteBuy(address(stock), 1000 ether);
        vm.prank(buyer);
        vm.expectRevert(bytes("Too little received"));
        dex.buyStock(address(stock), 1000 ether, quoted + 1, block.timestamp, version);
        assertEq(imd.balanceOf(buyer), balanceBefore);
        assertEq(imd.totalSupply(), supplyBefore);
        assertEq(stock.balanceOf(buyer), 0);
        assertEq(imd.balanceOf(creator), 0);
        assertEq(imd.balanceOf(address(dex)), 0);
        assertEq(imd.allowance(address(dex), router), 0);
    }

    function test_realMissingPoolRevertsWithoutFees() public {
        vm.startPrank(owner);
        dex.pause();
        // This fee tier has no pool. Listing checks do not assert liquidity availability.
        dex.setMarket(address(stock), abi.encodePacked(address(imd), uint24(500), address(stock)));
        dex.unpause();
        vm.stopPrank();
        uint256 version = dex.configVersion();
        uint256 supplyBefore = imd.totalSupply();
        vm.prank(buyer);
        vm.expectRevert();
        dex.buyStock(address(stock), 1000 ether, 1, block.timestamp, version);
        assertEq(imd.balanceOf(buyer), 100_000 ether);
        assertEq(imd.totalSupply(), supplyBefore);
        assertEq(imd.balanceOf(creator), 0);
        assertEq(imd.allowance(address(dex), router), 0);
    }

    function test_secondQuoteReflectsPoolMovement() public {
        (uint256 first,, uint256 version) = dex.quoteBuy(address(stock), 1000 ether);
        vm.prank(buyer);
        dex.buyStock(address(stock), 1000 ether, first, block.timestamp, version);
        (uint256 second,,) = dex.quoteBuy(address(stock), 1000 ether);
        assertLt(second, first);
        vm.prank(buyer);
        vm.expectRevert(bytes("Too little received"));
        dex.buyStock(address(stock), 1000 ether, first, block.timestamp, version);
    }

    function testFuzz_realRouterMatchesQuotedNetInput(uint256 gross) public {
        gross = bound(gross, 2_000_000, 10_000 ether);
        (uint256 quoted, IMDStockDex.FeeBreakdown memory fees, uint256 version) =
            dex.quoteBuy(address(stock), gross);
        vm.prank(buyer);
        assertEq(dex.buyStock(address(stock), gross, quoted, block.timestamp, version), quoted);
        assertEq(imd.balanceOf(creator), fees.creatorAmount);
        assertEq(imd.balanceOf(buyer), 100_000 ether - gross);
        assertEq(imd.allowance(address(dex), router), 0);
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        require(pools[msg.sender], "unknown fixture pool");
        IERC20(IV3PoolFixture(msg.sender).token0()).transfer(msg.sender, amount0);
        IERC20(IV3PoolFixture(msg.sender).token1()).transfer(msg.sender, amount1);
    }

    function _createPool(address tokenA, address tokenB) private {
        address pool = IV3FactoryFixture(factory).createPool(tokenA, tokenB, 3000);
        pools[pool] = true;
        IV3PoolFixture(pool).initialize(uint160(1 << 96));
        IV3PoolFixture(pool).mint(address(this), -887220, 887220, 1e24, "");
    }

    function _deploy(bytes memory initcode) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initcode, 32), mload(initcode))
        }
        require(deployed != address(0), "fixture deployment failed");
    }
}
