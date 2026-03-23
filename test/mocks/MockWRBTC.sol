// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockWRBTC is ERC20 {
    constructor() ERC20("Wrapped BTC", "WRBTC") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        _burn(msg.sender, wad);
        (bool success,) = msg.sender.call{value: wad}("");
        require(success, "withdraw failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}
