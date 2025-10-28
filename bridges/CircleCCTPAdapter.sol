// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interfaces/IERC20U.sol";

import "../interfaces/IBridgeAdapter.sol";
import "../interfaces/IBridgeCircle.sol";

import "../lib/NativeWrap.sol";

contract CircleCCTPAdapter is Initializable, IBridgeAdapter, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20U;

    struct CCTPParams {
        uint64 nonce;
        uint32 dstDomain;
        address router; // the target TokenMessenger
    }

    mapping(address => bool) public supportedRouters;
    mapping(bytes32 => bool) public transfers;

    event CircleMessageSent(bytes32 transferId, uint amount, uint64 dstChainId);

    function initialize(address[] memory _routers) external initializer {
        __Context_init();
        __Ownable_init();

        for (uint256 i = 0; i < _routers.length; i++) {
            require(_routers[i] != address(0), "nop");
            supportedRouters[_routers[i]] = true;
        }
    }

    function bridge(uint64 _dstChainId, address _receiver, uint256 _amount, address _token, bytes memory _bridgeParams, bytes memory _bridgePayload)
    external payable returns (bytes memory bridgeResp){
        CCTPParams memory params = abi.decode((_bridgeParams), (CCTPParams));
        require(supportedRouters[params.router], "illegal router");

        bytes32 transferId = keccak256(
            abi.encodePacked(_receiver, _token, _amount, _dstChainId, params.nonce, uint64(block.chainid))
        );

        require(transfers[transferId] == false, "transfer exists");

        transfers[transferId] = true;

        _safeTransferFrom(_token, _msgSender(), address(this), _amount);

        _swap(_token, _receiver, _amount, params, _bridgePayload);

        emit CircleMessageSent(transferId, _amount, _dstChainId);
    }

    function _swap(address _token, address _receiver, uint256 _amount, CCTPParams memory params, bytes memory _payload) internal {
        address _router = params.router;

        IERC20U(_token).forceApprove(address(_router), _amount);

        IBridgeCircle(_router).depositForBurn(_amount, params.dstDomain, addressToBytes32(_receiver), _token);

        IERC20U(_token).safeApprove(address(_router), 0);

    }

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
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
        require(success && (data.length == 0 || abi.decode(data, (bool))), "CircleCCTPAdapter: TRANSFER_FROM_FAILED");
    }
}
