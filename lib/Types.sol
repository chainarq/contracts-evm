// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.19;


import "./MsgDataTypes.sol";
import "../interfaces/ICodec.sol";

    enum SwapType {
        None,
        Local,
        Direct,
        SwapSrc,
        SwapDst,
        SwapSrcDst
    }

    enum MessageVia {
        Celer,
        LayerZero
    }

library Types {

    struct Source {
        // A number unique enough to be used in request ID generation.
        uint64 nonce;
        // the unix timestamp before which the fee is valid
        uint64 deadline;
        // sig of sha3("executor fee", srcChainId, amountIn, tokenIn, deadline, toChainId, bridgeOutToken, bridgeOutFallbackToken[, toChainId, bridgeOutToken,  bridgeOutFallbackToken]...)
        // see _verifyQuote()
        bytes quoteSig;
        uint256 amountIn;
        address tokenIn;
        bool nativeIn;
    }

    function emptySource() internal pure returns (Source memory) {
        return Source(0, 0, "", 0, address(0), false);
    }

    struct Destination {
        // The receiving party (the user) of the final output token
        // note that if an organization user's private key is breached, and if their original receiver is a contract
        // address, the hacker could deploy a malicious contract with the same address on the different chain and hence
        // get access to the user's pocket funds on that chain.
        // WARNING users should make sure their own deployer key's safety or that the receiver is
        // 1. not a reproducable address on any of the chains that chainarq supports
        // 2. a contract that they already deployed on all the chains that chainarq supports
        // 3. an EOA
        address receiver;
        bool nativeOut;
        address custodian;
    }

    struct Execution {
        ICodec.Swap[] swaps;
        Bridge bridge;
        address bridgeOutToken;
        // some bridges utilize a intermediary token (e.g. hToken for Hop and anyToken for Multichain)
        // in cases where there isn't enough underlying token liquidity on the dst chain, the user/pocket
        // could receive this token as a fallback. remote Terminus needs to know what this token is
        // in order to check whether a fallback has happened and refund the user.
        address bridgeOutFallbackToken;
        // the minimum that remote Terminus needs to receive in order to allow the swap message
        // to execute. note that this differs from a normal slippages controlling variable and is
        // purely used to deter DoS attacks (detailed in Terminus).
        uint256 bridgeOutMin;
        uint256 bridgeOutFallbackMin;
    }

    struct Bridge {
        uint64 toChainId;
        // bridge provider identifier
        string bridgeProvider;
        // Bridge transfers quoted and abi encoded by chainarq backend server.
        // Bridge adapter implementations need to decode this themselves.
        bytes bridgeParams;
        // the native fee required by the bridge provider
        uint256 nativeFee;
        // the estimated cost of gas incase there is a swap on the destination chain, paid in native in the source chain
        uint256 dstGasCost;
    }

    struct Message {
        bytes32 id;
        Types.Execution[] execs;
        Types.Destination dst;
    }
}
