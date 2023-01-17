// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Raffle
 * @notice Creates a mechanism to create multiple raffles
 */
contract Raffle is VRFConsumerBaseV2, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;

    VRFCoordinatorV2Interface COORDINATOR;
    Counters.Counter public raffleCounter;
    RequestConfig public requestConfig;
    address public owner;
    address public keeperRegistryAddress;
    uint256[] public stagedRaffles;
    uint256[] private liveRaffles;
    mapping(uint256 => RaffleInstance) public raffles;
    mapping(uint256 => uint256) public requestIdToRaffleIndex;
    mapping(uint256 => Prize[]) public prizes;

    // ------------------- STRUCTS -------------------
    enum RaffleState {
        STAGED,
        LIVE,
        FINISHED
    }

    // NOTE: maybe add in min amount of entries before raffle can be closed?
    struct RaffleInstance {
        bytes32 raffleName;
        address[] contestantsAddresses;
        address winner;
        uint256 startDate;
        uint256 prizeWorth;
        uint256 randomSeed;
        address contestOwner;
        uint256 timeLength;
        uint256 fee;
        RaffleState raffleState;
        Prize prize;
        bool feeToken;
        address feeTokenAddress;
    }

    struct Prize {
        string prizeName;
        bool claimed;
    }

    struct RequestConfig {
        uint64 subscriptionId;
        uint32 callbackGasLimit;
        uint16 requestConfirmations;
        uint32 numWords;
        bytes32 keyHash;
    }

    //------------------------------ EVENTS ----------------------------------
    event RaffleCreated(Prize prize, uint256 indexed time, uint256 indexed fee);
    event RaffleJoined(uint256 indexed raffleId, address indexed player, uint256 entries);
    event RaffleClosed(uint256 indexed raffleId, address[] participants);
    event RaffleStaged(uint256 indexed raffleId);
    event RaffleWon(uint256 indexed raffleId, address indexed winner);
    event RafflePrizeClaimed(uint256 indexed raffleId, address indexed winner, uint256 value);
    event KeeperRegistryAddressUpdated(address oldAddress, address newAddress);

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    modifier onlyKeeperRegistry() {
        if (msg.sender != keeperRegistryAddress) {
            revert OnlyKeeperRegistry();
        }
        _;
    }

    // ------------------- ERRORS -------------------
    error OnlyKeeperRegistry();

    constructor(
        address vrfCoordinator,
        uint64 subscriptionId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        bytes32 keyHash,
        address keeperAddress
    ) VRFConsumerBaseV2(vrfCoordinator) {
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        owner = msg.sender;
        requestConfig = RequestConfig({
            subscriptionId: subscriptionId,
            callbackGasLimit: callbackGasLimit,
            requestConfirmations: requestConfirmations,
            numWords: 1,
            keyHash: keyHash
        });
        setKeeperRegistryAddress(keeperAddress);
    }

    /**
     * @notice creates new raffle
     * @param prize prize struct
     * @param timeLength time length of raffle
     * @param fee fee to enter raffle
     * @param name name of raffle
     * @param feeToken address of token to use for fee. If 0x0, Gas token will be used
     *
     */
    function createRaffle(Prize memory prize, uint256 timeLength, uint256 fee, bytes32 name, address feeToken)
        external
        payable
        onlyOwner
    {
        bool _feeToken = false;
        address _feeTokenAddress = address(0);
        if (feeToken != address(0)) {
            _feeToken = true;
            _feeTokenAddress = feeToken;
        }
        RaffleInstance memory newRaffle = RaffleInstance({
            raffleName: name,
            contestantsAddresses: new address[](0),
            winner: address(0),
            startDate: block.timestamp,
            prizeWorth: msg.value,
            randomSeed: 0,
            contestOwner: msg.sender,
            timeLength: timeLength,
            fee: fee,
            raffleState: RaffleState.LIVE,
            prize: prize,
            feeToken: _feeToken,
            feeTokenAddress: _feeTokenAddress
        });
        raffles[raffleCounter.current()] = newRaffle;
        liveRaffles.push(raffleCounter.current());
        emit RaffleCreated(prize, timeLength, fee);
        raffleCounter.increment();
    }

    /**
     * @notice joins raffle by ID and number of entries
     * @param raffleId id of raffle
     * @param entries number of entries
     * @dev requires that raffle is live and that enough ETH is sent to cover fee
     *
     */
    function enterRaffle(uint256 raffleId, uint256 entries) external payable {
        require(raffles[raffleId].raffleState == RaffleState.LIVE, "Raffle is not live");
        if (raffles[raffleId].feeToken) {
            IERC20(raffles[raffleId].feeTokenAddress).safeTransferFrom(
                msg.sender, address(this), (raffles[raffleId].fee * entries)
            );
        } else {
            require(msg.value >= (raffles[raffleId].fee * entries), "Not enough ETH to join raffle");
        }
        for (uint256 i = 0; i < entries; i++) {
            raffles[raffleId].contestantsAddresses.push(msg.sender);
        }
        emit RaffleJoined(raffleId, msg.sender, entries);
    }

    /**
     * @notice closes raffle and picks winner
     * @param raffleId id of raffle
     * @dev requests random number from VRF and marks raffle as finished
     *
     */
    function pickWinner(uint256 raffleId) internal {
        uint256 requestId = COORDINATOR.requestRandomWords(
            requestConfig.keyHash,
            requestConfig.subscriptionId,
            requestConfig.requestConfirmations,
            requestConfig.callbackGasLimit,
            1
        );
        requestIdToRaffleIndex[requestId] = raffleId;
        raffles[raffleId].raffleState = RaffleState.FINISHED;

        emit RaffleClosed(raffleId, raffles[raffleId].contestantsAddresses);
    }

    /**
     * @notice gets the winner of a specific raffle
     * @param raffleId id of the raffle
     * @return address of the winner
     *
     */
    function getWinners(uint256 raffleId) external view returns (address) {
        return raffles[raffleId].winner;
    }

    /**
     * @notice withdraws rewards for an account
     * @param randomValue random value generated by VRF
     * @param amount amount of raffle entries
     *
     */
    function _pickRandom(uint256 randomValue, uint256 amount) internal pure returns (uint256) {
        uint256 v = uint256(keccak256(abi.encode(randomValue, 0)));
        return uint256(v % amount) + 1;
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        uint256 raffleIndexFromRequestId = requestIdToRaffleIndex[requestId];
        raffles[raffleIndexFromRequestId].randomSeed = randomWords[0];
        raffles[raffleIndexFromRequestId].raffleState = RaffleState.STAGED;
        _updateLiveRaffles(raffleIndexFromRequestId);
        uint256 winner = _pickRandom(randomWords[0], raffles[raffleIndexFromRequestId].contestantsAddresses.length);

        raffles[raffleIndexFromRequestId].winner = raffles[raffleIndexFromRequestId].contestantsAddresses[winner - 1];
        raffles[raffleIndexFromRequestId].raffleState = RaffleState.FINISHED;
        emit RaffleWon(raffleIndexFromRequestId, raffles[raffleIndexFromRequestId].winner);
    }

    /**
     * @notice claims prize for a specific raffle
     * @param raffleId id of the raffle
     * @dev requires that raffle is finished and that the caller is the winner
     *
     */
    function claimPrize(uint256 raffleId) external {
        require(raffles[raffleId].raffleState == RaffleState.FINISHED, "Raffle is not finished");
        require(raffles[raffleId].winner == msg.sender, "You are not the winner of this raffle");
        require(!raffles[raffleId].prize.claimed, "Prize has already been claimed");
        if (raffles[raffleId].feeToken) {
            IERC20(raffles[raffleId].feeTokenAddress).safeTransfer(msg.sender, raffles[raffleId].prizeWorth);
            raffles[raffleId].prize.claimed = true;
        } else {
            payable(msg.sender).transfer(raffles[raffleId].prizeWorth);
            raffles[raffleId].prize.claimed = true;
        }
        emit RafflePrizeClaimed(raffleId, msg.sender, raffles[raffleId].prizeWorth);
    }

    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory /* performData */ )
    {
        for (uint256 i = 0; i < liveRaffles.length; i++) {
            if (raffles[i].raffleState == RaffleState.LIVE) {
                upkeepNeeded = (block.timestamp - raffles[i].startDate) > raffles[i].timeLength;
            }
        }
    }

    function performUpkeep(bytes calldata /* performData */ ) external override onlyKeeperRegistry {
        for (uint256 i = 0; i < liveRaffles.length; i++) {
            if (raffles[i].raffleState == RaffleState.LIVE) {
                if ((block.timestamp - raffles[i].startDate) > raffles[i].timeLength) {
                    emit RaffleStaged(liveRaffles[i]);
                    pickWinner(liveRaffles[i]);
                }
            }
        }
    }

    /**
     * @notice Sets the keeper registry address.
     */
    function setKeeperRegistryAddress(address newKeeperAddress) public onlyOwner {
        require(newKeeperAddress != address(0));
        emit KeeperRegistryAddressUpdated(keeperRegistryAddress, newKeeperAddress);
        keeperRegistryAddress = newKeeperAddress;
    }

    /**
     * @notice Updates live raffles array when one finishes.
     */
    function _updateLiveRaffles(uint256 _index) internal {
        for (uint256 i = _index; i < liveRaffles.length - 1; i++) {
            liveRaffles[i] = liveRaffles[i + 1];
        }
        liveRaffles.pop();
    }

    /**
     * @notice get raffle by ID
     * @param raffleId raffle id
     * @return raffle instance
     *
     */
    function getRaffle(uint256 raffleId) external view returns (RaffleInstance memory) {
        return raffles[raffleId];
    }

    /**
     * @notice get all live raffles
     * @return array of live raffle IDs
     *
     */
    function getLiveRaffles() external view returns (uint256[] memory) {
        return liveRaffles;
    }

    /**
     * @notice get amount of entries for a specific user in a specific raffle
     * @param user address of the user
     * @param raffleId id of the raffle
     * @return uint256 amount of entries
     *
     */
    function getUserEntries(address user, uint256 raffleId) external view returns (uint256) {
        uint256 userEntriesCount = 0;
        for (uint256 i = 0; i < raffles[raffleId].contestantsAddresses.length; i++) {
            if (raffles[raffleId].contestantsAddresses[i] == user) {
                userEntriesCount++;
            }
        }

        return userEntriesCount;
    }
}
