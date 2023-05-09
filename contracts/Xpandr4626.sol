//SPDX-License-Identifier: MIT

/** 
@title Xpandr4626
@author Nikar0 
@notice Minimal Vault based on EIP 4626

www.github.com/nikar0/Xpandr4626 - www.twitter.com/Nikar0_
**/

pragma solidity 0.8.17;

import {ReentrancyGuard} from "./interfaces/solmate//ReentrancyGuard.sol";
import {ERC20, ERC4626} from "./interfaces/solmate/ERC4626.sol";
import {SafeTransferLib} from "./interfaces/solmate/SafeTransferLib.sol";
import {FixedPointMathLib} from "./interfaces/solmate/FixedPointMathLib.sol";
import {XpandrErrors} from "./interfaces/XpandrErrors.sol";
import {AdminOwned} from "./interfaces/AdminOwned.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";


/**
Implementation of a vault to deposit funds for yield optimizing
This is the contract that receives funds & users interface with
The strategy itself is implemented in a separate Strategy contract
 */
contract Xpandr4626 is ERC4626, AdminOwned, ReentrancyGuard, XpandrErrors {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    //VARIABLES & EVENTS\\
    struct StratCandidate {
        address implementation;
        uint256 proposedTime;
    }

    StratCandidate public stratCandidate;         //The last proposed strategy to switch to.
    IStrategy public strategy;                    //The strategy currently in use by the vault.
    uint256 constant approvalDelay = 43200;       //Delay before a strat can be approved. 12 hours
    uint256 vaultProfit;                          //Sum of the yield earned by strategies attached to the vault. In 'asset' amount.
    mapping(address => uint64) lastUserDeposit;   //Deposit timer to prevent spam w/ 0 withdraw fee
  
    event NewStratQueued(address implementation);
    event SwapStrat(address implementation);
    event InCaseTokensGetStuck(address caller, uint256 amount, address token);

    /**
     Initializes the vault and it's own receipt token
     This token is minted when someone deposits. It's burned in order
     to withdraw the corresponding portion of the underlying assets.
     */
    constructor (ERC20 _asset, IStrategy _strategy)
       ERC4626(
            // Underlying token
            _asset,
            // ex: Rari Dai Stablecoin Vault
            string(abi.encodePacked("Xpandr4626 Vault")),
            // ex: rvDAI
            string(abi.encodePacked("Xp-MPX-FTM"))
        )
    {
        strategy = _strategy;
        totalSupply = type(uint256).max;
    }

    function depositAll() external {
        deposit(asset.balanceOf(msg.sender), msg.sender);
    }

    //Entrypoint of funds into the system. The vault then deposits funds into the strategy.  
     function deposit(uint256 lpAmt, address receiver) public virtual override nonReentrant() returns (uint256 shares) {
        if (lastUserDeposit[msg.sender] == 0) {lastUserDeposit[msg.sender] = uint64(block.timestamp);} 
        if (uint64(block.timestamp - lastUserDeposit[msg.sender]) < 600) {revert UnderTimeLock();}
        if(tx.origin != receiver){revert NotAccountOwner();}
        vaultProfit = vaultProfit + strategy.harvestProfit();
        shares = previewDeposit(lpAmt);
        if(shares == 0){revert ZeroAmount();}

        asset.safeTransferFrom(msg.sender, address(this), lpAmt); // Need to transfer before minting or ERC777s could reenter.
        _earn();
        
        _mint(msg.sender, shares);
        emit Deposit(msg.sender, receiver, lpAmt, shares);

        if(strategy.harvestOnDeposit() == 1) {strategy.afterDeposit();}
    }

    
    //Function to send funds into the strategy and put them to work.
    //It's primarily called by the vault's deposit() function.
    function _earn() internal {
        uint _bal = available();
        asset.safeTransfer(address(strategy), _bal);
        strategy.deposit();
    }

    
    //Helper to call withdraw with all the sender's funds.
    function withdrawAll() external {
        withdraw(asset.balanceOf(msg.sender), msg.sender, msg.sender);
    }

    /**
     Exit the system. The vault will withdraw the required tokens
     from the strategy and semd to the token holder. A proportional number of receipt
     tokens are burned in the process.
     */

    function withdraw(uint256 lpAmt, address receiver, address owner) public virtual override nonReentrant returns (uint256 shares) {
        if(msg.sender != receiver && msg.sender != owner){revert NotAccountOwner();}
        if(lpAmt > asset.balanceOf(msg.sender)){revert OverBalance();}
        shares = previewWithdraw(lpAmt);
        if(lpAmt == 0 || shares == 0){revert ZeroAmount();}
       
        strategy.withdraw(lpAmt);
        _burn(owner, shares);

        asset.safeTransfer(receiver, lpAmt);

        emit Withdraw(msg.sender, receiver, owner, lpAmt, shares);
    }

    /** 
     * @dev Sets the candidate for the new strat to use with this vault.
     * @param _implementation The address of the candidate strategy.  
     */
    function queueStrat(address _implementation) public onlyAdmin {
        if(address(this) != IStrategy(_implementation).vault()){revert InvalidProposal();}
        stratCandidate = StratCandidate({
            implementation: _implementation,
            proposedTime: uint64(block.timestamp)
         });

        emit NewStratQueued(_implementation);
    }

    /** 
     * @dev It switches the active strat for the strat candidate. After upgrading, the 
     * candidate implementation is set to the 0x00 address, and proposedTime to a time 
     * happening in +100 years for safety. 
     */

    function swapStrat() public onlyAdmin {
        if(stratCandidate.implementation == address(0)){revert ZeroAddress();}
        if(stratCandidate.proposedTime + approvalDelay > uint64(block.timestamp)){revert UnderTimeLock();}

        emit SwapStrat(stratCandidate.implementation);
        strategy.retireStrat();
        strategy = IStrategy(stratCandidate.implementation);
        stratCandidate.implementation = address(0);
        stratCandidate.proposedTime = 5000000000;

        _earn();
    }

    
    //Rescues random funds stuck that the strat can't handle.
    function inCaseTokensGetStuck(address _token) external onlyAdmin {
        if(ERC20(_token) == asset){revert InvalidTokenOrPath();}

        uint256 amount = ERC20(_token).balanceOf(address(this));
        ERC20(_token).safeTransfer(msg.sender, amount);

        emit InCaseTokensGetStuck(msg.sender, amount, _token);
    }

    /**@dev VIEWS **/
    function want() public view returns (ERC20) {
        return asset;
    }

    //Returns idle funds in the vault
    function available() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    //Function for various UIs to display the current value of one of our yield tokens.
    //Returns uint256 with 18 decimals of how much underlying asset one vault share represents.
    function getPricePerFullShare() public view returns (uint256) {
        return totalSupply == 0 ? 1e18 : totalAssets() * 1e18 / totalSupply;
    }

    /**
     Calculates total underlying value of want held by the system.
     It takes into account vault contract balance, strategy contract balance
     & balance deployed in other contracts as part of the strategy.
     */
    function totalAssets() public view override returns (uint256) {
        return asset.balanceOf(address(this)) + IStrategy(strategy).balanceOf();
    }

    /**Following functions are included as per EIP-4626 standard but are not meant
    To be used in the context of this vault. As such, they were made uncallable by design.
    This vault does not allow 3rd parties to deposit or withdraw for another Owner.
    */
    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256 assets) {}
    function mint(uint256 shares, address receiver) public virtual override returns (uint256 assets) {}
    function previewMint(uint256 shares) public view virtual override returns (uint256 _mint){}
    function maxRedeem(address owner) public view virtual override returns (uint256 _redeem) {}
}