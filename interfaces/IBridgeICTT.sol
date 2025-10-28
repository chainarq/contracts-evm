// (c) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// SPDX-License-Identifier: Ecosystem

pragma solidity 0.8.25;

/**
 * @notice Input parameters for transferring tokens to another chain as part of a simple transfer.
 * @param destinationBlockchainID Blockchain ID of the destination
 * @param destinationTokenTransferrerAddress Address of the destination token transferrer instance
 * @param recipient Address of the recipient on the destination chain
 * @param primaryFeeTokenAddress Address of the ERC20 contract to optionally pay a Teleporter message fee
 * @param primaryFee Amount of tokens to pay as the optional Teleporter message fee
 * @param secondaryFee Amount of tokens to pay for Teleporter fee if a multi-hop is needed
 * @param requiredGasLimit Gas limit requirement for sending to a token transferrer.
 * This is required because the gas requirement varies based on the token transferrer instance
 * specified by {destinationBlockchainID} and {destinationTokenTransferrerAddress}.
 * @param multiHopFallback In the case of a multi-hop transfer, the address where the tokens
 * are sent on the home chain if the transfer is unable to be routed to its final destination.
 * Note that this address must be able to receive the tokens held as collateral in the home contract.
 */
struct SendTokensInput {
    bytes32 destinationBlockchainID;
    address destinationTokenTransferrerAddress;
    address recipient;
    address primaryFeeTokenAddress;
    uint256 primaryFee;
    uint256 secondaryFee;
    uint256 requiredGasLimit;
    address multiHopFallback;
}

/**
 * @notice Input parameters for transferring tokens to another chain as part of a transfer with a contract call.
 * @param destinationBlockchainID BlockchainID of the destination
 * @param destinationTokenTransferrerAddress Address of the destination token transferrer instance
 * @param recipientContract The contract on the destination chain that will be called
 * @param recipientPayload The payload that will be provided to the recipient contract on the destination chain
 * @param requiredGasLimit The required amount of gas needed to deliver the message on its destination chain,
 * including token operations and the call to the recipient contract.
 * @param recipientGasLimit The amount of gas that will provided to the recipient contract on the destination chain,
 * which must be less than the requiredGasLimit of the message as a whole.
 * @param multiHopFallback In the case of a multi-hop transfer, the address where the tokens
 * are sent on the home chain if the transfer is unable to be routed to its final destination.
 * Note that this address must be able to receive the tokens held as collateral in the home contract.
 * @param fallbackRecipient Address on the {destinationBlockchainID} where the transferred tokens are sent to if the call
 * to the recipient contract fails. Note that this address must be able to receive the tokens on the destination
 * chain of the transfer.
 * @param primaryFeeTokenAddress Address of the ERC20 contract to optionally pay a Teleporter message fee
 * @param primaryFee Amount of tokens to pay for Teleporter fee on the chain that iniiated the transfer
 * @param secondaryFee Amount of tokens to pay for Teleporter fee if a multi-hop is needed
 */
struct SendAndCallInput {
    bytes32 destinationBlockchainID;
    address destinationTokenTransferrerAddress;
    address recipientContract;
    bytes recipientPayload;
    uint256 requiredGasLimit;
    uint256 recipientGasLimit;
    address multiHopFallback;
    address fallbackRecipient;
    address primaryFeeTokenAddress;
    uint256 primaryFee;
    uint256 secondaryFee;
}


interface IBridgeICTT {
    /**
    * @notice Sends native tokens to the specified destination.
     * @param input Specifies information for delivery of the tokens
     */
    function send(SendTokensInput calldata input) external payable;

    /**
 * @notice Sends ERC20 tokens to the specified destination.
     * @param input Specifies information for delivery of the tokens
     * @param amount Amount of tokens to send
     */
    function send(SendTokensInput calldata input, uint256 amount) external;

    /**
     * @notice Sends ERC20 tokens to the specified destination to be used in a smart contract interaction.
     * @param input Specifies information for delivery of the tokens
     * @param amount Amount of tokens to send
     */
    function sendAndCall(SendAndCallInput calldata input, uint256 amount) external;

    /**
 * @notice Sends native tokens to the specified destination to be used in a smart contract interaction.
     * @param input Specifies information for delivery of the tokens to the remote contract and contract to be called
     * on the remote chain.
     */
    function sendAndCall(SendAndCallInput calldata input) external payable;

}
