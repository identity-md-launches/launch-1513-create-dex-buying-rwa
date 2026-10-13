// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/// @notice Minimal ABI of the original Uniswap v3 SwapRouter, not SwapRouter02 or Universal Router.
/// @dev ABI reference: Uniswap/v3-periphery contracts/interfaces/ISwapRouter.sol.
interface IUniswapV3Router {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice QuoterV2 is called using eth_call; it is intentionally not a Solidity view function.
/// @dev ABI reference: Uniswap/v3-periphery contracts/interfaces/IQuoterV2.sol.
interface IUniswapV3Quoter {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}
