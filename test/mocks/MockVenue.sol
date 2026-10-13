// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Router, IUniswapV3Quoter} from "../../src/interfaces/IUniswapV3.sol";

contract MockVenue is IUniswapV3Router, IUniswapV3Quoter {
    using SafeERC20 for IERC20;

    uint256 public numerator = 2;
    uint256 public denominator = 1;
    uint256 public spendShortfall;
    uint256 public reportExtra;
    bool public revertSwap;
    bool public ignoreMinimum;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;
    uint256 public quotePriceCount = type(uint256).max; // max: one entry per hop of the quoted path
    uint160 public quotePriceAfter = uint160(1 << 96);
    uint256 public lastAmountIn;
    uint256 public lastMinimum;
    uint256 public lastDeadline;
    address public lastRecipient;
    bytes public lastPath;

    error VenueFailure();
    error TooLittleReceived();

    function setRate(uint256 numerator_, uint256 denominator_) external {
        numerator = numerator_;
        denominator = denominator_;
    }

    function setFaults(bool revert_, bool ignore_, uint256 shortfall_, uint256 extra_) external {
        revertSwap = revert_;
        ignoreMinimum = ignore_;
        spendShortfall = shortfall_;
        reportExtra = extra_;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        if (revertSwap) revert VenueFailure();
        lastAmountIn = params.amountIn;
        lastMinimum = params.amountOutMinimum;
        lastRecipient = params.recipient;
        lastDeadline = params.deadline;
        lastPath = params.path;
        IERC20 input = IERC20(address(bytes20(params.path[:20])));
        IERC20 output = IERC20(address(bytes20(params.path[params.path.length - 20:])));
        input.safeTransferFrom(msg.sender, address(this), params.amountIn - spendShortfall);
        if (callbackTarget != address(0)) {
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        }
        amountOut = params.amountIn * numerator / denominator;
        if (!ignoreMinimum && amountOut < params.amountOutMinimum) revert TooLittleReceived();
        output.safeTransfer(params.recipient, amountOut);
        return amountOut + reportExtra;
    }

    function setQuoteMetadata(uint256 count, uint160 priceAfter) external {
        quotePriceCount = count;
        quotePriceAfter = priceAfter;
    }

    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint160[] memory prices, uint32[] memory ticks, uint256 gasEstimate)
    {
        if (revertSwap) {
            revert VenueFailure();
        }
        uint256 hops = quotePriceCount == type(uint256).max ? (path.length - 20) / 23 : quotePriceCount;
        prices = new uint160[](hops);
        for (uint256 i; i < hops; ++i) {
            prices[i] = quotePriceAfter;
        }
        return (amountIn * numerator / denominator, prices, new uint32[](hops), 100_000);
    }
}
