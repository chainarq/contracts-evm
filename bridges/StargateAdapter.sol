// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../interfaces/IERC20U.sol";

import "../interfaces/IBridgeAdapter.sol";
import "../interfaces/IBridgeStargate.sol";

import "../lib/NativeWrap.sol";

contract StargateAdapter is Initializable, IBridgeAdapter, NativeWrap {
    using SafeERC20Upgradeable for IERC20U;

    struct StargateParams {
        // a unique identifier that is uses to dedup transfers
        // this value is the a timestamp sent from frontend, but in theory can be any unique number
        uint64 nonce;
        uint256 srcPoolId;
        uint256 dstPoolId;
        uint256 minReceivedAmt; // defines the slippage, the min qty you would accept on the destination
        uint16 stargateDstChainId; // stargate defines chain id in its way
        address router; // the target router, should be in the <ref>supportedRouters</ref>
    }

    mapping(address => bool) public supportedRouters;
    mapping(bytes32 => bool) public transfers;


    function initialize(address _nativeWrap, address[] memory _routers) external initializer {
        __Context_init();
        __Ownable_init();
        initNativeWrap(_nativeWrap);
        for (uint256 i = 0; i < _routers.length; i++) {
            require(_routers[i] != address(0), "nop");
            supportedRouters[_routers[i]] = true;
        }
    }

    function bridge(uint64 _dstChainId, address _receiver, uint256 _amount, address _token, bytes memory _bridgeParams, bytes memory _bridgePayload) external payable
    returns (bytes memory bridgeResp){
        StargateParams memory params = abi.decode((_bridgeParams), (StargateParams));
        require(supportedRouters[params.router], "illegal router");

        bytes32 transferId = keccak256(
            abi.encodePacked(_receiver, _token, _amount, _dstChainId, params.nonce, uint64(block.chainid))
        );

        require(transfers[transferId] == false, "transfer exists");

        transfers[transferId] = true;

        _safeTransferFrom(_token, _msgSender(), address(this), _amount);

        _swap(_token, _receiver, _amount, params, _bridgePayload);
    }

    function _swap(address _token, address _receiver, uint256 _amount, StargateParams memory params, bytes memory _payload) internal {
        IBridgeStargate _router = IBridgeStargate(params.router);

        if (_token == nativeWrap) {
            withdrawNative(_amount);
            _router.swapETH{value: msg.value + _amount}(
                params.stargateDstChainId,
                payable(_receiver),
                abi.encodePacked(_receiver),
                _amount,
                params.minReceivedAmt
            );
        } else {
            IBridgeStargate.lzTxObj memory _lzTxObj = (_payload.length > 0)
                ? IBridgeStargate.lzTxObj(5e5, 0, "")
                : IBridgeStargate.lzTxObj(0, 0, "");

            /**
            * @dev  Meant to be used with tokens that require the approval
            * to be set to zero before setting it to a non-zero value, such as USDT.
            */
            IERC20U(_token).forceApprove(address(_router), _amount);
            // @notice: try catch on the following always fails regardless if its successful or not...
            _router.swap{value: msg.value}(
                params.stargateDstChainId,
                params.srcPoolId,
                params.dstPoolId,
                payable(_receiver),
                _amount,
                params.minReceivedAmt,
                _lzTxObj,
                abi.encodePacked(_receiver),
                _payload
            );

            IERC20U(_token).safeApprove(address(_router), 0);
        }

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

    function _safeTransferFrom(address token, address from, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "StargateAdapter: TRANSFER_FROM_FAILED");
    }
}
