// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Wrapped rBTC (WETH9-style) interface. Wraps native rBTC 1:1 into an
///         ERC-20 token.
/// @dev withdraw pays out native rBTC via transfer() with a 2300-gas stipend,
///      so receiving contracts must keep their receive() handlers empty.
interface IWRBTC is IERC20 {
    /// @notice Wraps the native rBTC sent with the call, minting an equal
    ///         amount of WRBTC to the caller.
    function deposit() external payable;

    /// @notice Burns `wad` WRBTC from the caller and sends back an equal
    ///         amount of native rBTC.
    /// @param wad Amount of WRBTC to unwrap, in wei.
    function withdraw(uint256 wad) external;
}
