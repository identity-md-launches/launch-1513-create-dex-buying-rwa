// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The configured IMD must expose a permissionless burn of the caller's own balance.
interface IBurnableIMD {
    function burn(uint256 amount) external;
}
