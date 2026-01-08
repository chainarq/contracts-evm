// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../interfaces/IERC20U.sol";
import "../interfaces/IBridgeAdapter.sol";

import "../lib/NativeWrap.sol";

interface ArQRouter {
    function swap(uint16 srcPoolId, uint32 dstDomainId, uint16 dstPoolId, address receiver, uint amount) external payable returns (bytes32 msgId);
}

contract ArQAdapter is Initializable, IBridgeAdapter, NativeWrap {
    using SafeERC20Upgradeable for IERC20U;

    struct ArqParams {
        uint64 nonce;
        address router;
        uint16 srcPoolId;
        uint32 dstDomainId;
        uint16 dstPoolId;
        uint amount;
    }

    mapping(address => bool) public supportedRouters;
    mapping(bytes32 => bool) public transfers;

    address public terminus;

    modifier onlyTerminus() {
        require(_msgSender() == address(terminus), "only terminus");
        _;
    }

    function initialize(address _nativeWrap) external initializer {
        __Context_init();
        __Ownable_init();
        initNativeWrap(_nativeWrap);
    }

    function bridge(uint64 _dstChainId, address _receiver, uint256 _amount, address _token, bytes memory _bridgeParams, bytes memory _bridgePayload) external payable onlyTerminus
    returns (bytes memory bridgeResp){
        ArqParams memory params = abi.decode((_bridgeParams), (ArqParams));
        require(supportedRouters[params.router], "illegal router");

        bytes32 transferId = keccak256(
            abi.encodePacked(_receiver, _token, _amount, _dstChainId, params.nonce, uint64(block.chainid))
        );

        require(transfers[transferId] == false, "transfer exists");

        transfers[transferId] = true;

        _safeTransferFrom(_token, _msgSender(), address(this), _amount);

        _swap(_token, _receiver, _amount, params);
    }

    function _swap(address _token, address _receiver, uint _amount, ArqParams memory params) internal {
        ArQRouter _router = ArQRouter(params.router);

        IERC20U(_token).forceApprove(address(_router), _amount);

        uint _msgValue = msg.value;

        if (_token == nativeWrap) {
            withdrawNative(_amount);
            _msgValue += _amount;
        }

        _router.swap{value: _msgValue}(
            params.srcPoolId,
            params.dstDomainId,
            params.dstPoolId,
            _receiver,
            _amount
        );

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

    function setTerminus(address _addr) external onlyOwner {
        terminus = _addr;
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "ArqAdapter: TRANSFER_FROM_FAILED");
    }


}
