// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @dev Configurable adversarial tokens live only in test/. No launch token is provided.
contract MockToken is ERC20Burnable {
    uint8 private immutable tokenDecimals;
    bool public falseReturns;
    bool public noReturns;
    bool public fakeBurn;
    bool public burnReverts;
    bool public senderTax;
    uint16 public transferTaxBps;
    address public blockedRecipient;
    address public taxedRecipient;
    address public callbackTarget;
    bytes public callbackData;
    uint8 public callbackOn;
    bool public callbackSucceeded;
    bytes public callbackResult;

    error Blocked();
    error BurnDisabled();

    constructor(string memory symbol_, uint8 decimals_) ERC20(symbol_, symbol_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setReturnMode(bool false_, bool none_) external {
        falseReturns = false_;
        noReturns = none_;
    }

    function setBurnMode(bool fake_, bool revert_) external {
        fakeBurn = fake_;
        burnReverts = revert_;
    }

    function setBlockedRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function setTransferTax(uint16 bps, bool senderPays, address onlyRecipient) external {
        transferTaxBps = bps;
        senderTax = senderPays;
        taxedRecipient = onlyRecipient;
    }

    function setCallback(address target, bytes calldata data, uint8 on) external {
        callbackTarget = target;
        callbackData = data;
        callbackOn = on;
    }

    function burn(uint256 amount) public override {
        if (burnReverts) revert BurnDisabled();
        if (callbackOn == 3) _callback();
        if (!fakeBurn) super.burn(amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (falseReturns) return false;
        if (callbackOn == 2) _callback();
        super.transfer(to, amount);
        if (noReturns) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (falseReturns) return false;
        if (callbackOn == 1) _callback();
        super.transferFrom(from, to, amount);
        if (noReturns) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (falseReturns) return false;
        if (callbackOn == 4) _callback();
        super.approve(spender, amount);
        if (noReturns) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (to != address(0) && to == blockedRecipient) revert Blocked();
        if (
            from != address(0) && to != address(0) && transferTaxBps > 0
                && (taxedRecipient == address(0) || to == taxedRecipient)
        ) {
            uint256 tax = amount * transferTaxBps / 10_000;
            super._update(from, address(0), tax);
            super._update(from, to, senderTax ? amount : amount - tax);
        } else {
            super._update(from, to, amount);
        }
    }

    function _callback() private {
        // Suppress recursion in the test double itself, while exposing the attempted DEX callback.
        uint8 previous = callbackOn;
        callbackOn = 0;
        (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        callbackOn = previous;
    }
}
