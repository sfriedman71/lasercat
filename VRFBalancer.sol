//SPDX-License-Identifier: MIT
pragma solidity <=0.8.17;

import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "../contracts/interfaces/PegswapInterface.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title VRFBalancer
 * @notice Creates automation for vrf subscriptions
 * @dev The linkTokenAddress in constructor is the ERC677 LINK token address of the network
 */
contract VRFBalancer is Pausable, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;

    VRFCoordinatorV2Interface public COORDINATOR;
    LinkTokenInterface public erc677Link;
    IERC20 erc20Link;
    IERC20 erc20Asset;
    PegswapInterface pegSwapRouter;
    IUniswapV2Router02 dexRouter;
    address public owner;
    address public keeperRegistryAddress;
    uint256 public minWaitPeriodSeconds;
    uint256 contractLINKMinBalance;
    uint64[] private watchList;
    uint256 private constant MIN_GAS_FOR_TRANSFER = 55_000;
    bool public needsPegswap;

    struct Target {
        bool isActive;
        uint256 minBalance;
        uint256 topUpAmount;
        uint56 lastTopUpTimestamp;
    }

    mapping(uint64 => Target) internal s_targets;

    event FundsAdded(uint256 amountAdded, uint256 newBalance, address sender);
    event FundsWithdrawn(uint256 amountWithdrawn, address payee);
    event TopUpSucceeded(uint64 indexed subscriptionId);
    event TopUpFailed(uint64 indexed subscriptionId);
    event KeeperRegistryAddressUpdated(address oldAddress, address newAddress);
    event VRFCoordinatorV2AddressUpdated(address oldAddress, address newAddress);
    event MinWaitPeriodUpdated(uint256 oldMinWaitPeriod, uint256 newMinWaitPeriod);
    event PegswapRouterUpdated(address oldPegswapRouter, address newPegswapRouter);
    event DEXAddressUpdated(address newDEXAddress);
    event ContractLINKMinBalanceUpdated(uint256 oldContractLINKBalance, uint256 newContractLINKBalance);
    event ERC20AssetAddressUpdated(address oldERC20AssetAddress, address newERC20AssetAddress);
    event PegSwapSuccess(uint256 amount, address from, address to);
    event DexSwapSuccess(uint256 amount, address from, address to);
    event WatchListUpdated(uint64[] oldSubs, uint64[] newSubs);

    // Errors

    error Unauthorized();
    error OnlyKeeperRegistry();
    error InvalidWatchList();
    error DuplicateSubcriptionId(uint64 duplicate);

    // Modifiers

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyKeeperRegistry() {
        if (msg.sender != keeperRegistryAddress) {
            revert OnlyKeeperRegistry();
        }
        _;
    }

    constructor(
        address erc677linkTokenAddress,
        address erc20linkTokenAddress,
        address coordinatorAddress,
        address keeperAddress,
        uint256 minPeriodSeconds,
        address dexContractAddress,
        uint256 linkContractBalance,
        address erc20AssetAddress
    ) {
        owner = msg.sender;
        setLinkTokenAddresses(erc677linkTokenAddress, erc20linkTokenAddress);
        setVRFCoordinatorV2Address(coordinatorAddress);
        setKeeperRegistryAddress(keeperAddress);
        setMinWaitPeriodSeconds(minPeriodSeconds);
        setDEXAddress(dexContractAddress);
        setContractLINKMinBalance(linkContractBalance);
        setERC20Asset(erc20AssetAddress);
    }

    /**
     * @notice Sets the VRF subscriptions to watch for, along with min balnces and topup amounts.
     * @param subscriptionIds The subscription IDs to watch.
     * @param minBalances The minimum balances to maintain for each subscription.
     * @param topUpAmounts The amount to top up each subscription by when it falls below the minimum.
     * @dev The arrays must be the same length.
     */
    function setWatchList(
        uint64[] calldata subscriptionIds,
        uint256[] calldata minBalances,
        uint256[] calldata topUpAmounts
    ) external onlyOwner {
        if (subscriptionIds.length != minBalances.length || subscriptionIds.length != topUpAmounts.length) {
            revert InvalidWatchList();
        }
        uint64[] memory oldWatchList = watchList;
        for (uint256 idx = 0; idx < oldWatchList.length; idx++) {
            s_targets[oldWatchList[idx]].isActive = false;
        }
        for (uint256 idx = 0; idx < subscriptionIds.length; idx++) {
            if (s_targets[subscriptionIds[idx]].isActive) {
                revert DuplicateSubcriptionId(subscriptionIds[idx]);
            }
            if (subscriptionIds[idx] == 0) {
                revert InvalidWatchList();
            }
            if (topUpAmounts[idx] == 0) {
                revert InvalidWatchList();
            }
            if (topUpAmounts[idx] <= minBalances[idx]) {
                revert InvalidWatchList();
            }
            s_targets[subscriptionIds[idx]] = Target({
                isActive: true,
                minBalance: minBalances[idx],
                topUpAmount: topUpAmounts[idx],
                lastTopUpTimestamp: 0
            });
        }
        watchList = subscriptionIds;
        emit WatchListUpdated(oldWatchList, subscriptionIds);
    }

    function getCurrentWatchList() external view onlyOwner returns (uint64[] memory) {
        return watchList;
    }

    function addSubscription(uint64 subscriptionId, uint256 minBalance, uint256 topUpAmount) external onlyOwner {
        if (subscriptionId == 0) {
            revert InvalidWatchList();
        }
        if (topUpAmount == 0) {
            revert InvalidWatchList();
        }
        if (topUpAmount <= minBalance) {
            revert InvalidWatchList();
        }
        if (s_targets[subscriptionId].isActive) {
            revert DuplicateSubcriptionId(subscriptionId);
        }
        s_targets[subscriptionId] =
            Target({isActive: true, minBalance: minBalance, topUpAmount: topUpAmount, lastTopUpTimestamp: 0});
        uint64[] memory oldWatchList = watchList;
        uint64[] memory newWatchList = new uint64[](oldWatchList.length + 1);
        for (uint256 idx = 0; idx < oldWatchList.length; idx++) {
            newWatchList[idx] = oldWatchList[idx];
        }
        newWatchList[oldWatchList.length] = subscriptionId;
        watchList = newWatchList;
        emit WatchListUpdated(oldWatchList, newWatchList);
    }

    function deleteSubscription(uint64 subscriptionId) external onlyOwner {
        s_targets[subscriptionId].isActive = false;
        uint64[] memory oldWatchList = watchList;
        uint64[] memory newWatchList = new uint64[](oldWatchList.length - 1);
        uint256 count = 0;
        for (uint256 idx = 0; idx < oldWatchList.length; idx++) {
            if (oldWatchList[idx] != subscriptionId) {
                newWatchList[count] = oldWatchList[idx];
                count++;
            }
        }
        watchList = newWatchList;
        emit WatchListUpdated(oldWatchList, newWatchList);
    }

    function updateSubscription(uint64 subscriptionId, uint256 minBalance, uint256 topUpAmount) external onlyOwner {
        if (subscriptionId == 0) {
            revert InvalidWatchList();
        }
        if (topUpAmount == 0) {
            revert InvalidWatchList();
        }
        if (topUpAmount <= minBalance) {
            revert InvalidWatchList();
        }
        if (!s_targets[subscriptionId].isActive) {
            revert InvalidWatchList();
        }
        s_targets[subscriptionId].minBalance = minBalance;
        s_targets[subscriptionId].topUpAmount = topUpAmount;
    }

    function getUnderFundedSubscriptions() external view returns (uint64[] memory) {
        return _getUnderfundedSubscriptions();
    }

    /**
     * @notice Collects the underfunded subscriptions based on user parameters.
     * @return The subscription IDs that are underfunded.
     */
    function _getUnderfundedSubscriptions() internal view returns (uint64[] memory) {
        uint64[] memory currentWatchList = watchList;
        uint64[] memory needsFunding = new uint64[](currentWatchList.length);
        uint256 count = 0;
        uint256 minWaitPeriod = minWaitPeriodSeconds;
        Target memory target;
        for (uint256 idx = 0; idx < currentWatchList.length; idx++) {
            target = s_targets[currentWatchList[idx]];
            (uint96 subscriptionBalance,,,) = COORDINATOR.getSubscription(currentWatchList[idx]);

            if (target.lastTopUpTimestamp + minWaitPeriod <= block.timestamp && subscriptionBalance < target.minBalance)
            {
                needsFunding[count] = currentWatchList[idx];
                count++;
            }
        }

        return needsFunding;
    }

    function topUp(uint64[] memory needsFunding) external onlyOwner {
        _topUp(needsFunding);
    }

    /**
     * @notice Top up the specified subscriptions if they are underfunded.
     * @param needsFunding The subscriptions to top up.
     * @dev This function is called by the KeeperRegistry contract.
     * @dev Checks that the subscription is active, has not been topped up recently, and is underfunded.
     */
    function _topUp(uint64[] memory needsFunding) internal whenNotPaused {
        uint256 _minWaitPeriodSeconds = minWaitPeriodSeconds;
        uint256 contractBalance = erc677Link.balanceOf(address(this));
        Target memory target;
        for (uint256 idx = 0; idx < needsFunding.length; idx++) {
            target = s_targets[needsFunding[idx]];
            (uint96 subscriptionBalance,,,) = COORDINATOR.getSubscription(needsFunding[idx]);
            if (
                target.isActive && target.lastTopUpTimestamp + _minWaitPeriodSeconds <= block.timestamp
                    && subscriptionBalance < target.minBalance && contractBalance >= target.topUpAmount
            ) {
                bool success =
                    erc677Link.transferAndCall(address(COORDINATOR), target.topUpAmount, abi.encode(needsFunding[idx]));

                if (success) {
                    s_targets[needsFunding[idx]].lastTopUpTimestamp = uint56(block.timestamp);
                    emit TopUpSucceeded(needsFunding[idx]);
                } else {
                    emit TopUpFailed(needsFunding[idx]);
                }
            }
            if (gasleft() < MIN_GAS_FOR_TRANSFER) {
                return;
            }
        }
    }

    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        override
        whenNotPaused
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint64[] memory needsFunding = _getUnderfundedSubscriptions();
        upkeepNeeded = needsFunding.length > 0;
        performData = abi.encode(needsFunding);
        return (upkeepNeeded, performData);
    }

    function performUpkeep(bytes calldata performData) external override onlyKeeperRegistry whenNotPaused {
        uint64[] memory needsFunding = abi.decode(performData, (uint64[]));
        if (needsFunding.length > 0) {
            if (needsPegswap) {
                _dexSwap(address(erc20Asset), address(erc20Link), erc20Asset.balanceOf(address(this)));
                _pegSwap();
            } else {
                _dexSwap(address(erc20Asset), address(erc677Link), erc20Asset.balanceOf(address(this)));
            }
            _topUp(needsFunding);
        }
    }

    /**
     * @notice Sets the VRF coordinator address.
     * @param coordinatorAddress The address of the VRF coordinator.
     */
    function setVRFCoordinatorV2Address(address coordinatorAddress) public onlyOwner {
        require(coordinatorAddress != address(0));
        emit VRFCoordinatorV2AddressUpdated(address(COORDINATOR), coordinatorAddress);
        COORDINATOR = VRFCoordinatorV2Interface(coordinatorAddress);
    }

    /**
     * @notice Sets the keeper registry address.
     * @param keeperAddress The address of the keeper registry.
     */
    function setKeeperRegistryAddress(address keeperAddress) public onlyOwner {
        require(keeperAddress != address(0));
        emit KeeperRegistryAddressUpdated(keeperRegistryAddress, keeperAddress);
        keeperRegistryAddress = keeperAddress;
    }

    /**
     * @notice Gets the keeper registry address.
     * @return address address of the keeper registry.
     */
    function getKeeperRegistryAddress() public view returns (address) {
        return keeperRegistryAddress;
    }

    /**
     * @notice Sets the LINK token address.
     * @param erc677Address The address of the ERC677 LINK token.
     */
    function setLinkTokenAddresses(address erc677Address, address erc20Address) public onlyOwner {
        require(erc677Address != address(0), "ERC677 address cannot be 0");
        if (erc20Address != address(0)) {
            needsPegswap = true;
            erc20Link = IERC20(erc20Address);
            erc677Link = LinkTokenInterface(erc677Address);
        } else {
            erc677Link = LinkTokenInterface(erc677Address);
        }
    }

    /**
     * @notice Gets the LINK token address.
     * @return address address of the LINK token ERC-677.
     */
    function getERC677Address() public view returns (address) {
        return address(erc677Link);
    }

    /**
     * @notice Gets the LINK token address.
     * @return address address of the LINK token ERC-20.
     */
    function getERC20Address() public view returns (address) {
        return address(erc20Link);
    }

    /**
     * @notice Sets the minimum wait period between top up checks.
     * @param period The minimum wait period in seconds.
     */
    function setMinWaitPeriodSeconds(uint256 period) public onlyOwner {
        emit MinWaitPeriodUpdated(minWaitPeriodSeconds, period);
        minWaitPeriodSeconds = period;
    }

    /**
     * @notice Gets the minimum wait period between top up checks.
     * @return uint256 minimum wait period in seconds.
     */
    function getMinWaitPeriodSeconds() public view returns (uint256) {
        return minWaitPeriodSeconds;
    }

    /**
     * @notice Sets the decentralized exchange address.
     * @param dexAddress The address of the decentralized exchange.
     * @dev The decentralized exchange must support the uniswap v2 router interface.
     */
    function setDEXAddress(address dexAddress) public onlyOwner {
        require(dexAddress != address(0));
        emit DEXAddressUpdated(dexAddress);
        dexRouter = IUniswapV2Router02(dexAddress);
    }

    /**
     * @notice Gets the decentralized exchange address.
     * @return address address of the decentralized exchange.
     */
    function getDEXRouter() public view returns (address) {
        return address(dexRouter);
    }

    /**
     * @notice Sets the minimum LINK balance the contract should have.
     * @param amount The minimum LINK balance in wei.
     */
    function setContractLINKMinBalance(uint256 amount) public onlyOwner {
        require(amount > 0);
        emit ContractLINKMinBalanceUpdated(contractLINKMinBalance, amount);
        contractLINKMinBalance = amount;
    }

    /**
     * @notice Gets the minimum LINK balance the contract should have.
     * @return uint256 The minimum LINK balance in wei.
     */
    function getContractLINKMinBalance() public view returns (uint256) {
        return contractLINKMinBalance;
    }

    /**
     * @notice Sets the address of the ERC20 asset being traded.
     * @param assetAddress The address of the ERC20 asset.
     *
     */
    function setERC20Asset(address assetAddress) public onlyOwner {
        require(assetAddress != address(0));
        emit ERC20AssetAddressUpdated(address(erc20Asset), assetAddress);
        erc20Asset = IERC20(assetAddress);
    }

    /**
     * @notice Gets the address of the ERC20 asset being traded.
     * @return address The address of the ERC20 asset.
     *
     */
    function getERC20Asset() public view returns (address) {
        return address(erc20Asset);
    }

    /**
     * @notice Gets an assets balance in the contract.
     * @param asset The address of the asset.
     * @return uint256 The assets balance in wei.
     *
     */
    function getAssetBalance(address asset) public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
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
     * @return bool
     */
    function isPaused() external view returns (bool) {
        return paused();
    }

    function withdraw(uint256 amount, address payable payee) external onlyOwner {
        require(payee != address(0));
        emit FundsWithdrawn(amount, payee);
        bool ok = erc677Link.transfer(payee, amount);
        require(ok, "LINK transfer failed");
    }

    function dexSwap(address fromToken, address toToken, uint256 amount) public onlyOwner {
        _dexSwap(fromToken, toToken, amount);
    }

    /**
     * @notice Uses the Uniswap Clone contract router to swap ERC20 for ERC20/ERC677 LINK.
     * @param fromToken Token address sending to swap.
     * @param toToken Token address receiving from swap.
     * @param amount Total tokens sending to swap.
     */
    function _dexSwap(address fromToken, address toToken, uint256 amount) internal whenNotPaused {
        address[] memory path = new address[](2);
        path[0] = fromToken;
        path[1] = toToken;
        IERC20(fromToken).safeIncreaseAllowance(address(dexRouter), amount);
        uint256[] memory amounts = dexRouter.swapExactTokensForTokens(amount, 1, path, address(this), block.timestamp);
        emit DexSwapSuccess(amounts[1], fromToken, toToken);
    }

    /**
     * @notice Publuc function to call the private _pegSwap function.
     */
    function pegSwap() external onlyOwner {
        _pegSwap();
    }

    /**
     * @notice Uses the PegSwap contract to swap ERC20 LINK for ERC677 LINK.
     */
    function _pegSwap() internal whenNotPaused {
        require(needsPegswap, "No pegswap needed");
        IERC20(erc20Link).safeIncreaseAllowance(address(pegSwapRouter), erc20Link.balanceOf(address(this)));
        pegSwapRouter.swap(erc20Link.balanceOf(address(this)), address(erc20Link), address(erc677Link));
        emit PegSwapSuccess(erc677Link.balanceOf(address(this)), address(erc20Link), address(erc677Link));
    }

    /**
     * @notice Sets PegSwap router address.
     * @param pegSwapAddress The address of the PegSwap router.
     */
    function setPegSwapRouter(address pegSwapAddress) external onlyOwner {
        require(pegSwapAddress != address(0));
        emit PegswapRouterUpdated(address(pegSwapRouter), pegSwapAddress);
        pegSwapRouter = PegswapInterface(pegSwapAddress);
        needsPegswap = true;
    }

    /**
     * @notice Gets PegSwap router address.
     * @return address address of the PegSwap router.
     */
    function getPegSwapRouter() external view returns (address) {
        return address(pegSwapRouter);
    }

    /**
     * @notice Sets the address of the ERC20 LINK token.
     * @param newAddress The address of the ERC20 LINK token.
     *
     */
    function setERC20Link(address newAddress) external onlyOwner {
        require(newAddress != address(0));
        erc20Link = IERC20(newAddress);
    }

    /**
     * @notice Withdraw token assets.
     * @param asset The address of the token to withdraw.
     *
     */
    function withdrawAsset(address asset) external onlyOwner {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        require(balance > 0, "Nothing to withdraw");
        bool ok = IERC20(asset).transfer(msg.sender, balance);
        require(ok, "token transfer failed");
    }
}
