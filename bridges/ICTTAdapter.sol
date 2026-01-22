// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interfaces/IERC20U.sol";

import "../interfaces/IBridgeAdapter.sol";
import "../interfaces/IBridgeICTT.sol";
import {NativeWrap} from "../lib/NativeWrap.sol";

contract ICTTAdapter is Initializable, IBridgeAdapter, NativeWrap {
    using SafeERC20Upgradeable for IERC20U;

    struct ICTTParams {
        bytes32 destinationBlockchainID;
        address destinationTokenTransferrerAddress;
        address recipient;

        address router;
        uint64 nonce;
        uint amount;
    }

    mapping(bytes32 => bool) public transfers;
    address public terminus;

    mapping(address => bool) public supportedRouters;

    event ICTTMessageSent(bytes32 transferId, uint amount, uint64 dstChainId);
    event ICTTDebug(address sender, address token, uint balance, uint amount, bool isAmtBlcEq, uint64 dstChainId);


    modifier onlyTerminus() {
        require(_msgSender() == address(terminus), "only terminus");
        _;
    }

    modifier onlySelf(){
        require(_msgSender() == address(this), "ICTT only self");
        _;
    }

    function initialize(address _nativeWrap, address[] memory _routers) external initializer {
        __Context_init();
        __Ownable_init();
        initNativeWrap(_nativeWrap);
    }

    function bridge(uint64 _dstChainId, address _receiver, uint256 _amount, address _token, bytes calldata _bridgeParams, bytes calldata _bridgePayload) onlyTerminus
    external payable returns (bytes memory bridgeResp){

//        uint _bal = IERC20U(_token).balanceOf(_msgSender());
//        emit ICTTDebug(_msgSender(), _token, _bal, _amount, (_bal == _amount), _dstChainId);
//        return "";

//        _safeTransferFrom(_token, _msgSender(), address(this), _amount);
        IERC20U(_token).safeTransferFrom(_msgSender(), address(this), _amount);

        try this._decodeParams(_bridgeParams) returns (ICTTParams memory _bPrms){
            ICTTParams memory params = _bPrms;

            require(supportedRouters[params.router], "illegal router");

            bytes32 transferId = keccak256(
                abi.encodePacked(_receiver, _token, _amount, _dstChainId, params.nonce, uint64(block.chainid))
            );

            require(transfers[transferId] == false, "transfer exists");

            transfers[transferId] = true;

            emit ICTTMessageSent(transferId, _amount, _dstChainId);
            return _swap(_token, _receiver, _amount, params, _bridgePayload);
        } catch {}

        revert("ICTTAdapter: bridge failed");
    }

    function _swap(address _token, address _receiver, uint256 _amount, ICTTParams memory params, bytes memory _payload) internal returns (bytes memory _resp){
        address _router = params.router;

        SendTokensInput memory input = SendTokensInput(
            params.destinationBlockchainID,
            params.destinationTokenTransferrerAddress,
            _receiver,
            address(0),
            0,
            0,
            300000,
            address(0)
        );

        if (_token == nativeWrap) {
            withdrawNative(_amount);
            IBridgeICTT(_router).send{value: _amount}(input);
        } else {
            IERC20U(_token).forceApprove(address(_router), _amount);

            IBridgeICTT(_router).send(input, _amount);

            IERC20U(_token).safeApprove(address(_router), 0);
        }


    }

    function _decodeParams(bytes calldata _data) external view onlySelf returns (ICTTParams memory){
        return abi.decode((_data), (ICTTParams));
    }

    function setTerminus(address _addr) external onlyOwner {
        terminus = _addr;
    }

    function setSupportedRouters(address[] memory _routers, bool _enabled) public onlyOwner {
        for (uint i = 0; i < _routers.length; i++) {
            supportedRouters[_routers[i]] = _enabled;
        }
    }

    function rescueFund(address _token) external onlyOwner {
        if (_token == address(0)) {
            (bool ok,) = owner().call{value: address(this).balance}("");
            require(ok, "send native failed");
        } else {
            IERC20U(_token).safeTransfer(owner(), IERC20U(_token).balanceOf(address(this)));
        }
    }

/*
    function _safeTransferFrom(address token, address from, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "ICTTAdapter: TRANSFER_FROM_FAILED");
    }
*/
}
