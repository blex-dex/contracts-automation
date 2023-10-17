// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.8/ConfirmedOwner.sol";

import "../oracle/interfaces/IFastPriceFeed.sol";
import "../oracle/interfaces/IChainPriceFeed.sol";

contract AutoPrice is
    AutomationCompatibleInterface,
    ChainlinkClient,
    ConfirmedOwner
{
    using Chainlink for Chainlink.Request;

    bytes32 public constant jobId = "ca98366cc7314957b8c012c72f05aeeb";
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public diff_limit = 10;

    address public fastPriceFeed;
    address public chainPriceFeed;

    address public linkToken;
    address public apiOracle;
    uint256 public fee;

    address public tokens;
    string public url;
    string public path;
    uint256 public price;

    uint256 public minTimeInterval;
    uint256 public lastUpdatedAt;
    uint256 public minBlockInterval;
    uint256 public lastUpdatedBlock;

    event RequestPrice(bytes32 indexed requestId, uint256 volume);

    /**
     * @notice Initialize the link token and target oracle
     */
    // 0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846  linkToken
    // 0x022EEA14A6010167ca026B32576D6686dD7e85d2  oracle
    constructor(
        address _linkToken,
        address _apiOracle,
        uint256 _fee
    ) ConfirmedOwner(msg.sender) {
        setFee(_fee);
        setLinkToken(_linkToken);
        setAPIOracle(_apiOracle);
    }

    // function set
    function setLinkToken(address token) public onlyOwner {
        require(token != address(0), "invalid link token");
        linkToken = token;
        setChainlinkToken(token);
    }

    function setAPIOracle(address oracle) public onlyOwner {
        require(oracle != address(0), "invalid API Oracle");
        apiOracle = oracle;
        setChainlinkOracle(oracle);
    }

    function setFee(uint256 _fee) public onlyOwner {
        require(_fee > 0, "invalid fee");
        fee = _fee;
    }

    function setFastPriceFeed(address feed) external onlyOwner {
        require(feed != address(0), "invalid fastPrice feed");

        fastPriceFeed = feed;
        chainPriceFeed = IFastPriceFeed(fastPriceFeed).chainPriceFeed();

        require(chainPriceFeed != address(0), "invalid chainPrice feed");
    }

    // "https://min-api.cryptocompare.com/data/pricemultifull?fsyms=ETH&tsyms=USD"  "RAW,ETH,USD,PRICE"
    // "https://min-api.cryptocompare.com/data/pricemultifull?fsyms=BTC&tsyms=USD"  "RAW,BTC,USD,PRICE"
    function setToken(
        address token,
        string memory _url,
        string memory _path
    ) external onlyOwner {
        require(token != address(0), "invalid token");
        tokens = token;
        url = _url;
        path = _path;
    }

    function setMinBlockInterval(uint256 interval) external onlyOwner {
        minBlockInterval = interval;
    }

    function setMinTimeInterval(uint256 interval) external onlyOwner {
        minTimeInterval = interval;
    }

    /* @dev this method is called by the Chainlink Automation Nodes to check if `performUpkeep` must be done. Note that `checkData` is used to segment the computation to subarrays.
     *
     *  @dev `checkData` is an encoded binary data and which contains the lower bound and upper bound on which to perform the computation
     *
     *  @dev return `upkeepNeeded`if rebalancing must be done and `performData` which contains an array of indexes that require rebalancing and their increments. This will be used in `performUpkeep`
     */
    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (!_isUpdate()) {
            return (false, performData);
        }

        uint256 _fastPrice = IFastPriceFeed(fastPriceFeed).prices(tokens);
        if (_fastPrice == 0) {
            return (true, performData);
        }

        uint256 _chainPrice = _getChainPrice();

        uint256 _diff = _fastPrice > _chainPrice
            ? ((_fastPrice - _chainPrice) * BASIS_POINTS_DIVISOR) / _chainPrice
            : ((_chainPrice - _fastPrice) * BASIS_POINTS_DIVISOR) / _fastPrice;

        if (_diff < diff_limit) {
            return (false, performData);
        }

        return (true, performData);
    }

    function _getChainPrice() private view returns (uint256) {
        uint256 _price = IChainPriceFeed(chainPriceFeed).getLatestPrice(tokens);
        uint256 _decimals = IChainPriceFeed(chainPriceFeed).priceDecimals(tokens);
        uint256 _precision = IChainPriceFeed(chainPriceFeed).PRICE_PRECISION();

        return _price * _precision / (10 ** _decimals);
    }

    /* @dev this method is called by the Automation Nodes. it increases all elements whose balances are lower than the LIMIT. Note that the elements are bounded by `lowerBound`and `upperBound`
     *  (provided by `performData`
     *
     *  @dev `performData` is an encoded binary data which contains the lower bound and upper bound of the subarray on which to perform the computation.
     *  it also contains the increments
     *
     *  @dev return `upkeepNeeded`if rebalancing must be done and `performData` which contains an array of increments. This will be used in `performUpkeep`
     */
    function performUpkeep(bytes calldata /* performData */) external override {
        // bytes32[] memory _keys = abi.decode(performData, (bytes32[]));
        requestPrice();
    }

    /**
     * Create a Chainlink request to retrieve API response, find the target
     * data, then multiply by 1000000000000000000 (to remove decimal places from data).
     */
    function requestPrice() public returns (bytes32 requestId) {
        Chainlink.Request memory req = buildChainlinkRequest(
            jobId,
            address(this),
            this.fulfill.selector
        );

        // Set the URL to perform the GET request on
        req.add("get", url);

        // Set the path to find the desired data in the API response, where the response format is:
        // request.add("path", "RAW.ETH.USD.VOLUME24HOUR"); // Chainlink nodes prior to 1.0.0 support this format
        req.add("path", path); // Chainlink nodes 1.0.0 and later support this format

        // Multiply the result by 1000000000000000000 to remove decimals
        int256 timesAmount = 10 ** 30;
        req.addInt("times", timesAmount);

        // Sends the request
        return sendChainlinkRequest(req, fee);
    }

    /**
     * Receive the response in the form of uint256
     */
    function fulfill(
        bytes32 _requestId,
        uint256 _price
    ) public recordChainlinkFulfillment(_requestId) {
        require(_price > 0, "invalid price");

        address[] memory _tokens = new address[](1);
        uint256[] memory _prices = new uint256[](1);

        _tokens[0] = tokens;
        _prices[0] = _price;

        IFastPriceFeed(fastPriceFeed).setPrices(
            _tokens,
            _prices,
            block.timestamp
        );

        _setLastUpdatedValues(_price);
        emit RequestPrice(_requestId, _price);
    }

    /**
     * Allow withdraw of Link tokens from the contract
     */
    function withdrawLink() public onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(
            link.transfer(msg.sender, link.balanceOf(address(this))),
            "Unable to transfer"
        );
    }

    function _isUpdate() private view returns (bool) {
        if (minBlockInterval > 0) {
            if (block.number - lastUpdatedBlock >= minBlockInterval) {
                return true;
            }
            return false;
        }
        if (minTimeInterval > 0) {
            if (block.timestamp - lastUpdatedAt >= minTimeInterval) {
                return true;
            }
            return false;
        }

        return true;
    }

    function _setLastUpdatedValues(uint256 _price) private {
        require(_isUpdate(), "minBlockInterval not yet passed");

        price = _price;
        lastUpdatedAt = block.timestamp;
        lastUpdatedBlock = block.number;
    }
}
