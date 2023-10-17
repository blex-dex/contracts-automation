// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";

import {IPrice} from "../oracle/interfaces/IPrice.sol";
import {IMarket} from "../market/interfaces/IMarket.sol";
import {IOrderBook} from "../order/interface/IOrderBook.sol";
import {IPositionBook} from "../position/interfaces/IPositionBook.sol";
import {IOrderStore} from "../order/interface/IOrderStore.sol";
import {IMarketValid} from "./../market/interfaces/IMarketValid.sol";

import {Order} from "../order/OrderStruct.sol";
import {MarketDataTypes} from "../market/MarketDataTypes.sol";

contract AutoLiquidateBase is Ownable {
    using SafeERC20 for IERC20;

    address public market;
    address public priceOracle;
    bool public isLong;

    uint256 public execLimit = 5;

    function setMarket(address m) external onlyOwner {
        market = m;
        priceOracle = IMarket(market).priceFeed();
    }

    constructor(address marketAddr, bool islong) {
        require(marketAddr != address(0), "invalid market");

        market = marketAddr;
        isLong = islong;
        priceOracle = IMarket(market).priceFeed();
    }

    function setLimit(uint256 limit) external onlyOwner {
        require(limit > 0, "invalid limit");
        execLimit = limit;
    }

    function withdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    function _getPrice() private view returns (uint256) {
        address _indexToken = IMarket(market).indexToken();
        return IPrice(priceOracle).getPrice(_indexToken, !isLong);
    }

    function _checkUpkeep(
        uint256 lower,
        uint256 upper
    ) internal view returns (address[] memory keys) {
        IPositionBook _positionBook = IMarket(market).positionBook();
        address[] memory _keys = _positionBook.getPositionKeys(
            lower,
            upper,
            isLong
        );
        address[] memory _need = new address[](_keys.length);

        uint256 _count;
        for (uint i; i < _keys.length && _count < execLimit; i++) {
            if (!_isLiquidate(_keys[i])) {
                continue;
            }

            _need[_count] = _keys[i];
            _count++;
        }

        if (_count != 0) {
            keys = new address[](_count);
            for (uint i; i < _count; i++) {
                keys[i] = _need[i];
            }
        }
    }

    function _isLiquidate(address account) private view returns (bool) {
        IMarketValid _valid = IMarket(market).marketValid();
        uint256 _state = _valid.isLiquidate(
            account,
            market,
            isLong,
            IMarket(market).positionBook(),
            IMarket(market).feeRouter(),
            _getPrice()
        );

        return (_state > 0);
    }

    function _performUpkeep(address[] memory keys) internal {
        IMarket(market).liquidatePositions(keys, isLong);
    }
}

/**
 * @dev Example contract which perform most of the computation in `checkUpkeep`
 *
 * @notice important to implement {AutomationCompatibleInterface}
 */
contract AutoLiquidate is AutomationCompatibleInterface, AutoLiquidateBase {
    constructor(
        address marketAddr,
        bool islong
    ) AutoLiquidateBase(marketAddr, islong) {}

    function checkIndex(
        uint256 _lower,
        uint256 _upper
    ) external view returns (address[] memory keys) {
        return _checkUpkeep(_lower, _upper);
    }

    function performIndex(uint256 _lower, uint256 _upper) external {
        address[] memory keys = _checkUpkeep(_lower, _upper);
        _performUpkeep(keys);
    }

    /* @dev this method is called by the Chainlink Automation Nodes to check if `performUpkeep` must be done. Note that `checkData` is used to segment the computation to subarrays.
     *
     *  @dev `checkData` is an encoded binary data and which contains the lower bound and upper bound on which to perform the computation
     *
     *  @dev return `upkeepNeeded`if rebalancing must be done and `performData` which contains an array of indexes that require rebalancing and their increments. This will be used in `performUpkeep`
     */
    function checkUpkeep(
        bytes memory checkData
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        (uint256 _lower, uint256 _upper) = abi.decode(
            checkData,
            (uint256, uint256)
        );
        require(_upper > _lower, "invalid params");

        address[] memory _keys = _checkUpkeep(_lower, _upper);

        if (_keys.length == 0) {
            return (false, performData);
        }
        performData = abi.encode(_keys);
        return (true, performData);
    }

    /* @dev this method is called by the Automation Nodes. it increases all elements whose balances are lower than the LIMIT. Note that the elements are bounded by `lowerBound`and `upperBound`
     *  (provided by `performData`
     *
     *  @dev `performData` is an encoded binary data which contains the lower bound and upper bound of the subarray on which to perform the computation.
     *  it also contains the increments
     *
     *  @dev return `upkeepNeeded`if rebalancing must be done and `performData` which contains an array of increments. This will be used in `performUpkeep`
     */
    function performUpkeep(bytes memory performData) external override {
        address[] memory _keys = abi.decode(performData, (address[]));
        require(_keys.length > 0, "invalid params");

        _performUpkeep(_keys);
    }
}

contract AutoLiquidateMock is AutoLiquidate {
    constructor(
        address marketAddr,
        bool islong
    ) AutoLiquidate(marketAddr, islong) {}
}
