// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IMailbox} from "../interfaces/IMailbox.sol";
import {IPostDispatchHook} from "../interfaces/hooks/IPostDispatchHook.sol";
import {HLMessage} from "./HLMessage.sol";

import {IInterchainSecurityModule, ISpecifiesInterchainSecurityModule} from "../interfaces/IInterchainSecurityModule.sol";
import {MultiCallable} from "./MultiCallable.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import "./TypeCasts.sol";

abstract contract MailboxClient is MultiCallable, ReentrancyGuardUpgradeable, ISpecifiesInterchainSecurityModule {
    using HLMessage for bytes;
    using Strings for uint256;
    using Strings for uint32;
    using Strings for address;
    using Strings for bytes;
    using TypeCasts for bytes32;

    IMailbox public mailbox;

    uint32 public localDomain;

    IInterchainSecurityModule public interchainSecurityModule;

    IPostDispatchHook public hook;

    uint256[48] private __GAP; // gap for upgrade safety

    // ============ Modifiers ============
    modifier onlyContract(address _contract) {
        require(Address.isContract(_contract), "TRMb: invalid mailbox");
        _;
    }

    modifier onlyContractOrNull(address _contract) {
        require(Address.isContract(_contract) || _contract == address(0), "TRMb: invalid contract setting");
        _;
    }

    modifier onlySelf(){
        require(_msgSender() == address(this), "TRMb: only self");
        _;
    }

    /**
     * @notice Only accept messages from an Hyperlane Mailbox contract
     */
    modifier onlyMailbox() {
        require(_msgSender() == address(mailbox), "TRMb: sender not mailbox");
        _;
    }

    /**
     * @notice Sets the address of the application's custom hook.
     * @param _hook The address of the hook contract.
     */
    function setHook(address _hook) public onlyContractOrNull(_hook) onlyOwnerMulticall {
        hook = IPostDispatchHook(_hook);
    }

    /**
     * @notice Sets the address of the application's custom interchain security module.
     * @param _module The address of the interchain security module contract.
     */
    function setInterchainSecurityModule(address _module) public onlyContractOrNull(_module) onlyOwnerMulticall {
        interchainSecurityModule = IInterchainSecurityModule(_module);
    }

    // ======== Initializer =========
    function _MailboxClient_initialize(address _hook, address _interchainSecurityModule, address _owner) internal onlyInitializing {
        __ReentrancyGuard_init();
        __Ownable_init();
        setHook(_hook);
        setInterchainSecurityModule(_interchainSecurityModule);
        _transferOwnership(_owner);
    }

    function _isLatestDispatched(bytes32 id) internal view returns (bool) {
        return mailbox.latestDispatchedId() == id;
    }

    function _metadata(uint32 /*_destinationDomain*/) internal view virtual returns (bytes memory) {
        return "";
    }

    function _dispatch(uint32 _destinationDomain, bytes32 _recipient, bytes memory _messageBody) internal virtual returns (bytes32) {
        return _dispatch(_destinationDomain, _recipient, msg.value, _messageBody);
    }

    function _dispatch(uint32 _destinationDomain, bytes32 _recipient, uint256 _value, bytes memory _messageBody) internal virtual returns (bytes32) {
        return mailbox.dispatch{value: _value}(_destinationDomain, _recipient, _messageBody, _metadata(_destinationDomain), hook);
    }

    function _quoteDispatch(uint32 _destinationDomain, bytes32 _recipient, bytes memory _messageBody) internal view virtual returns (uint256) {
        return mailbox.quoteDispatch(_destinationDomain, _recipient, _messageBody, _metadata(_destinationDomain), hook);
    }

    function setMailbox(address _mb) external onlyContract(_mb) onlyOwnerMulticall {
        mailbox = IMailbox(_mb);
        localDomain = mailbox.localDomain();
    }
}
