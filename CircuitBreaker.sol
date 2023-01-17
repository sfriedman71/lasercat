// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract CircuitBreaker is Pausable, AutomationCompatibleInterface {
    address public owner;
    int256 public limit;
    int256 public currentPrice;
    int8 public volatilityPercentage;
    uint256 public interval;
    address public externalContract;
    bytes public functionSelector;
    bool public usingExternalContract;
    address public keeperRegistryAddress;
    AggregatorV3Interface public priceFeed;
    EventType[] public configuredEvents;
    mapping(EventType => bool) public currentEventsMapping;

    enum EventType {
        Limit,
        Staleness,
        Volatility
    }

    //------------------------------ EVENTS ----------------------------------

    event Limit(int256 percentage);
    event Staleness(uint256 interval);
    event Volatility(
        int256 indexed percentage,
        uint256 indexed currentPrice,
        int256 indexed lastPrice
    );
    event KeeperRegistryAddressUpdated(address oldAddress, address newAddress);
    event EventsTriggered(EventType[] events);
    event StalenessEventUpdated(uint256 old, uint256 updated);
    event LimitEventUpdated(int256 old, int256 updated);
    event VolatilityEventUpdated(
        int256 oldPrice,
        int256 updatedPrice,
        int8 oldPercentage,
        int8 updatedPercentage
    );

    // Errors

    error OnlyKeeperRegistry();
    // ------------------- MODIFIERS -------------------

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    modifier onlyContract() {
        require(msg.sender == owner || msg.sender == address(this));
        _;
    }

    modifier onlyKeeperRegistry() {
        if (msg.sender != keeperRegistryAddress) {
            revert OnlyKeeperRegistry();
        }
        _;
    }

    constructor(
        address feed,
        uint8[] memory eventTypes,
        address keeperAddress
    ) {
        owner = msg.sender;
        priceFeed = AggregatorV3Interface(feed);
        setKeeperRegistryAddress(keeperAddress);
        for (uint256 i = 0; i < eventTypes.length; i++) {
            configuredEvents.push(EventType(eventTypes[i]));
        }
    }

    /**
     * @notice Gets the event types that are configured.
     * @return EventType[] The list of event types.
     */
    function getEvents() external view returns (EventType[] memory) {
        return configuredEvents;
    }

    /**
     * @notice Adds an event type to the list of configured events.
     * @param eventTypes The event type to add based on the EventType enum.
     */
    function addEventTypes(uint8[] memory eventTypes) external onlyOwner {
        for (uint256 i = 0; i < eventTypes.length; i++) {
            require(eventTypes[i] < 3, "Not a valid event type");
            require(
                !currentEventsMapping[EventType(i)],
                "Event type already configured"
            );
            currentEventsMapping[EventType(i)] = true;
            configuredEvents.push(EventType(eventTypes[i]));
        }
    }

    /**
     * @notice Deletes an event type from the list of configured events.
     * @param eventTypes The event type to delete based on the EventType enum.
     */
    function deleteEventTypes(uint8[] memory eventTypes) external onlyOwner {
        for (uint256 i = 0; i < configuredEvents.length; i++) {
            if (configuredEvents[i] == EventType(eventTypes[i])) {
                configuredEvents[i] = configuredEvents[
                    configuredEvents.length - 1
                ];
                configuredEvents.pop();
                currentEventsMapping[EventType(eventTypes[i])] = false;
            }
        }
    }

    /**
     * @notice Sets limit event parameters.
     * @param newLimit The price to watch for.
     */
    function setLimit(int256 newLimit) external onlyOwner {
        limit = newLimit;
        emit LimitEventUpdated(limit, newLimit);
    }

    /**
     * @notice Sets staleness event parameters.
     * @param newInterval The interval to check against.
     */
    function setStaleness(uint256 newInterval) external onlyOwner {
        interval = newInterval;
        emit StalenessEventUpdated(interval, newInterval);
    }

    /**
     * @notice Sets volatility event parameters.
     * @param newPrice The current price.
     * @param newPercentage The percentage change to check against.
     */
    function setVolatility(int256 newPrice, int8 newPercentage)
        external
        onlyOwner
    {
        currentPrice = newPrice;
        volatilityPercentage = newPercentage;
        emit VolatilityEventUpdated(
            currentPrice,
            newPrice,
            volatilityPercentage,
            newPercentage
        );
    }

    /**
     * @notice Update price feed address.
     * @param feed The address of the price feed.
     */
    function updateFeed(address feed) external onlyOwner {
        priceFeed = AggregatorV3Interface(feed);
    }

    /**
     * @notice Sets the keeper registry address.
     * @param newKeeperRegistryAddress The address of the keeper registry.
     */
    function setKeeperRegistryAddress(address newKeeperRegistryAddress)
        public
        onlyOwner
    {
        require(newKeeperRegistryAddress != address(0));
        emit KeeperRegistryAddressUpdated(
            keeperRegistryAddress,
            newKeeperRegistryAddress
        );
        keeperRegistryAddress = newKeeperRegistryAddress;
    }

    function getLatestPrice() internal view returns (int256, uint256) {
        (, int256 price, , uint256 timeStamp, ) = priceFeed.latestRoundData();
        return (price, timeStamp);
    }

    function checkVolatility(int256 price)
        internal
        view
        returns (
            bool,
            EventType,
            int256
        )
    {
        (bool v, int256 pc) = (calculateChange(price));
        if (v) {
            return (true, EventType.Volatility, pc);
        }

        return (false, EventType.Volatility, 0);
    }

    function checkStaleness(uint256 timeStamp)
        internal
        view
        returns (bool, EventType)
    {
        if (block.timestamp - timeStamp > interval) {
            return (true, EventType.Staleness);
        }
        return (false, EventType.Staleness);
    }

    function checkLimit(int256 price) internal view returns (bool, EventType) {
        if (price >= limit) {
            return (true, EventType.Limit);
        }
        return (false, EventType.Limit);
    }

    function calculateChange(int256 price)
        internal
        view
        returns (bool, int256)
    {
        int256 percentageChange = ((price - currentPrice) / currentPrice) * 100;
        int256 absValue = percentageChange < 0
            ? -percentageChange
            : percentageChange;
        if (absValue > volatilityPercentage) {
            return (true, absValue);
        }

        return (false, 0);
    }

    function checkEvents(int256 price, uint256 timeStamp)
        internal
        returns (bool, EventType[] memory)
    {
        EventType[] memory triggeredEvents = new EventType[](
            configuredEvents.length
        );
        for (uint256 i = 0; i < configuredEvents.length; i++) {
            if (configuredEvents[i] == EventType.Volatility) {
                (bool volEvent, EventType ev, ) = checkVolatility(price);
                if (volEvent) {
                    triggeredEvents[i] = ev;
                }
            } else if (configuredEvents[i] == EventType.Staleness) {
                (bool stalenessEvent, EventType es) = checkStaleness(timeStamp);
                if (stalenessEvent) {
                    triggeredEvents[i] = es;
                }
            } else if (configuredEvents[i] == EventType.Limit) {
                (bool limitEvent, EventType el) = checkLimit(price);
                if (limitEvent) {
                    triggeredEvents[i] = el;
                }
            }
        }
        if (triggeredEvents.length > 0) {
            emit EventsTriggered(triggeredEvents);
            return (true, triggeredEvents);
        }
        return (false, triggeredEvents);
    }

    /**
     * @notice Custom function to be called by the keeper.
     */
    function customFunction() public onlyContract {
        (bool ok, ) = externalContract.call(functionSelector);
        require(ok, "Custom function failed.");
    }

    /**
     * @notice Set custom function.
     * @param externalContractAddress The address of the external contract.
     * @param functionSelectorHex The function selector of the external contract.
     */
    function setCustomFunction(
        address externalContractAddress,
        bytes memory functionSelectorHex
    ) external onlyOwner {
        require(externalContractAddress != address(0), "Invalid address.");
        externalContract = externalContractAddress;
        functionSelector = functionSelectorHex;
        usingExternalContract = true;
    }

    /**
     * @notice Pause custom function from running in upkeep.
     */
    function pauseCustomFunction() external onlyOwner {
        usingExternalContract = false;
    }

    /**
     * @notice Unpause custom function from running in upkeep.
     */
    function unpauseCustomFunction() external onlyOwner {
        usingExternalContract = true;
    }

    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        override
        whenNotPaused
        returns (
            bool upkeepNeeded,
            bytes memory /* performData */
        )
    {
        (int256 price, uint256 timestamp) = getLatestPrice();

        (bool needed, ) = checkEvents(price, timestamp);
        upkeepNeeded = needed;
    }

    function performUpkeep(
        bytes calldata /* performData */
    ) external override whenNotPaused {
        (int256 price, uint256 timeStamp) = getLatestPrice();
        (bool upkeepNeeded, EventType[] memory e) = checkEvents(
            price,
            timeStamp
        );
        if (upkeepNeeded) {
            for (uint256 i = 0; i < e.length; i++) {
                if (e[i] == EventType.Volatility) {
                    (, int256 pc) = (calculateChange(price));
                    emit Volatility(pc, uint256(price), currentPrice);
                } else if (e[i] == EventType.Staleness) {
                    emit Staleness(interval);
                } else if (e[i] == EventType.Limit) {
                    emit Limit(limit);
                }
            }
        }
        if (usingExternalContract) {
            customFunction();
        }
    }

    /**
     * @notice Pause to prevent executing performUpkeep.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Check contract status.
     */
    function isPaused() external view returns (bool) {
        return paused();
    }
}
