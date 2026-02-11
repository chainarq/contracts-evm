// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;


import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../interfaces/IERC20U.sol";

import "../interfaces/IBridgeAdapter.sol";
import "../interfaces/IBridgeStargate.sol";

import "../lib/NativeWrap.sol";

contract StargateV2Adapter is Initializable, IBridgeAdapter, NativeWrap {
    using SafeERC20Upgradeable for IERC20U;

    struct StargateV2Params {
        uint64 nonce;
        uint32 dstEid;
        uint256 minReceivedAmt; // defines the slippage, the min qty you would accept on the destination
        address router; // the target router, should be in the <ref>supportedRouters</ref>
    }

    mapping(address => bool) public supportedRouters;
    mapping(bytes32 => bool) public transfers;

    address public terminus;

    modifier onlyTerminus() {
        require(_msgSender() == address(terminus), "only terminus");
        _;
    }

    function initialize(address _nativeWrap, address[] memory _routers) external initializer {
        __Context_init();
        __Ownable_init();
        initNativeWrap(_nativeWrap);
        for (uint256 i = 0; i < _routers.length; i++) {
            require(_routers[i] != address(0), "nop");
            supportedRouters[_routers[i]] = true;
        }
    }

    function bridge(uint64 _dstChainId, address _receiver, uint256 _amount, address _token, bytes memory _bridgeParams, bytes memory _bridgePayload) onlyTerminus
    external payable returns (bytes memory bridgeResp){
        StargateV2Params memory params = abi.decode((_bridgeParams), (StargateV2Params));
        require(supportedRouters[params.router], "illegal router");

        bytes32 transferId = keccak256(
            abi.encodePacked(_receiver, _token, _amount, _dstChainId, params.nonce, uint64(block.chainid))
        );

        require(transfers[transferId] == false, "transfer exists");

        transfers[transferId] = true;

        _safeTransferFrom(_token, _msgSender(), address(this), _amount);

        _swap(_token, _receiver, _amount, params, _bridgePayload);
    }

    function _swap(address _token, address _receiver, uint256 _amount, StargateV2Params memory params, bytes memory _payload) internal {
        address _router = params.router;

        IERC20U(_token).forceApprove(address(_router), _amount);

        //struct SendParam {
        //    uint32 dstEid; // Destination endpoint ID.
        //    bytes32 to; // Recipient address.
        //    uint256 amountLD; // Amount to send in local decimals.
        //    uint256 minAmountLD; // Minimum amount to send in local decimals.
        //    bytes extraOptions; // Additional options supplied by the caller to be used in the LayerZero message.
        //    bytes composeMsg; // The composed message for the send() operation.
        //    bytes oftCmd; // The OFT command to be executed, unused in default OFT implementations.
        //}

        if (_token == nativeWrap) {
            withdrawNative(_amount);
        }

        (uint _valueToSend, SendParam memory _sendParam, MessagingFee memory _messagingFee) = prepareTakeTaxi(_router, params.dstEid, _amount, _receiver);

        IStargate(_router).sendToken{value: _valueToSend}(_sendParam, _messagingFee, _receiver);

        IERC20U(_token).safeApprove(address(_router), 0);

    }

    function prepareTakeTaxi(address _stargate, uint32 _dstEid, uint256 _amount, address _receiver)
    public view returns (uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee) {
        sendParam = SendParam({
            dstEid: _dstEid,
            to: addressToBytes32(_receiver),
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: new bytes(0),
            composeMsg: new bytes(0),
            oftCmd: ""
        });

        IStargate stargate = IStargate(_stargate);

        (, , OFTReceipt memory receipt) = stargate.quoteOFT(sendParam);
        sendParam.minAmountLD = receipt.amountReceivedLD;

        messagingFee = stargate.quoteSend(sendParam, false);
        valueToSend = messagingFee.nativeFee;

        if (stargate.token() == address(0x0)) {
            valueToSend += sendParam.amountLD;
        }
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

    function setTerminus(address _addr) external onlyOwner {
        terminus = _addr;
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "StargateV2Adapter: TRANSFER_FROM_FAILED");
    }

    uint256[50] private __gap;

}
