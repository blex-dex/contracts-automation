// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";

import {IPrice} from "../oracle/interfaces/IPrice.sol";
import {IMarket} from "../market/interfaces/IMarket.sol";
import {IOrderBook} from "../order/interface/IOrderBook.sol";
import {IOrderStore} from "../order/interface/IOrderStore.sol";

import {Order} from "../order/OrderStruct.sol";
import {MarketDataTypes} from "../market/MarketDataTypes.sol";
import {IMarketValid} from "./../market/interfaces/IMarketValid.sol";

/**
 * @dev Example contract which perform most of the computation in `checkUpkeep`
 *
 * @notice important to implement {AutomationCompatibleInterface}
 */
contract AutoOrderBase is Ownable {
    using SafeERC20 for IERC20;
    using Order for Order.Props;
    using MarketDataTypes for MarketDataTypes.UpdatePositionInputs;

    address public market;
    address public indexToken;
    address public orderBook;
    address public oracle;
    bool public isIncrease;
    bool public isLong;

    uint256 public orderLimit = 5;

    function setMarket(address m) external onlyOwner {
        market = m;
        oracle = IMarket(market).priceFeed();
        indexToken = IMarket(market).indexToken();

        orderBook = address(
            isLong
                ? IMarket(market).orderBookLong()
                : IMarket(market).orderBookShort()
        );
    }

    constructor(address marketAddr, bool isOpen, bool islong) {
        require(marketAddr != address(0), "invalid market");
        market = marketAddr;
        isIncrease = isOpen;
        isLong = islong;
        oracle = IMarket(market).priceFeed();
        indexToken = IMarket(market).indexToken();
        orderBook = address(
            isLong
                ? IMarket(market).orderBookLong()
                : IMarket(market).orderBookShort()
        );
    }

    function setLimit(uint256 limit) external onlyOwner {
        require(limit > 0, "invalid limit");
        orderLimit = limit;
    }

    function withdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    function _getPrice() internal view returns (uint256) {
        return IPrice(oracle).getPrice(indexToken, isLong == isIncrease);
    }

    function _checkExecOrder(
        uint256 lower,
        uint256 upper
    ) internal view returns (bytes32[] memory keys) {
        uint256 _price = _getPrice();
        return _getExecOrders(lower, upper, _price);
    }

    function isLiq(Order.Props memory _order) internal view returns (bool) {
        IMarket im = IMarket(market);
        IMarketValid mv = IMarketValid(im.marketValid());
        return
            mv.isLiquidate(
                _order.account,
                market,
                isLong,
                im.positionBook(),
                im.feeRouter(),
                IPrice(im.priceFeed()).getPrice(im.indexToken(), !isLong)
            ) > 0;
    }

    function _execOrder(Order.Props memory _order) internal {
        MarketDataTypes.UpdatePositionInputs memory _vars;
        _vars.initialize(isIncrease);
        _vars._market = market;
        _vars._isLong = isLong;
        _vars._sizeDelta = _order.size;
        _vars._price = _order.price;
        _vars._refCode = _order.refCode;
        _vars._isExec = true;
        _vars._fromOrder = _order.orderID;
        _vars._account = _order.account;
        _vars.collateralDelta = _order.collateral;
        if (isIncrease) {
            _vars.setTp(_order.getTakeprofit());
            _vars.setSl(_order.getStoploss());
        } else {
            _vars.setIsKeepLev(_order.getIsKeepLev());
        }

        IMarket(market).execOrderKey(_order, _vars);
    }

    function _performUpkeep(bytes32[] memory keys) internal {
        IOrderBook _orderBook = IOrderBook(orderBook);
        IOrderStore _store = isIncrease
            ? _orderBook.openStore()
            : _orderBook.closeStore();
        uint256 len = keys.length;
        for (uint i = 0; i < len; ) {
            bytes32 _orderKey = keys[i];
            Order.Props memory _order = _store.orders(_orderKey);
            _execOrder(_order);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev 内部函数，获取价格在给定范围内可执行的订单的键列表。
     * @param lower uint256 可执行订单价格下限。
     * @param upper uint256 可执行订单价格上限。
     * @param price uint256 当前执行价格。
     * @return keys bytes32[] 订单键的列表。
     */
    function _getExecOrders(
        uint256 lower,
        uint256 upper,
        uint256 price
    ) internal view returns (bytes32[] memory keys) {
        Order.Props[] memory _orders = IOrderBook(orderBook)
            .getExecutableOrdersByPrice(lower, upper, isIncrease, price);
        if (_orders.length == 0) {
            return keys;
        }

        uint256 _count = _orders.length > orderLimit
            ? orderLimit
            : _orders.length;
        keys = new bytes32[](_count);

        for (uint256 _index; _index < _count; _index++) {
            Order.Props memory _order = _orders[_index];
            keys[_index] = _order.getKey();
        }
    }
}

contract AutoOrder is AutomationCompatibleInterface, AutoOrderBase {
    using SafeERC20 for IERC20;
    using Order for Order.Props;
    using MarketDataTypes for MarketDataTypes.UpdatePositionInputs;

    constructor(
        address marketAddr,
        bool isOpen,
        bool islong
    ) AutoOrderBase(marketAddr, isOpen, islong) {}

    function performIndex(uint256 lower, uint256 upper) external {
        Order.Props[] memory orders = IOrderBook(orderBook)
            .getExecutableOrdersByPrice(lower, upper, isIncrease, _getPrice());
        for (uint i = 0; i < orders.length; i++) {
            Order.Props memory _order = orders[i];
            _execOrder(_order);
        }
    }

    function checkIndex(
        uint256 lower,
        uint256 upper
    ) external view returns (Order.Props[] memory ordersForReturn) {
        Order.Props[] memory _orders = IOrderBook(orderBook)
            .getExecutableOrdersByPrice(lower, upper, isIncrease, _getPrice());
        uint256 countForReturn;
        for (uint i = 0; i < _orders.length; i++)
            if (false == isLiq(_orders[i])) ++countForReturn;
        ordersForReturn = new Order.Props[](countForReturn);
        uint256 j;
        for (uint i = 0; i < _orders.length; i++)
            if (false == isLiq(_orders[i])) {
                ordersForReturn[j] = _orders[i];
                ++j;
            }
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

        bytes32[] memory _keys = _checkExecOrder(_lower, _upper);

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
        bytes32[] memory _keys = abi.decode(performData, (bytes32[]));
        _performUpkeep(_keys);
    }
}

contract AutoOrderMock is AutoOrder {
    constructor(
        address marketAddr,
        bool isOpen,
        bool islong
    ) AutoOrder(marketAddr, isOpen, islong) {}
}
