// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../interfaces/IERC20U.sol";
import "../interfaces/IBridgeAdapter.sol";
//import "../interfaces/ISquidRouter.sol";

import "../lib/NativeWrap.sol";

contract HyperlaneAdapter is Initializable, IBridgeAdapter, NativeWrap {
    using SafeERC20Upgradeable for IERC20U;

    struct LaneParams {
        uint64 nonce;
        address router;
        bytes data;
    }

    mapping(address => bool) public supportedRouters;
    mapping(bytes32 => bool) public transfers;

    function initialize(address _nativeWrap) external initializer {
        __Context_init();
        __Ownable_init();
        initNativeWrap(_nativeWrap);
    }

    function bridge(uint64 _dstChainId, address _receiver, uint256 _amount, address _token, bytes memory _bridgeParams, bytes memory _bridgePayload) external payable
    returns (bytes memory bridgeResp){
        LaneParams memory params = abi.decode((_bridgeParams), (LaneParams));
        require(supportedRouters[params.router], "illegal router");

        bytes32 transferId = keccak256(
            abi.encodePacked(_receiver, _token, _amount, _dstChainId, params.nonce, uint64(block.chainid))
        );

        require(transfers[transferId] == false, "transfer exists");

        transfers[transferId] = true;

        _safeTransferFrom(_token, _msgSender(), address(this), _amount);

        _swap(_token, _amount, params);

    }

    function _swap(address _token, uint _amount, LaneParams memory params) internal {
        // ISquidRouter _router = ISquidRouter(params.router);
        address _router = params.router;

        IERC20U(_token).forceApprove(address(_router), _amount);

        _router.call{value: msg.value}(params.data);

        IERC20U(_token).safeApprove(address(_router), 0);
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
        require(success && (data.length == 0 || abi.decode(data, (bool))), "LaneAdapter: TRANSFER_FROM_FAILED");
    }

}
