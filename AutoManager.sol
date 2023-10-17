// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";

import "./interfaces/IKeeperRegistry.sol";

contract AutoManager is AutomationCompatibleInterface, Ownable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    uint256 public constant MIN_ADD_FUNDS = 1e18;

    uint8 public multiplier = 1;   // balance of link min multiplier
    uint8 public execLimit = 50;

    address public linkToken;   // link contract address

    EnumerableSet.UintSet ids;
    mapping(uint256 => address) public registries;
    mapping(uint256 => uint96)  public minAddFunds;

    event AddAutoMation(uint256 id);
    event RemoveAutoMation(uint256 id);

    constructor(address token) {
        require(token != address(0), "invalid token");
        linkToken = token;
    }

    function setLinkToken(address token) external onlyOwner {
        require(token != address(0), "invalid token");
        linkToken = token;
    }

    function setMultiplier(uint8 mul) external onlyOwner {
        require(mul > 0, "invalid multiplier");
        multiplier = mul;
    }

    function setLimit(uint8 limit) external onlyOwner {
        require(limit > 0, "invalid limit");
        execLimit = limit;
    }

    function setMinAddFunds(uint256 id, uint96 minAdd) external onlyOwner {
        require(ids.contains(id), "automation not exist");
        require(minAdd >= MIN_ADD_FUNDS, "invalid value");

        minAddFunds[id] = minAdd;
    }

    function addAutoMation(uint256 id, address registry, uint96 minAdd) external onlyOwner {
        require(id != 0, "invalid id");
        require(minAdd >= MIN_ADD_FUNDS, "invalid value");
        require(registry != address(0), "invalid registry");
        require(!ids.contains(id), "automation already exist");

        ids.add(id);
        minAddFunds[id] = minAdd;
        registries[id] = registry;

        emit AddAutoMation(id);
    }

    function removeAutoMation(uint256 id) external onlyOwner {
        require(ids.contains(id), "automation not exist");

        ids.remove(id);
        delete minAddFunds[id];
        delete registries[id];

        emit RemoveAutoMation(id);
    }

    function withdraw(address to, uint256 amount) external onlyOwner {
        IERC20(linkToken).safeTransfer(to, amount);
    }

    function length() external view returns (uint256) { 
        return ids.length(); 
    }
    
    function getIds() external view returns (uint256[] memory) {
        return ids.values();
    }

    function _isNeedAddFund(uint256 id) private view returns (bool) {
        address _registry = registries[id];

        uint96 _min = IKeeperRegistry(_registry).getMinBalanceForUpkeep(id);
        UpkeepInfo memory _info = IKeeperRegistry(_registry).getUpkeep(id);
    
        return (_info.balance <= (_min * multiplier));
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
        uint256[] memory _ids = ids.values();
        uint256[] memory _needs = new uint256[](_ids.length);
        uint256 _index;

        for (uint256 i = 0; i < _ids.length && _index < execLimit; i++) {
            uint256 _id = _ids[i];
            bool _isNeed = _isNeedAddFund(_id);
            if (_isNeed) {
                _needs[_index] = _id;
                _index++;
            }
        }

        if (_index == 0) {
            return (false, performData);
        }

        uint256[] memory _datas = new uint256[](_index);
        for (uint256 i = 0; i < _index; i++) {
            _datas[i] = _needs[i];
        }
        performData = abi.encode(_datas);
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
    function performUpkeep(bytes calldata performData) external override {
        uint256[] memory _ids = abi.decode(performData, (uint256[]));
        require(_ids.length != 0, "ids is empty");

        for (uint256 i = 0; i < _ids.length; i++) {
            uint256 _id = _ids[i];

            bool _isNeed = _isNeedAddFund(_id);
            if (_isNeed) {  
                address _registry = registries[_id];
                IERC20(linkToken).approve(_registry, uint256(minAddFunds[_id]));
                IKeeperRegistry(_registry).addFunds(_id, minAddFunds[_id]);
            }
        }
    }
}
