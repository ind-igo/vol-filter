// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import {PRBMathUD60x18} from "prb-math/PRBMathUD60x18.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Owned} from "solmate/auth/Owned.sol";

contract VolFilter is Owned {
    using PRBMathUD60x18 for uint256;

    constructor() Owned(msg.sender) {}

}