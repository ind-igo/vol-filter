// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {AggregatorV2V3Interface} from "interfaces/AggregatorV2V3Interface.sol";

// TODO add in balancer oracle feed

/* ========== ERRORS =========== */
error Price_InvalidParams();
error Price_NotInitialized();
error Price_AlreadyInitialized();
error Price_BadFeed(address priceFeed);

/// @notice Storage of price indicators (price, simple moving average, standard deviation)
/// @dev Welford's Algorithm: https://w.wiki/rcG
contract Indicators is Owned {
    using FixedPointMathLib for uint256;

    /* ========== EVENTS =========== */
    event NewObservation(uint256 timestamp, uint256 price);

    /* ========== STATE VARIABLES ========== */

    /// Chainlink Price Feeds
    /// @dev Chainlink typically provides price feeds for an asset in ETH. Therefore, we use two price feeds against ETH, one for OHM and one for the Reserve asset, to calculate the relative price of OHM in the Reserve asset.
    AggregatorV2V3Interface internal immutable _ohmEthPriceFeed;
    AggregatorV2V3Interface internal immutable _reserveEthPriceFeed;

    /// @notice Moving average data
    uint256 internal _movingAverage; /// See getMovingAverage()

    /// @notice M2 is the sum of the squared differences between the current observation and the moving average.
    /// @dev    Used to calculate the standard deviation.
    uint256 internal _m2;

    /// @notice Array of price observations. Check nextObsIndex to determine latest data point.
    /// @dev    Observations are stored in a ring buffer where the moving average is the sum of all observations divided by the number of observations.
    ///         Observations can be cleared by changing the movingAverageDuration or observationFrequency and must be re-initialized.
    uint256[] public observations;

    /// @notice Index of the next observation to make. The current value at this index is the oldest observation.
    uint32 public nextObsIndex;

    /// @notice Number of observations used in the moving average calculation. Computed from movingAverageDuration / observationFrequency.
    uint32 public numObservations;

    /// @notice Frequency (in seconds) that observations should be stored.
    uint48 public observationFrequency;

    /// @notice Duration (in seconds) over which the moving average is calculated.
    uint48 public movingAverageDuration;

    /// @notice Unix timestamp of last observation (in seconds).
    uint48 public lastObservationTime;

    /// @notice Number of decimals in the price values provided by the contract.
    uint8 public constant decimals = 18;

    /// @notice Whether the price module is initialized (and therefore active).
    bool public initialized;

    // Scale factor for converting prices, calculated from decimal values.
    uint256 internal immutable _scaleFactor;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        AggregatorV2V3Interface ohmEthPriceFeed_,
        AggregatorV2V3Interface reserveEthPriceFeed_,
        uint48 observationFrequency_,
        uint48 movingAverageDuration_
    ) Owned(msg.sender) {
        /// @dev Moving Average Duration should be divisible by Observation Frequency to get a whole number of observations
        if (
            movingAverageDuration_ == 0 ||
            movingAverageDuration_ % observationFrequency_ != 0
        ) revert Price_InvalidParams();

        // Set price feeds, decimals, and scale factor
        _ohmEthPriceFeed = ohmEthPriceFeed_;
        uint8 ohmEthDecimals = _ohmEthPriceFeed.decimals();

        _reserveEthPriceFeed = reserveEthPriceFeed_;
        uint8 reserveEthDecimals = _reserveEthPriceFeed.decimals();

        uint256 exponent = decimals + reserveEthDecimals - ohmEthDecimals;
        if (exponent > 38) revert Price_InvalidParams();
        _scaleFactor = 10**exponent;

        /// Set parameters and calculate number of observations
        observationFrequency = observationFrequency_;
        movingAverageDuration = movingAverageDuration_;

        numObservations = uint32(
            movingAverageDuration_ / observationFrequency_
        );

        /// Store blank observations array
        observations = new uint256[](numObservations);
        /// nextObsIndex is initialized to 0
    }

    /// @notice Trigger an update of price indicators (moving average, variance and std dev)
    /// @dev This function does not have a time-gating on the observationFrequency on this contract. It is set on the Heart policy contract.
    ///      The Heart beat frequency should be set to the same value as the observationFrequency.
    // Calculate indicators (simple moving average, variance and std dev) using Welford's Algorithm
    // https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance#Welford's_online_algorithm
    function updateIndicators() external returns (uint256, uint256, uint256) {
        if (!initialized) revert Price_NotInitialized();

        uint32 numObs = numObservations;
        // Get earliest observation in window
        uint256 earliestPrice = observations[nextObsIndex];
        uint256 currentPrice = getCurrentPrice();

        uint256 diff = currentPrice > earliestPrice
            ? currentPrice - earliestPrice
            : earliestPrice - currentPrice;

        // Calculate moving average and variance with new price data
        (_movingAverage, _m2) = _computeAverageAndM2(
            numObs,
            _movingAverage,
            _m2,
            diff
        );

        /// Push new observation into storage and store timestamp taken at
        observations[nextObsIndex] = currentPrice;
        lastObservationTime = uint48(block.timestamp);
        nextObsIndex = (nextObsIndex + 1) % numObs;

        emit NewObservation(block.timestamp, currentPrice);

        return (currentPrice, _movingAverage, getStandardDeviation())
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Get the current price of OHM in the Reserve asset from the price feeds
    function getCurrentPrice() public view returns (uint256) {
        /// Revert if not initialized
        if (!initialized) revert Price_NotInitialized();

        /// Get prices from feeds
        uint256 ohmEthPrice;
        uint256 reserveEthPrice;
        {
            (, int256 ohmEthPriceInt, , uint256 updatedAt, ) = _ohmEthPriceFeed
                .latestRoundData();

            /// Use a multiple of observation frequency to determine what is too old to use.
            /// Price feeds will not provide an updated answer if the data doesn't change much.
            /// This would be similar to if the feed just stopped updating; therefore, we need a cutoff.
            if (updatedAt < block.timestamp - 3 * uint256(observationFrequency))
                revert Price_BadFeed(address(_ohmEthPriceFeed));

            ohmEthPrice = uint256(ohmEthPriceInt);

            (, int256 reserveEthPriceInt, , updatedAt, ) = _reserveEthPriceFeed
                .latestRoundData();

            if (updatedAt < block.timestamp - uint256(observationFrequency))
                revert Price_BadFeed(address(_reserveEthPriceFeed));
            reserveEthPrice = uint256(reserveEthPriceInt);
        }

        /// Convert to OHM/RESERVE price
        uint256 currentPrice = (ohmEthPrice * _scaleFactor) / reserveEthPrice;

        return currentPrice;
    }

    /// @notice Get the last stored price observation of OHM in the Reserve asset
    function getLastPrice() public view returns (uint256) {
        if (!initialized) revert Price_NotInitialized();

        uint32 lastIndex = nextObsIndex == 0
            ? numObservations - 1
            : nextObsIndex - 1;

        return observations[lastIndex];
    }

    /// @notice Get the moving average of OHM in the Reserve asset over the defined window (see movingAverageDuration and observationFrequency).
    function getMovingAverage() public view returns (uint256) {
        if (!initialized) revert Price_NotInitialized();
        return _movingAverage;
    }

    // Use Welford's Algorithm to calculate the standard deviation from M2
    // More info: https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance#Welford's_online_algorithm
    function getStandardDeviation() public view returns (uint256) {
        if (!initialized) revert Price_NotInitialized();
        return (_m2 / (numObservations - 1)).sqrt();
    }

    function getIndicators() external view returns (uint256, uint256, uint256) {
        return (getCurrentPrice(), getMovingAverage(), getStandardDeviation())
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /// @notice                     Initialize the price module
    /// @notice                     Access restricted to approved policies
    /// @param startObservations_   Array of observations to initialize the moving average with. Must be of length numObservations.
    /// @param lastObservationTime_ Unix timestamp of last observation being provided (in seconds).
    /// @dev This function must be called after the Price module is deployed to activate it and after updating the observationFrequency
    ///      or movingAverageDuration (in certain cases) in order for the Price module to function properly.
    function initialize(
        uint256[] memory startObservations_,
        uint48 lastObservationTime_
    ) external {
        /// Revert if already initialized
        if (initialized) revert Price_AlreadyInitialized();

        /// Cache numObservations to save gas.
        uint256 numObs = observations.length;

        /// Check that the number of start observations matches the number expected
        if (
            startObservations_.length != numObs ||
            lastObservationTime_ > uint48(block.timestamp)
        ) revert Price_InvalidParams();

        uint256 avg;
        uint256 m2;
        for (uint256 i; i < numObs; ) {
            uint256 obs = startObservations_[i];
            if (obs == 0) revert Price_InvalidParams();

            (avg, m2) = _computeAverageAndM2(i + 1, avg, m2, obs);
            observations[i] = obs;
            unchecked {
                ++i;
            }
        }

        // initialize state
        _movingAverage = avg;
        _m2 = m2;
        lastObservationTime = lastObservationTime_;
        initialized = true;
    }

    /// @notice                         Change the moving average window (duration)
    /// @param movingAverageDuration_   Moving average duration in seconds, must be a multiple of observation frequency
    /// @dev Changing the moving average duration will erase the current observations array
    ///      and require the initialize function to be called again. Ensure that you have saved
    ///      the existing data and can re-populate before calling this function.
    function changeMovingAverageDuration(uint48 movingAverageDuration_)
        external
    {
        /// Moving Average Duration should be divisible by Observation Frequency to get a whole number of observations
        if (
            movingAverageDuration_ == 0 ||
            movingAverageDuration_ % observationFrequency != 0
        ) revert Price_InvalidParams();

        /// Calculate the new number of observations
        uint256 newObservations = uint256(
            movingAverageDuration_ / observationFrequency
        );

        /// Store blank observations array of new size
        observations = new uint256[](newObservations);

        /// Set initialized to false and update state variables
        _resetState();
        movingAverageDuration = movingAverageDuration_;
    }

    /// @notice   Change the observation frequency of the moving average (i.e. how often a new observation is taken)
    /// @param    observationFrequency_   Observation frequency in seconds, must be a divisor of the moving average duration
    /// @dev      Changing the observation frequency clears existing observation data since it will not be taken at the right time intervals.
    ///           Ensure that you have saved the existing data and/or can re-populate before calling this function.
    function changeObservationFrequency(uint48 observationFrequency_) external {
        /// Moving Average Duration should be divisible by Observation Frequency to get a whole number of observations
        if (
            observationFrequency_ == 0 ||
            movingAverageDuration % observationFrequency_ != 0
        ) revert Price_InvalidParams();

        /// Calculate the new number of observations
        uint256 newObservations = uint256(
            movingAverageDuration / observationFrequency_
        );

        /// Since the old observations will not be taken at the right intervals,
        /// the observations array will need to be reinitialized.
        /// Although, there are a handful of situations that could be handled
        /// (e.g. clean multiples of the old frequency),
        /// it is easier to do so off-chain and reinitialize the array.

        /// Store blank observations array of new size
        observations = new uint256[](newObservations);

        /// Set initialized to false and update state variables
        _resetState();
        observationFrequency = observationFrequency_;
    }

    // Reset common state variables
    function _resetState() internal {
        initialized = false;
        lastObservationTime = 0;
        _movingAverage = 0;
        _m2 = 0;
        nextObsIndex = 0;
        numObservations = uint32(observations.length);
    }

    // M2 is the sum of the squared differences between the current observation and the moving average.
    function _computeAverageAndM2(
        uint256 counter_,
        uint256 avg_,
        uint256 m2_,
        uint256 diff_
    ) internal pure returns (uint256 newAvg, uint256 newM2) {
        uint256 delta = diff_ - avg_;
        newAvg = avg_ + delta / counter_;
        newM2 = m2_ + delta * (diff_ - newAvg);
    }
}
