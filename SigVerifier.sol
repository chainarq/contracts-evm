// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";


/**
 * @title Allows owner to set signer, and verifies signatures
 * @author Padoriku
 */
contract SigVerifier is OwnableUpgradeable {
    using ECDSA for bytes32;

    address public signer;

    event SignerUpdated(address from, address to);

    function initSigVerifier(address _signer) internal onlyInitializing {
        _setSigner(_signer);
    }

    function setSigner(address _signer) public onlyOwner {
        _setSigner(_signer);
    }

    function _setSigner(address _signer) private {
        address oldSigner = signer;
        signer = _signer;
        emit SignerUpdated(oldSigner, _signer);
    }

    function verifySig(bytes32 _hash, bytes memory _feeSig) internal view {
        address _signer = _hash.recover(_feeSig);
        require(_signer == signer, "invalid signer");
    }
}
