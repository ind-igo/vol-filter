// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import {PRBMathUD60x18} from "prb-math/PRBMathUD60x18.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Owned} from "solmate/auth/Owned.sol";

import {Indicators} from "./Indicators.sol";

error VolFilter_InvalidParam();

contract VolFilter is Owned {
    using PRBMathUD60x18 for uint256;

    Indicators public indicators;

    // Capacity for epoch
    uint256 public epochCapacity;

    // Bollinger Bands parameters
    uint256 public bbandMultiple; // Between 1 and 3

    // Threshold of %Band to trigger a buy/sell. Out of 100.
    uint256 public minimumThreshold;

    constructor(Indicators indicators_) Owned(msg.sender) {
        indicators = indicators_;
    }

    // Called at rebase
    function update() external {
        // TODO can combine these into one call
        uint256 sma = indicators.getMovingAverage();
        uint256 stdDev = indicators.getStandardDeviation();
        uint256 currentPrice = indicators.getCurrentPrice();

        // Calculate BBands
        uint256 upperBand = sma + (stdDev * bbandMultiple);
        uint256 lowerBand = sma - (stdDev * bbandMultiple);

        // Calculate %Band of current price
        uint256 percentBand = (currentPrice - lowerBand) / (upperBand - lowerBand);

        // TODO too tired. revisit
        if (percentBand < minimumThreshold) {
            // TODO
        }
        // Trigger buy/sell if %Band is below threshold
    }

    function setEpochCapacity(uint256 epochCapacity_) public onlyOwner {
        epochCapacity = epochCapacity_;
    }

    function setBands(uint256 multiple_) external onlyOwner {
        if (multiple_ < 1 || multiple_ > 3) revert VolFilter_InvalidParam();
        bbandMultiple = multiple_;
    }

    function setThreshold(uint256 threshold_) external onlyOwner {
        if (threshold_ > 100) revert VolFilter_InvalidParam();
        minimumThreshold = threshold_;
    }
}