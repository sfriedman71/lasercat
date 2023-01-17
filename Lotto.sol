// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Lotto
 * @notice Creates a lotto with a set of numbers and a prize
 * @dev numbers are set > 0 and <= 100
 */

contract Lotto is VRFConsumerBaseV2, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;

    VRFCoordinatorV2Interface COORDINATOR;
    Counters.Counter public lottoCounter;
    LottoInstance public lotto;
    RequestConfig public requestConfig;
    address public owner;
    address payable[] players;
    address public keeperRegistryAddress;
    mapping(uint256 => address) private randomRequests;
    mapping(address => uint8[]) private tickets;

    // ------------------- STRUCTS -------------------

    enum LottoState {
        STAGED,
        LIVE,
        FINISHED
    }

    struct LottoInstance {
        address[] contestantsAddresses;
        address[] winners;
        uint256 startDate;
        LottoState lottoState;
        uint256 prizeWorth;
        address lottoOwner;
        uint256 timeLength;
        uint256 fee;
        bool untilWon;
        bool feeToken;
        address feeTokenAddress;
    }

    struct Participant {
        Ticket[] tickets;
    }

    struct Ticket {
        uint256[] numbers;
        uint256 requestId;
    }

    struct RequestConfig {
        uint64 subscriptionId;
        uint32 callbackGasLimit;
        uint16 requestConfirmations;
        uint32 numWords;
        bytes32 keyHash;
    }

    //------------------------------ EVENTS ----------------------------------

    event LottoCreated(uint256 indexed time, uint256 indexed fee);
    event LottoEnter(address indexed player);
    event LottoStaged(address[] participants);
    event RequestedLottoNumbers(uint256 indexed requestId);
    event WinningLotteryNumbers(uint8[] numbers);
    event LotteryWinners(address[] winners);

    // ------------------- ERRORS -------------------
    error LottoNotLive();
    error OnlyKeeperRegistry();

    // ------------------- MODIFIERS -------------------

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
     * @notice creates new lottery
     * @param timeLength length of the lottery
     * @param fee fee to enter the lottery
     * @param untilWon if the lottery will be finished when a winner is found
     * @param feeToken address of the token to be used as fee. If 0x0, Gas token will be used
     *
     */
    function createLotto(uint256 timeLength, uint256 fee, bool untilWon, address feeToken) external onlyOwner {
        bool _feeToken = false;
        address _feeTokenAddress = address(0);
        if (feeToken != address(0)) {
            _feeToken = true;
            _feeTokenAddress = feeToken;
        }
        lottoCounter.increment();
        LottoInstance memory newLotto = LottoInstance({
            contestantsAddresses: new address[](0),
            winners: new address[](0),
            startDate: block.timestamp,
            lottoState: LottoState.LIVE,
            prizeWorth: 0,
            lottoOwner: msg.sender,
            timeLength: timeLength,
            fee: fee,
            untilWon: untilWon,
            feeToken: _feeToken,
            feeTokenAddress: _feeTokenAddress
        });

        lotto = newLotto;
        emit LottoCreated(timeLength, fee);
    }

    /**
     * @notice withdraws rewards for an account
     * @param numbers numbers chosen by the player
     * @dev empty array will trigger a random number generation
     *
     */
    function enterLotto(uint8[] memory numbers) external payable {
        if (lotto.lottoState != LottoState.LIVE) {
            revert LottoNotLive();
        }
        if (!lotto.feeToken) {
            require(msg.value >= lotto.fee, "You need to pay the fee to enter the lotto");
        } else {
            IERC20 token = IERC20(lotto.feeTokenAddress);
            token.safeTransferFrom(msg.sender, address(this), lotto.fee);
        }
        if (numbers.length == 0) {
            uint256 requestId = COORDINATOR.requestRandomWords(
                requestConfig.keyHash,
                requestConfig.subscriptionId,
                requestConfig.requestConfirmations,
                requestConfig.callbackGasLimit,
                1
            );
            randomRequests[requestId] = msg.sender;
            players.push(payable(msg.sender));
        } else {
            require(numbers.length == 6, "not enough numbers");
            for (uint256 i = 0; i < numbers.length; i++) {
                require(numbers[i] <= 100, "Number must be between 1 and 100");
            }
            players.push(payable(msg.sender));
            tickets[msg.sender] = _sortArray(numbers);
        }
        if (!lotto.feeToken) {
            lotto.prizeWorth += msg.value;
        } else {
            lotto.prizeWorth += lotto.fee;
        }
        lotto.contestantsAddresses.push(msg.sender);
        emit LottoEnter(msg.sender);
    }

    /**
     * @notice creates random numbers from VRF request
     * @dev if lotto state is live, it will create random numbers for the player
     * @dev if lotto state is staged, it will pick winners
     *
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        uint256 randomNumber = randomWords[0];
        if (lotto.lottoState == LottoState.LIVE) {
            address a = randomRequests[requestId];
            tickets[a] = _sortArray(_createRandom(randomNumber, 6));
        } else {
            uint8[] memory winningNumbers = _createRandom(randomNumber, 6);
            emit WinningLotteryNumbers(winningNumbers);
            uint8[] memory sortedWinningNumbers = _sortArray(winningNumbers);
            for (uint256 i = 0; i < players.length; i++) {
                address payable player = players[i];
                uint8[] memory playerNumbers = tickets[player];
                for (uint8 j = 0; j < playerNumbers.length; j++) {
                    if (playerNumbers[j] != sortedWinningNumbers[j]) {
                        continue;
                    }
                    if (j == players.length) {
                        lotto.winners.push(player);
                    }
                }
            }
            if (lotto.winners.length > 0) {
                uint256 prize = lotto.prizeWorth / lotto.winners.length;
                if (lotto.feeToken) {
                    IERC20 token = IERC20(lotto.feeTokenAddress);
                    for (uint256 i = 0; i < lotto.winners.length; i++) {
                        address winner = lotto.winners[i];
                        token.safeTransfer(winner, prize);
                    }
                } else {
                    for (uint256 i = 0; i < lotto.winners.length; i++) {
                        address payable winner = payable(lotto.winners[i]);
                        winner.transfer(prize);
                    }
                }
                lotto.lottoState = LottoState.FINISHED;
                emit LotteryWinners(lotto.winners);
            } else {
                lotto.lottoState = LottoState.LIVE;
                lotto.startDate = block.timestamp;
            }
        }
    }

    /**
     * @notice gets the winners of the lotto
     *
     */
    function getWinners() external view returns (address[] memory) {
        return lotto.winners;
    }

    /**
     * @notice withdraws rewards for an account
     * @param randomValue random value generated by VRF
     * @param amount amount of numbers to generate
     *
     */
    function _createRandom(uint256 randomValue, uint256 amount) internal pure returns (uint8[] memory expandedValues) {
        expandedValues = new uint8[](amount);
        for (uint256 i = 0; i < amount; i++) {
            uint256 v = uint256(keccak256(abi.encode(randomValue, i)));
            expandedValues[i] = uint8(v % 100) + 1;
        }
        return expandedValues;
    }

    /**
     * @notice sorts array of numbers
     * @param arr sorts list of numbers
     * @dev used to pick winner with less state changes
     *
     */
    function _sortArray(uint8[] memory arr) internal pure returns (uint8[] memory) {
        for (uint256 i = 0; i < arr.length; i++) {
            for (uint256 j = i + 1; j < arr.length; j++) {
                if (arr[i] > arr[j]) {
                    uint8 temp = arr[i];
                    arr[i] = arr[j];
                    arr[j] = temp;
                }
            }
        }
        return arr;
    }

    function pickWinner() internal {
        uint256 requestId = COORDINATOR.requestRandomWords(
            requestConfig.keyHash,
            requestConfig.subscriptionId,
            requestConfig.requestConfirmations,
            requestConfig.callbackGasLimit,
            1
        );
        assert(requestId > 0);
        emit RequestedLottoNumbers(requestId);
    }

    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory /* performData */ )
    {
        if (lotto.lottoState != LottoState.LIVE) {
            upkeepNeeded = false;
        } else {
            upkeepNeeded = (block.timestamp - lotto.startDate) > lotto.timeLength;
        }
    }

    function performUpkeep(bytes calldata /* performData */ ) external override onlyKeeperRegistry {
        if (lotto.lottoState != LottoState.LIVE) {
            return;
        }
        if ((block.timestamp - lotto.startDate) > lotto.timeLength) {
            lotto.lottoState = LottoState.STAGED;
            address[] memory _players = new address[](players.length);
            for (uint256 i = 0; i < players.length; i++) {
                _players[i] = players[i];
            }
            emit LottoStaged(_players);
            pickWinner();
        }
    }

    /**
     * @notice Sets the keeper registry address.
     * @param keeperAddress The address of the keeper registry.
     */
    function setKeeperRegistryAddress(address keeperAddress) public onlyOwner {
        require(keeperAddress != address(0));
        keeperRegistryAddress = keeperAddress;
    }
}
