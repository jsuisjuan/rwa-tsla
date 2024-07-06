// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import { ConfirmedOwner } from '@chainlink/contracts/v0.8/ConfirmedOwner.sol';
import { FunctionsClient } from '@chainlink/contracts/v0.8/functions/dev/v1_0_0/FunctionsClient.sol';
import { FunctionsRequest } from '@chainlink/contracts/v0.8/functions/dev/v1_0_0/libraries/FunctionsRequest.sol';
import { AggregatorV3Interface } from '@chainlink/contracts/v0.8/interfaces/AggregatorV3Interface.sol';

import { ERC20 } from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import { Strings } from '@openzeppelin/contracts/utils/Strings.sol';

contract dTSLA is ConfirmedOwner, FunctionsClient, ERC20 {
    using FunctionsRequest for FunctionsRequest.Request;
    using Strings for uint256;

    error dTSLA__NotEnoughtCollateral();
    error dTSLA__DoesntMeetMinimumWithdrawlAmount();
    error dTSLA__TransferFailed();

    enum MintOrRedeem {
        mint, redeem
    }

    struct dTslaRequest {
        uint256 amountOfToken;
        address requester;
        MintOrRedeem mintOrRedeem;
    }

    uint256 constant PRECISION = 1e18;
    address constant SEPOLIA_FUNCTIONS_ROUTER = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    address constant SEPOLIA_TSLA_PRICE_FEED = 0xc59E3633BAAC79493d908e63626716e204A45EdF; // this is actually LINK/USD for demo purposes
    address constant SEPOLIA_USDC_PRICE_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;
    address constant SEPOLIA_USDC = 0xAF0d217854155ea67D583E4CB5724f7caeC3Dc87;
    bytes32 constant DON_ID = hex'66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000';
    uint256 constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint32  constant GAS_LIMIT = 300_000;
    uint256 constant COLLATERAL_RATIO = 200; // 200% collateral ration means if there is $200 of TSLA in the brokerage, we can mint AT MOST %100 of dTSLA
    uint256 constant COLLATERAL_PRECISION = 100;
    uint256 constant MINIMUM_WITHDRAWL_AMOUNT = 100e18; // USDC has 6 decimals

    uint64  immutable i_subId;
    string  private s_mintSourceCode;
    string  private s_redeemSourceCode;
    uint256 private s_portfolioBalance;

    mapping(bytes32 requestId => dTslaRequest request) private s_requestIdToRequest;
    mapping(address user => uint256 pendingWithdrawlAmount) private s_userToWithdrawlAmount;

    constructor(
        string memory mintSourceCode, 
        string memory redeemSourceCode,
        uint64 subId
    ) 
        ConfirmedOwner(msg.sender) 
        FunctionsClient(SEPOLIA_FUNCTIONS_ROUTER)
        ERC20('dTSLA', 'dTSLA') 
    {
        s_mintSourceCode = mintSourceCode;
        s_redeemSourceCode = redeemSourceCode;
        i_subId = subId;
    }

    // Send an HTTP request to:
    // 1. See how much TSLA is brought
    // 2. If enough TSLA is in the alpaca account, mint dTSLA
    function sendMintRequest(uint256 amount) external onlyOwner returns (bytes32) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_mintSourceCode);
        bytes32 requestId = _sendRequest(req.encodeCBOR(), i_subId, GAS_LIMIT, DON_ID);
        s_requestIdToRequest[requestId] = dTslaRequest(amount, msg.sender, MintOrRedeem.mint);
        return requestId;
    }

    // Return the amount of TSLA value (in USD) is stored in our broker
    // If we have enough TSLA token, mint the dTSLA
    function _mintFulFillRequest(bytes32 requestId, bytes memory response) internal {
        uint256 amountOfTokensToMint = s_requestIdToRequest[requestId].amountOfToken;
        s_portfolioBalance = uint256(bytes32(response));

        // if TSLA collateral (how much TSLA we have bought) > dTSLA to mint -> mint
        // How much TSLA in $$$ do we have?
        // How much TSLA in $$$ are we minting?
        if (_getCollateralRatioAdjustedTotalBalance(amountOfTokensToMint) > s_portfolioBalance) {
            revert dTSLA__NotEnoughtCollateral();
        }

        if (amountOfTokensToMint != 0) {
            _mint(s_requestIdToRequest[requestId].requester, amountOfTokensToMint);
        }
    }

    /// @notice User sends a request to sell TSLA for USDC (redemptionToken)
    /// this will, have the chainlink function call our alpaca (bank) and do the following
    /// 1. Sell TSLA on the brokerage
    /// 2. Buy USDC on the brokerage
    /// 3. Send USDC to this contract for the user to withdraw
    function sendRedeemRequest(uint256 amountdTsla) external {
        uint256 amountTslaInUsdc = getUsdcValueOfUsd(getUsdcValueOfTsla(amountdTsla));
        if (amountTslaInUsdc < MINIMUM_WITHDRAWL_AMOUNT) {
            revert dTSLA__DoesntMeetMinimumWithdrawlAmount();
        }
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s_redeemSourceCode);

        string[] memory args = new string[](2);
        args[0] = amountdTsla.toString();
        args[1] = amountTslaInUsdc.toString();
        req.setArgs(args);

        bytes32 requestId = _sendRequest(req.encodeCBOR(), i_subId, GAS_LIMIT, DON_ID);
        s_requestIdToRequest[requestId] = dTslaRequest(amountdTsla, msg.sender, MintOrRedeem.redeem);

        _burn(msg.sender, amountdTsla);
    }

    function _redeemFulFillRequest(bytes32 requestId, bytes memory response) internal {
        // assume for now this has 18 decimals
        uint256 usdcAmount = uint256(bytes32(response));
        if (usdcAmount == 0) {
            uint256 amountOfdTSLABurned = s_requestIdToRequest[requestId].amountOfToken;
            _mint(s_requestIdToRequest[requestId].requester, amountOfdTSLABurned);
            return;
        }
        s_userToWithdrawlAmount[s_requestIdToRequest[requestId].requester] += usdcAmount;
    }

    function withdraw() external {
        uint256 amountToWithdraw = s_userToWithdrawlAmount[msg.sender];
        s_userToWithdrawlAmount[msg.sender] = 0;
        bool succ = ERC20(0xAF0d217854155ea67D583E4CB5724f7caeC3Dc87).transfer(msg.sender, amountToWithdraw);
        if (!succ) {
            revert dTSLA__TransferFailed();
        }
    }

    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory /*err*/) internal override {
        s_requestIdToRequest[requestId].mintOrRedeem == MintOrRedeem.mint ? _mintFulFillRequest(requestId, response) : _redeemFulFillRequest(requestId, response);
    }

    function _getCollateralRatioAdjustedTotalBalance(uint256 amountOfTokensToMint) internal view returns (uint256) {
        uint256 calculatedNewTotalValue = getCalculatedNewTotalValue(amountOfTokensToMint);
        return (calculatedNewTotalValue * COLLATERAL_RATIO) / COLLATERAL_PRECISION;
    }

    // The new expected total value in USD of all the dTSLA tokens combined
    function getCalculatedNewTotalValue(uint256 addedNumberOfTokens) internal view returns (uint256) {
        // 10 dtsla tokens + 5 dtsla tokens = 15 dtsla tokens * tsla price (100) = 1500
        return ((totalSupply() + addedNumberOfTokens) * getTslaPrice()) / PRECISION;
    }

    function getUsdcValueOfUsd(uint256 usdAmount) public view returns (uint256) {
        return (usdAmount * getUsdcPrice()) / PRECISION;
    }

    function getUsdcValueOfTsla(uint256 usdAmount) public view returns (uint256) {
        return (usdAmount * getTslaPrice()) / PRECISION;
    }

    function getTslaPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(SEPOLIA_TSLA_PRICE_FEED);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price) * ADDITIONAL_FEED_PRECISION; // so that we have 18 decimals
    }

    function getUsdcPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(SEPOLIA_USDC_PRICE_FEED);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price) * ADDITIONAL_FEED_PRECISION;
    }


    function getRequest(bytes32 requestId) public view returns (dTslaRequest memory) {
        return s_requestIdToRequest[requestId];
    }

    function getPendingWithdrawlAmount(address user) public view returns (uint256) {
        return s_userToWithdrawlAmount[user];
    }

    function getPortfolioBalance() public view returns (uint256) {
        return i_subId;
    }

    function getMintSourceCode() public view returns (string memory) {
        return s_mintSourceCode;
    }

    function getRedeemSourceCode() public view returns (string memory) {
        return s_redeemSourceCode;
    }

    function getCollateralRatio() public pure returns (uint256) {
        return COLLATERAL_RATIO;
    }

    function getCollateralPrecision() public pure returns (uint256) {
        return COLLATERAL_PRECISION;
    }
}

// parei no 1:00:47

// 1:00:58 talvez vc terá que criar um contrato para popular
// SEPOLIA_USDC