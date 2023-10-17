// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.8/ConfirmedOwner.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../oracle/interfaces/IFastPriceFeed.sol";
import "../oracle/interfaces/IChainPriceFeed.sol";

contract AutoPriceV2 is
    AutomationCompatibleInterface,
    ChainlinkClient,
    ConfirmedOwner
{
    using Chainlink for Chainlink.Request;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct Req {
        string url;
        string path;
    }

    bytes32 public constant jobId = "ca98366cc7314957b8c012c72f05aeeb";
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public diff_limit = 10;

    address public fastPriceFeed;
    address public chainPriceFeed;

    address public linkToken;
    address public apiOracle;
    uint256 public fee;

    // address public tokens;
    // string public url;
    // string public path;
    // uint256 public price;

    // set of token address
    EnumerableSet.AddressSet private tokens;
    mapping(address => Req) public urls;
    mapping(address => uint256) public prices;
    mapping(bytes32 => address) public requestToken;

    uint256 public minBlockInterval;
    mapping(address => uint256) public lastUpdatedBlock;
    // uint256 public lastUpdatedBlock;

    event RequestPrice(bytes32 indexed requestId, uint256 volume);

    /**
     * @notice Initialize the link token and target oracle
     */
    // 0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846  linkToken
    // 0x022EEA14A6010167ca026B32576D6686dD7e85d2  oracle
    // 100000000000000000                          0.1 link fee
    constructor(
        address token,
        address oracle,
        uint256 fees
    ) ConfirmedOwner(msg.sender) {
        setLinkToken(token);
        setAPIOracle(oracle);

        setFee(fees);
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

    function setFee(uint256 fees) public onlyOwner {
        require(fees > 0, "invalid fee");
        fee = fees;
    }

    function setFastPriceFeed(address feed) external onlyOwner {
        require(feed != address(0), "invalid fastPrice feed");

        fastPriceFeed = feed;
        chainPriceFeed = IFastPriceFeed(fastPriceFeed).chainPriceFeed();

        require(chainPriceFeed != address(0), "invalid chainPrice feed");
    }

    function setMinBlockInterval(uint256 interval) external onlyOwner {
        minBlockInterval = interval;
    }

    // "https://min-api.cryptocompare.com/data/pricemultifull?fsyms=ETH&tsyms=USD"  "RAW,ETH,USD,PRICE"
    function addToken(
        address token,
        string memory url,
        string memory path
    ) external onlyOwner {
        require(token != address(0), "invalid token");

        tokens.add(token);

        Req memory _req = Req({url: url, path: path});
        urls[token] = _req;
    }

    function removeToken(address token) external onlyOwner {
        require(token != address(0), "invalid token");

        tokens.remove(token);
        delete urls[token];
        delete prices[token];
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
        uint256 _cnt = tokens.length();

        for (uint256 i = 0; i < _cnt; i++) {
            address _token = tokens.at(i);

            if (_checkUpdate(_token)) {
                performData = abi.encode(_token);
                return (true, performData);
            }
        }

        return (false, performData);
    }

    function _checkUpdate(address token) private view returns (bool) {
        if (token == address(0)) {
            return false;
        }
        if (!_isUpdate(token)) {
            return false;
        }

        uint256 _fastPrice = IFastPriceFeed(fastPriceFeed).prices(token);
        if (_fastPrice == 0) {
            return true;
        }

        // uint256 _chainPrice = IChainPriceFeed(chainPriceFeed).getLatestFormatPrice(token);
        uint256 _chainPrice;

        uint256 _diff = _fastPrice > _chainPrice
            ? ((_fastPrice - _chainPrice) * BASIS_POINTS_DIVISOR) / _chainPrice
            : ((_chainPrice - _fastPrice) * BASIS_POINTS_DIVISOR) / _fastPrice;

        if (_diff < diff_limit) {
            return false;
        }
        return true;
    }

    /* @dev this method is called by the Automation Nodes. it increases all elements whose balances are lower than the LIMIT. Note that the elements are bounded by `lowerBound`and `upperBound`
     *  (provided by `performData`
     *
     *  @dev `performData` is an encoded binary data which contains the lower bound and upper bound of the subarray on which to perform the computation.
     *  it also contains the increments
     *
     *  @dev return `upkeepNeeded`if rebalancing must be done and `performData` which contains an array of increments. This will be used in `performUpkeep`
     */
    function performUpkeep(bytes calldata performData) external override {
        // bytes32[] memory _keys = abi.decode(performData, (bytes32[]));
        address _token = abi.decode(performData, (address));

        Req memory _req = urls[_token];
        bytes32 _id = requestPrice(_req.url, _req.path);

        requestToken[_id] = _token;
    }

    /**
     * Create a Chainlink request to retrieve API response, find the target
     * data, then multiply by 1000000000000000000 (to remove decimal places from data).
     */
    function requestPrice(
        string memory url,
        string memory path
    ) public returns (bytes32 requestId) {
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

        address _token = requestToken[_requestId];

        address[] memory _tokens = new address[](1);
        uint256[] memory _prices = new uint256[](1);

        _tokens[0] = _token;
        _prices[0] = _price;

        IFastPriceFeed(fastPriceFeed).setPrices(
            _tokens,
            _prices,
            block.timestamp
        );

        _setLastUpdatedValues(_token, _price);
        delete requestToken[_requestId];

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

    function _isUpdate(address token) private view returns (bool) {
        if (minBlockInterval > 0) {
            if ((block.number - lastUpdatedBlock[token]) >= minBlockInterval) {
                return true;
            }
            return false;
        }
        return true;
    }

    function _setLastUpdatedValues(address token, uint256 price) private {
        require(_isUpdate(token), "minBlockInterval not yet passed");

        prices[token] = price;
        lastUpdatedBlock[token] = block.number;
    }
}
