// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IBatcher.sol";
import "../../interfaces/IVault.sol";
import "../ConvexExecutor/interfaces/ICurvePool.sol";
import "../ConvexExecutor/interfaces/ICurveDepositZapper.sol";

import "./EIP712.sol";

/// @title Batcher
/// @author 0xAd1
/// @notice Used to batch user deposits and withdrawals until the next rebalance
contract Batcher is IBatcher, EIP712, ReentrancyGuard {
  using SafeERC20 for IERC20;

  /*///////////////////////////////////////////////////////////////
                                CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @notice minimum amount of tokens to be processed
  uint256 constant DUST_LIMIT = 10000;



  /// @notice Hauler parameters for the batcher
  VaultInfo public vaultInfo;

  /// @notice Creates a new Batcher strictly linked to a vault
  /// @param _verificationAuthority Address of the verification authority which allows users to deposit
  /// @param _governance Address of governance for Batcher
  /// @param haulerAddress Address of the hauler which will be used to deposit and withdraw want tokens
  /// @param maxAmount Maximum amount of tokens that can be deposited in the vault
  constructor(address _verificationAuthority, address _governance, address haulerAddress, uint256 maxAmount) {
    verificationAuthority = _verificationAuthority;
    governance = _governance;
  
    require (haulerAddress != address(0), 'Invalid hauler address');
    vaultInfo = VaultInfo({
      vaultAddress: haulerAddress,
      tokenAddress: IVault(haulerAddress).wantToken(),
      maxAmount: maxAmount,
      currentAmount: 0
    });

    IERC20(vaultInfo.tokenAddress).approve(haulerAddress, type(uint256).max);
  }




  /*///////////////////////////////////////////////////////////////
                       USER DEPOSIT/WITHDRAWAL LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @notice Ledger to maintain addresses and their amounts to be deposited into hauler
  mapping(address => uint256) public depositLedger;

  /// @notice Ledger to maintain addresses and their amounts to be withdrawn from hauler
  mapping(address => uint256) public withdrawLedger;

  /// @notice Address which authorises users to deposit into Batcher
  address public verificationAuthority;

  /**
   * @notice Stores the deposits for future batching via periphery
   * @param amountIn Value of token to be deposited
   * @param signature signature verifying that depositor has enough karma and is authorized to deposit by brahma
   */
  function depositFunds(
    uint256 amountIn,
    bytes memory signature
  ) external override nonReentrant {
    validDeposit(signature);
    IERC20(vaultInfo.tokenAddress).safeTransferFrom(
      msg.sender,
      address(this),
      amountIn
    );

    vaultInfo.currentAmount += amountIn;
    require(
      vaultInfo.currentAmount <= vaultInfo.maxAmount,
      "Exceeded deposit limit"
    );

    _completeDeposit(amountIn);
  }

  /**
   * @notice Stores the deposits for future batching via periphery
   * @param amountIn Value of Lp token to be deposited
   * @param signature signature verifying that depositor has enough karma and is authorized to deposit by brahma
   */
  function depositFundsInCurveLpToken(
    uint256 amountIn,
    bytes memory signature
  ) external override nonReentrant {
    validDeposit(signature);
    /// Curve Lp Token - UST_Wormhole
    IERC20 lpToken = IERC20(0xCEAF7747579696A2F0bb206a14210e3c9e6fB269);

    lpToken.safeTransferFrom(msg.sender, address(this), amountIn);

    uint256 usdcReceived = _convertLpTokenIntoUSDC(lpToken);

    _completeDeposit(usdcReceived);
  }


  /**
   * @notice Stores the deposits for future batching via periphery
   * @param amountIn Value of token to be deposited
   */
  function withdrawFunds(uint256 amountIn)
    external
    override
    nonReentrant
  {

    require(
      depositLedger[msg.sender] == 0,
      "Cannot withdraw funds from hauler while waiting to deposit"
    );


    if (amountIn > userTokens[msg.sender]) {
      IERC20(vaultInfo.vaultAddress).safeTransferFrom(msg.sender, address(this), amountIn - userTokens[msg.sender]);
      userTokens[msg.sender] = 0;
    } else {
      userTokens[msg.sender] = userTokens[msg.sender] - amountIn;
    }
    
    

    withdrawLedger[msg.sender] =
      withdrawLedger[msg.sender] +
      (amountIn);

    vaultInfo.currentAmount -= amountIn;

    emit WithdrawRequest(msg.sender, vaultInfo.vaultAddress, amountIn);
  }



  /**
   * @notice Allows user to withdraw LP tokens
   * @param amount Amount of LP tokens to withdraw
   * @param recipient Address to receive the LP tokens
   */
  function claimTokens(uint256 amount, address recipient) public override nonReentrant{
    require(userTokens[msg.sender] >= amount, "No funds available");
    userTokens[msg.sender] = userTokens[msg.sender] - amount;
    IERC20(vaultInfo.vaultAddress).safeTransfer(recipient, amount);
  }



  /*///////////////////////////////////////////////////////////////
                    VAULT DEPOSIT/WITHDRAWAL LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @notice Ledger to maintain addresses and hauler tokens which batcher owes them
  mapping(address => uint256) public userTokens;

  /// @notice Priavte mapping used to check duplicate addresses while processing batch deposits and withdrawals
  mapping(address => bool) private processedAddresses;

  /**
   * @notice Performs deposits on the periphery for the supplied users in batch
   * @param users array of users whose deposits must be resolved
   */
  function batchDeposit(address[] memory users)
    external
    override
    nonReentrant
  {
    onlyKeeper();
    IVault hauler = IVault(vaultInfo.vaultAddress);

    uint256 amountToDeposit = 0;
    uint256 oldLPBalance = IERC20(address(hauler)).balanceOf(address(this));

    for (uint256 i = 0; i < users.length; i++) {
      if (!processedAddresses[users[i]]) {
        amountToDeposit =
          amountToDeposit +
          (depositLedger[users[i]]);
        processedAddresses[users[i]] = true;
      }
    }

    require(amountToDeposit > 0, "no deposits to make");

    uint256 lpTokensReportedByHauler = hauler.deposit(
      amountToDeposit,
      address(this)
    );

    uint256 lpTokensReceived = IERC20(address(hauler)).balanceOf(
      address(this)
    ) - (oldLPBalance);

    require(
      lpTokensReceived == lpTokensReportedByHauler,
      "LP tokens received by hauler does not match"
    );

    for (uint256 i = 0; i < users.length; i++) {
      uint256 userAmount = depositLedger[users[i]];
      if (processedAddresses[users[i]]) {
        if (userAmount > 0) {
          uint256 userShare = (userAmount * (lpTokensReceived)) /
            (amountToDeposit);
          userTokens[users[i]] = userTokens[users[i]] + userShare;
          depositLedger[users[i]] = 0;
        }
        processedAddresses[users[i]] = false;
      }
    }
  }


  /**
   * @notice Performs withdraws on the periphery for the supplied users in batch
   * @param users array of users whose deposits must be resolved
   */
  function batchWithdraw(address[] memory users)
    external
    override
    nonReentrant
  {
    onlyKeeper();
    IVault hauler = IVault(vaultInfo.vaultAddress);

    IERC20 token = IERC20(vaultInfo.tokenAddress);

    uint256 amountToWithdraw = 0;
    uint256 oldWantBalance = token.balanceOf(address(this));

    for (uint256 i = 0; i < users.length; i++) {
      if (!processedAddresses[users[i]]) {
        amountToWithdraw =
          amountToWithdraw +
          (withdrawLedger[users[i]]);
        processedAddresses[users[i]] = true;
      }
    }

    require(amountToWithdraw > 0, "no deposits to make");

    uint256 wantTokensReportedByHauler = hauler.withdraw(
      amountToWithdraw,
      address(this)
    );

    uint256 wantTokensReceived = token.balanceOf(address(this)) -
      (oldWantBalance);

    require(
      wantTokensReceived == wantTokensReportedByHauler,
      "Want tokens received by hauler does not match"
    );

    for (uint256 i = 0; i < users.length; i++) {
      uint256 userAmount = withdrawLedger[users[i]];
      if (processedAddresses[users[i]]) {
        if (userAmount > 0) {
          uint256 userShare = (userAmount * wantTokensReceived) /
            amountToWithdraw;
          token.safeTransfer(users[i], userShare);

          withdrawLedger[users[i]] = 0;
        }
        processedAddresses[users[i]] = false;
      }
    }
  }



  /*///////////////////////////////////////////////////////////////
                    INTERNAL HELPERS
  //////////////////////////////////////////////////////////////*/

  /// @notice Helper to verify signature against verification authority
  /// @param signature Should be generated by verificationAuthority. Should contain msg.sender 
  function validDeposit(bytes memory signature) internal view {
    require(
      verifySignatureAgainstAuthority(signature, verificationAuthority),
      "Signature is not valid"
    );

    require(
      withdrawLedger[msg.sender] == 0,
      "Cannot deposit funds to hauler while waiting to withdraw"
    );
  }

  /// @notice Common internal helper to process deposit requests from both wantTokena and CurveLPToken
  /// @param amountIn Amount of want tokens deposited
  function _completeDeposit(uint256 amountIn) internal {
    depositLedger[msg.sender] =
      depositLedger[msg.sender] +
      (amountIn);

    emit DepositRequest(msg.sender, vaultInfo.vaultAddress, amountIn);
  }

  /// @notice Can be changed by keeper
  uint256 public slippageForCurveLp = 30;

  /// @notice Helper to convert Lp tokens into USDC
  /// @dev Burns LpTokens on UST3-Wormhole pool on curve to get USDC
  /// @param lpToken Curve Lp Token
  function _convertLpTokenIntoUSDC(IERC20 lpToken)
    internal
    returns (uint256 receivedWantTokens)
  {
    uint256 MAX_BPS = 10000;

    ICurvePool ust3Pool = ICurvePool(
      0xCEAF7747579696A2F0bb206a14210e3c9e6fB269
    );
    ICurveDepositZapper curve3PoolZap = ICurveDepositZapper(
      0xA79828DF1850E8a3A3064576f380D90aECDD3359
    );

    uint256 _amount = lpToken.balanceOf(address(this));

    lpToken.safeApprove(address(curve3PoolZap), _amount);

    int128 usdcIndexInPool = int128(int256(uint256(2)));

    // estimate amount of USDC received on burning Lp tokens
    uint256 expectedWantTokensOut = curve3PoolZap.calc_withdraw_one_coin(
      address(ust3Pool),
      _amount,
      usdcIndexInPool
    );
    // burn Lp tokens to receive USDC with a slippage of 0.3%
    receivedWantTokens = curve3PoolZap.remove_liquidity_one_coin(
      address(ust3Pool),
      _amount,
      usdcIndexInPool,
      (expectedWantTokensOut * (MAX_BPS - slippageForCurveLp)) / (MAX_BPS)
    );
  }


  /*///////////////////////////////////////////////////////////////
                    MAINTAINANCE ACTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Function to set authority address
  /// @param authority New authority address
  function setAuthority(address authority) public {
    onlyGovernance();
    verificationAuthority = authority;
  }

  /// @inheritdoc IBatcher
  function setHaulerLimit(uint256 maxAmount) external override {
    onlyKeeper();
    vaultInfo.maxAmount = maxAmount;
  }

  /// @notice Setting slippage for swaps
  /// @param _slippage Must be between 0 and 10000
  function setSlippage(uint256 _slippage) external override {
    onlyKeeper();
    require(_slippage <= 10000, "Slippage must be between 0 and 10000");
    slippageForCurveLp = _slippage;
  }

  /// @notice Function to sweep funds out in case of emergency, can only be called by governance
  /// @param _token Address of token to sweep
  function sweep(address _token) public nonReentrant{
    onlyGovernance();
    IERC20(_token).transfer(
      msg.sender,
      IERC20(_token).balanceOf(address(this))
    );
  }


  /*///////////////////////////////////////////////////////////////
                    ACCESS MODIFERS
  //////////////////////////////////////////////////////////////*/

  /// @notice Governance address
  address public governance;

  /// @notice Pending governance address
  address public pendingGovernance;

  /// @notice Helper to get Keeper address from Hauler contract
  /// @return Keeper address
  function keeper() public view returns (address) {
    require(vaultInfo.vaultAddress != address(0), "Hauler not set");
    return IVault(vaultInfo.vaultAddress).keeper();
  }

  /// @notice Helper to asset msg.sender as keeper address
  function onlyKeeper() internal view {
    require(msg.sender == keeper(), "Only keeper can call this function");
  }

  /// @notice Helper to asset msg.sender as governance address
  function onlyGovernance() internal view{
    require(governance == msg.sender, "Only governance can call this");
  }

  /// @notice Function to change governance. New address will need to accept the governance role
  /// @param _governance Address of new temporary governance
  function setGovernance(address _governance) external {
    onlyGovernance();
    pendingGovernance = _governance;
  }

  /// @notice Function to accept governance role. Only pending governance can accept this role
  function acceptGovernance() external {
    require(
      msg.sender == pendingGovernance,
      "ONLY_PENDING_GOV"
    );
    governance = pendingGovernance;
  }

}
