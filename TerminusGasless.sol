// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "./lib/Types.sol";
import "./interfaces/IERC20U.sol";
import "./lib/Pauser.sol";
import "./interfaces/ITerminus.sol";


interface IERC20P is IERC20U {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
}

contract TerminusGasless is Initializable, ReentrancyGuardUpgradeable, Pauser {
    using SafeERC20Upgradeable for IERC20P;

    address public terminus;

    // @notice: the addresses allowed to execute messages
    mapping(address => bool) public executors;

    mapping(bytes32 => bool) public processed;

    uint public nonce;

    event ExecuteWithPermitSuccess(bytes32 id);
    event ExecuteWithPermitFailed(bytes32 id, string reason);

    function initialize() external initializer {
        __Context_init();
        __ReentrancyGuard_init();
        __Ownable_init();
        initPauser();
    }

    modifier onlyExecutor(){
        require(executors[_msgSender()], "only executor");
        _;
    }

    modifier onlySelf(){
        require(_msgSender() == address(this), "only self");
        _;
    }

    function terminusExecuteWithPermit(
        address _token, address _sender, uint _amount, uint _deadline,
        uint8 v, bytes32 r, bytes32 s,
        bytes calldata executeData
    ) external payable whenNotPaused nonReentrant onlyExecutor {

        bytes32 id = keccak256(abi.encodePacked(_token, _sender, _amount, _deadline, executeData, nonce));

        require(!processed[id], "execution already processed");

        // @notice execution will fail if executeData isn't valid
        try this._isValidExecuteData(executeData){
        } catch {
            revert("invalid exec data");
        }

        (bool _ok_1,) = _token.call(abi.encodeWithSelector(IERC20P.permit.selector, _sender, address(this), _amount, _deadline, v, r, s));
        require(_ok_1, "permit failed or invalid");

        (Types.Execution[] memory _execs, Types.Source memory _src, Types.Destination memory _dst) = _decodeExecData(executeData);

        IERC20P(_token).safeTransferFrom(_sender, address(this), _amount);

        IERC20P(_token).safeTransfer(address(terminus), _amount);

        ITerminus(terminus).executeGasless{value: msg.value}(_execs, _src, _dst, _amount, _token, address(this));

        emit ExecuteWithPermitSuccess(id);

        /*// @notice executeData includes the selector
        (bool _ok_2,) = terminus.call{value: msg.value}(executeData);

        if (_ok_2) {
            emit ExecuteWithPermitSuccess(id);
        } else {
            _executeWithPermitFailed(id, "terminus execution failed", _token, _sender, (_amount ));
        }*/

        processed[id] = true;
        nonce++;
    }

    /*function _executeWithPermitFailed(bytes32 id, string memory reason, address _token, address _sender, uint _amount) internal {

        emit ExecuteWithPermitFailed(id, reason);

        IERC20P(_token).transfer(_sender, _amount);
    }*/

    function _isValidExecuteData(bytes calldata executeData) external view onlySelf {
        (Types.Execution[] memory _execs, Types.Source memory _src, Types.Destination memory _dst) = abi.decode((executeData[4 :]), (Types.Execution[], Types.Source, Types.Destination));
    }

    function _decodeExecData(bytes calldata executeData) internal pure returns (Types.Execution[] memory, Types.Source memory, Types.Destination  memory) {
        (Types.Execution[] memory _execs, Types.Source memory _src, Types.Destination memory _dst) = abi.decode((executeData[4 :]), (Types.Execution[], Types.Source, Types.Destination));

        return (_execs, _src, _dst);
    }

    function setTerminus(address _addr) external onlyOwner {
        terminus = payable(_addr);
    }

    function setExecutors(address[] memory _addrs, bool _allowed) external onlyOwner {
        for (uint i = 0; i < _addrs.length; i++) {
            executors[_addrs[i]] = _allowed;
        }
    }

    function rescueFund(address _token) external onlyOwner {
        if (_token == address(0)) {
            (bool ok,) = owner().call{value: address(this).balance}("");
            require(ok, "send native failed");
        } else {
            IERC20P(_token).safeTransfer(owner(), IERC20P(_token).balanceOf(address(this)));
        }
    }
}
