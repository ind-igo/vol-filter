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
    function withdrawReserves(address to_, ERC20 token_, uint256 amount_) external;
}

error VolFilter_InvalidParam();

contract VolFilter is Owned {
    using FixedPointMathLib for uint256;

    Indicators public indicators;
    IUniswapV2PairPartialV5 public pair; // 0 = OHM, 1 = DAI
    IMINTR public MINTR;
    ITRSRY public TRSRY;

    ERC20 public ohm;
    ERC20 public dai;

    // Epoch
    uint256 public epochCapacity;

    // next epoch timestamp
    uint256 public nextEpoch;
    
    // Amount of DAI to sell
    uint256 public bidCapacity;

    // Amount of OHM to sell
    uint256 public askCapacity;

    // Bollinger Bands multiple. Defines maximum standard deviations that system will respond to. Must be <3.
    uint256 public bbandMultiple;

    // Threshold of %Band to trigger a buy/sell. Out of 100. 1e4. 50% +/- minPctThreshold
    uint256 public minPctThreshold;
    uint256 public constant HUNDRED_PCT = 100e4;
    uint256 public constant FIFTY_PCT = 50e4;
    uint256 public constant PCT_UNITS = 1e4;

    uint256 public immutable numIntervals; // TWAMM intervals for one 1 epoch

    constructor(Indicators indicators_, address dai_) Owned(msg.sender) {
        indicators = indicators_;
        numIntervals = 8 hours / pair.orderTimeInterval();
        dai = ERC20(dai_);
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
        uint256 pctBandOfPrice = ((currentPrice - lowerBand) / (upperBand - lowerBand)) * 1e4;
        if (pctBandOfPrice > HUNDRED_PCT) pctBandOfPrice = HUNDRED_PCT;
        
        // Check if current price is above minimum threshold above/below SMA to trigger market ops
        // If in top range (>50%), mint and sell OHM. If in bottom range (<50%), withdraw DAI and buy OHM.
        if (pctBandOfPrice > FIFTY_PCT + minPctThreshold) {
            uint256 capacityPct = (pctBandOfPrice - FIFTY_PCT) / FIFTY_PCT;
            uint256 orderSize = askCapacity * capacityPct / PCT_UNITS;

            // Mint enough OHM to sell
            MINTR.mintTo(address(this), orderSize);

            // Initiate OHM sell order for order amount until next epoch
            pair.longTermSwapFrom0To1(orderSize, numIntervals);

        } else if (pctBandOfPrice < FIFTY_PCT - minPctThreshold) {
            // Trigger buy/sell if %Band is below threshold
            uint256 capacityPct = (HUNDRED_PCT - pctBandOfPrice - FIFTY_PCT) / FIFTY_PCT;
            uint256 orderSize = bidCapacity * capacityPct / PCT_UNITS;

            TRSRY.withdrawReserves(address(this), dai, orderSize);

            // Buy OHM for order amount until next epoch
            pair.longTermSwapFrom1To0(orderSize, numIntervals);
        }

    }

    function setEpochCapacity(uint256 epochCapacity_) public onlyOwner {
        epochCapacity = epochCapacity_;
    }

    // Denominated in OHM (9 decimals)
    function setBidCapacity(uint256 bidCapacity_) public onlyOwner {
        bidCapacity = bidCapacity_;
    }

    // Denominated in DAI (18 decimals)
    function setAskCapacity(uint256 askCapacity_) public onlyOwner {
        askCapacity = askCapacity_;
    }

    function setBands(uint256 multiple_) external onlyOwner {
        if (multiple_ < 1 || multiple_ > 3) revert VolFilter_InvalidParam();
        bbandMultiple = multiple_;
    }

    function setMinPctThreshold(uint256 minPct_) external onlyOwner {
        if (minPct_ > 100e4) revert VolFilter_InvalidParam();
        minPctThreshold = minPct_;
    }
}