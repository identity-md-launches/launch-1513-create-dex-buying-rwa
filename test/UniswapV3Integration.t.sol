// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMDStockDex} from "../src/IMDStockDex.sol";
import {IUniswapV3Router} from "../src/interfaces/IUniswapV3.sol";
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

    /// @dev QuoterV2 silently returns the output of a partial fill when a pool runs dry. The DEX must
    ///      not present that as an executable quote, because buyStock rejects partial spending.
    function test_realExhaustedLiquidityQuoteRevertsInsteadOfPhantomOutput() public {
        MockToken thin = new MockToken("THIN", 18);
        thin.mint(address(this), 1e28);
        _createPoolWithLiquidity(address(imd), address(thin), 1e18, -60, 60);
        vm.startPrank(owner);
        dex.pause();
        dex.setMarket(address(thin), abi.encodePacked(address(imd), uint24(3000), address(thin)));
        dex.unpause();
        vm.stopPrank();
        uint256 version = dex.configVersion();

        // Both the quote and the purchase fail for an order the pool cannot absorb; nothing is charged.
        vm.expectRevert(IMDStockDex.InsufficientLiquidity.selector);
        dex.quoteBuy(address(thin), 1000 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IMDStockDex.UnexpectedTokenBalance.selector, address(imd)));
        dex.buyStock(address(thin), 1000 ether, 1, block.timestamp, version);
        assertEq(imd.balanceOf(buyer), 100_000 ether);
        assertEq(imd.balanceOf(creator), 0);

        // An order inside the available liquidity quotes and executes consistently.
        (uint256 quoted,,) = dex.quoteBuy(address(thin), 0.001 ether);
        assertGt(quoted, 0);
        vm.prank(buyer);
        assertEq(dex.buyStock(address(thin), 0.001 ether, quoted, block.timestamp, version), quoted);
    }

    function test_realExhaustedIntermediateHopIsDetected() public {
        MockToken thin = new MockToken("THIN", 18);
        thin.mint(address(this), 1e28);
        _createPoolWithLiquidity(address(bridge), address(thin), 1e18, -60, 60);
        vm.startPrank(owner);
        dex.pause();
        dex.setMarket(
            address(thin),
            abi.encodePacked(address(imd), uint24(3000), address(bridge), uint24(3000), address(thin))
        );
        dex.unpause();
        vm.stopPrank();
        vm.expectRevert(IMDStockDex.InsufficientLiquidity.selector);
        dex.quoteBuy(address(thin), 1000 ether);
        (uint256 quoted,, uint256 version) = dex.quoteBuy(address(thin), 0.001 ether);
        vm.prank(buyer);
        assertEq(dex.buyStock(address(thin), 0.001 ether, quoted, block.timestamp, version), quoted);
    }

    /// @dev MAX_HOPS route IMD -> A -> B -> C -> STOCK on real bytecode: settles with no residue anywhere.
    function test_realFourHopMaximumRoute() public {
        (MockToken a, MockToken b, MockToken c) = _fourHopTokens();
        _createPool(address(imd), address(a));
        _createPool(address(a), address(b));
        _createPool(address(b), address(c));
        _createPool(address(c), address(stock));
        _listFourHop(a, b, c, address(stock));

        uint256 supplyBefore = imd.totalSupply();
        (uint256 quoted, IMDStockDex.FeeBreakdown memory fees, uint256 version) =
            dex.quoteBuy(address(stock), 1000 ether);
        // Four 0.3% LP fees plus the 0.5% application fee and price impact.
        assertGt(quoted, 975 ether);
        assertLt(quoted, 984 ether);
        vm.prank(buyer);
        assertEq(dex.buyStock(address(stock), 1000 ether, quoted, block.timestamp, version), quoted);
        assertEq(stock.balanceOf(buyer), quoted);
        assertEq(imd.balanceOf(buyer), 100_000 ether - 1000 ether);
        assertEq(imd.balanceOf(creator), fees.creatorAmount);
        assertEq(supplyBefore - imd.totalSupply(), fees.burnAmount);
        assertEq(imd.balanceOf(address(dex)), 0);
        assertEq(a.balanceOf(address(dex)), 0);
        assertEq(b.balanceOf(address(dex)), 0);
        assertEq(c.balanceOf(address(dex)), 0);
        assertEq(stock.balanceOf(address(dex)), 0);
        assertEq(imd.allowance(address(dex), router), 0);
    }

    /// @dev Exhausted liquidity at the last of four hops. The quote refuses it, and a buyer whose minimum
    ///      reflects a realistic price is protected by the router's slippage check; nothing is charged.
    ///      With a loose minimum the purchase succeeds as a partial fill: see .imd-findings.json.
    function test_realFourHopExhaustedLastHopQuoteRefusedAndMinimumProtects() public {
        (MockToken a, MockToken b, MockToken c) = _fourHopTokens();
        MockToken thin = new MockToken("THIN", 18);
        thin.mint(address(this), 1e28);
        _createPool(address(imd), address(a));
        _createPool(address(a), address(b));
        _createPool(address(b), address(c));
        _createPoolWithLiquidity(address(c), address(thin), 1e18, -60, 60);
        _listFourHop(a, b, c, address(thin));
        uint256 version = dex.configVersion();
        uint256 supplyBefore = imd.totalSupply();

        vm.expectRevert(IMDStockDex.InsufficientLiquidity.selector);
        dex.quoteBuy(address(thin), 1000 ether);
        vm.prank(buyer);
        vm.expectRevert(bytes("Too little received"));
        dex.buyStock(address(thin), 1000 ether, 900 ether, block.timestamp, version);
        assertEq(imd.balanceOf(buyer), 100_000 ether);
        assertEq(imd.totalSupply(), supplyBefore);
        assertEq(imd.balanceOf(creator), 0);
        assertEq(thin.balanceOf(buyer), 0);
        assertEq(c.balanceOf(router), 0);
        assertEq(imd.allowance(address(dex), router), 0);
    }

    function _fourHopTokens() private returns (MockToken a, MockToken b, MockToken c) {
        a = new MockToken("A", 18);
        b = new MockToken("B", 18);
        c = new MockToken("C", 18);
        a.mint(address(this), 1e28);
        b.mint(address(this), 1e28);
        c.mint(address(this), 1e28);
    }

    function _listFourHop(MockToken a, MockToken b, MockToken c, address target) private {
        vm.startPrank(owner);
        dex.pause();
        dex.setMarket(
            target,
            abi.encodePacked(
                address(imd),
                uint24(3000),
                address(a),
                uint24(3000),
                address(b),
                uint24(3000),
                address(c),
                uint24(3000),
                target
            )
        );
        dex.unpause();
        vm.stopPrank();
    }

    function test_realRouterAndQuoterRejectedAsCreator() public {
        vm.startPrank(owner);
        dex.pause();
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setFeeDistribution(router, 6000);
        vm.expectRevert(IMDStockDex.InvalidAddress.selector);
        dex.setFeeDistribution(quoter, 6000);
        vm.stopPrank();
        assertEq(dex.creator(), creator);
    }

    /// @dev Documents the fee's scope: it is charged on every purchase made through the DEX. The listed
    ///      pool is a public third-party venue the DEX does not own or gate, so a swap sent to the
    ///      router directly pays Uniswap's pool fee only. See README "Scope of the fee".
    function test_feeAppliesToEveryDexPurchaseButNotToDirectPoolSwaps() public {
        (bytes memory path,) = dex.market(address(stock));
        address direct = makeAddr("direct pool user");
        imd.mint(direct, 1000 ether);
        uint256 supplyBefore = imd.totalSupply();
        (uint256 quotedViaDex, IMDStockDex.FeeBreakdown memory fees, uint256 version) =
            dex.quoteBuy(address(stock), 1000 ether);
        vm.prank(buyer);
        dex.buyStock(address(stock), 1000 ether, quotedViaDex, block.timestamp, version);
        assertEq(supplyBefore - imd.totalSupply(), fees.burnAmount);
        assertEq(imd.balanceOf(creator), fees.creatorAmount);

        vm.startPrank(direct);
        imd.approve(router, 1000 ether);
        IUniswapV3Router(router)
            .exactInput(IUniswapV3Router.ExactInputParams(path, direct, block.timestamp, 1000 ether, 1));
        vm.stopPrank();
        // The whole 1000 IMD reached the pool: no application fee, burn, or creator payment occurred.
        assertEq(imd.balanceOf(direct), 0);
        assertEq(supplyBefore - imd.totalSupply(), fees.burnAmount);
        assertEq(imd.balanceOf(creator), fees.creatorAmount);
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        require(pools[msg.sender], "unknown fixture pool");
        IERC20(IV3PoolFixture(msg.sender).token0()).transfer(msg.sender, amount0);
        IERC20(IV3PoolFixture(msg.sender).token1()).transfer(msg.sender, amount1);
    }

    function _createPool(address tokenA, address tokenB) private {
        _createPoolWithLiquidity(tokenA, tokenB, 1e24, -887220, 887220);
    }

    function _createPoolWithLiquidity(
        address tokenA,
        address tokenB,
        uint128 liquidity,
        int24 lower,
        int24 upper
    ) private {
        address pool = IV3FactoryFixture(factory).createPool(tokenA, tokenB, 3000);
        pools[pool] = true;
        IV3PoolFixture(pool).initialize(uint160(1 << 96));
        IV3PoolFixture(pool).mint(address(this), lower, upper, liquidity, "");
    }

    function _deploy(bytes memory initcode) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initcode, 32), mload(initcode))
        }
        require(deployed != address(0), "fixture deployment failed");
    }
}
