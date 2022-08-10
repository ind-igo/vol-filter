// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {IUniswapV2PairPartialV5} from "./interfaces/IUniswapV2PairPartialV5.sol";
import {Indicators} from "./Indicators.sol";

interface IMINTR {
    function mintTo(address to_, uint256 amount_) external;
}

interface ITRSRY {
    function withdrawReserves(
        address to_,
        ERC20 token_,
        uint256 amount_
    ) external;
}

error VolFilter_InvalidParam();
error VolFilter_TooEarly();

// TODO Add band smoothing. Add minimum absolute volatility to act upon
contract VolFilter is Owned {
    using FixedPointMathLib for uint256;

    Indicators public indicators;
    IUniswapV2PairPartialV5 public pair; // 0 = OHM, 1 = DAI
    IMINTR public MINTR;
    ITRSRY public TRSRY;

    ERC20 public ohm;
    ERC20 public dai;

    // Epoch
    uint256 public nextEpochTimestamp;
    uint256 public epochDuration;

    // Amount of DAI to sell
    uint256 public bidCapacity;

    // Amount of OHM to sell
    uint256 public askCapacity;

    // Bollinger Bands multiple. Defines maximum standard deviations that system will respond to. Must be <3.
    uint256 public maxBandMultiple;

    // Threshold of %Band to trigger a buy/sell. Out of 100. 1e4. 50% +/- minPctThreshold
    uint256 public minPctThreshold;
    uint256 public constant HUNDRED_PCT = 100e4;
    uint256 public constant FIFTY_PCT = 50e4;
    uint256 public constant PCT_UNITS = 1e4;

    uint256 public numIntervals; // TWAMM intervals for one order

    constructor(Indicators indicators_, address dai_) Owned(msg.sender) {
        indicators = indicators_;
        dai = ERC20(dai_);
        nextEpochTimestamp = 0;
    }

    // Called at rebase
    function update() external {
        if (block.timestamp < nextEpochTimestamp) revert VolFilter_TooEarly();

        // Update indicator data, then use updated data
        (uint256 currentPrice, uint256 sma uint256 stdDev) = indicators.updateIndicators();

        // Calculate BBands
        uint256 upperBand = sma + (stdDev * maxBandMultiple);
        uint256 lowerBand = sma - (stdDev * maxBandMultiple);

        // Calculate %Band of current price
        uint256 pricePctBBand = ((currentPrice - lowerBand) /
            (upperBand - lowerBand)) * PCT_UNITS;
        if (pricePctBBand > HUNDRED_PCT) pricePctBBand = HUNDRED_PCT;

        // Check if current price is above minimum threshold above/below SMA to trigger market ops
        // If in top range (>50%), mint and sell OHM. If in bottom range (<50%), withdraw DAI and buy OHM.
        // Orders last until next epoch.
        if (pricePctBBand > FIFTY_PCT + minPctThreshold) {
            uint256 capacityPct = (pricePctBBand - FIFTY_PCT) / FIFTY_PCT;
            uint256 orderSize = (askCapacity * capacityPct) / PCT_UNITS;

            MINTR.mintTo(address(this), orderSize);
            pair.longTermSwapFrom0To1(orderSize, numIntervals);
        } else if (pricePctBBand < FIFTY_PCT - minPctThreshold) {
            // Trigger buy/sell if %Band is below threshold
            uint256 capacityPct = (HUNDRED_PCT - pricePctBBand - FIFTY_PCT) /
                FIFTY_PCT;
            uint256 orderSize = (bidCapacity * capacityPct) / PCT_UNITS;

            TRSRY.withdrawReserves(address(this), dai, orderSize);
            pair.longTermSwapFrom1To0(orderSize, numIntervals);
        }

        nextEpochTimestamp += epochDuration;
    }

    function setEpochDuration(uint256 duration_) external {
        epochDuration = duration_;
        numIntervals = duration_ / pair.orderTimeInterval();

        // NOTE: Reset epoch timestamp. This means update can be called again.
        nextEpochTimestamp = 0;
    }

    // Denominated in OHM (9 decimals)
    function setBidCapacity(uint256 bidCapacity_) public onlyOwner {
        bidCapacity = bidCapacity_;
    }

    // Denominated in DAI (18 decimals)
    function setAskCapacity(uint256 askCapacity_) public onlyOwner {
        askCapacity = askCapacity_;
    }

    function setMaxBandMultiple(uint256 multiple_) external onlyOwner {
        if (multiple_ < 1 || multiple_ > 3) revert VolFilter_InvalidParam();
        maxBandMultiple = multiple_;
    }

    function setMinPctThreshold(uint256 minPct_) external onlyOwner {
        if (minPct_ > 100e4) revert VolFilter_InvalidParam();
        minPctThreshold = minPct_;
    }
}
