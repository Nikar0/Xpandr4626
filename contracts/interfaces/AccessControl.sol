// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

/**
@notice Based on solmate's Owned.sol with added access control for an operator & error code + if instead of requires.
 */

 error NoAuth();
 error NotStrategist();

abstract contract AccessControl {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed user, address indexed newOwner);
    event SetStrategist(address indexed user, address indexed newStrategist);

    /*//////////////////////////////////////////////////////////////
                            OWNERSHIP STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public strategist;
    address public constant treasury = address(0xE37058057B0751bD2653fdeB27e8218439e0f726);
    address public constant devMultiSig = address(0x3522f55fE566420f14f89bd46820EC66D3A5eb7c);

    modifier onlyOwner() virtual {
        checkOwner();
        _;
    }

    modifier onlyAdmin() virtual {
        checkAdmin();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        owner = devMultiSig;
        emit OwnershipTransferred(address(0), owner);
    }

    /*//////////////////////////////////////////////////////////////
                             OWNERSHIP LOGIC
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external virtual onlyOwner {
        owner = newOwner;
        emit OwnershipTransferred(msg.sender, newOwner);
    }

    function setStrategist(address _newStrategist) external virtual {
        if(msg.sender != strategist){revert NotStrategist();}
        strategist = _newStrategist;
        emit SetStrategist(msg.sender, strategist);
    }

    function checkOwner() internal virtual {
        if(tx.origin != owner){revert NoAuth();}
    }

    function checkAdmin() internal virtual {
        if(tx.origin != owner && tx.origin != strategist){revert NoAuth();}
    }

}
