//SPDX-License-Identifier: ISC
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "./IOptionMarket.sol";

interface IOptionMarketViewer {
    struct TradePremiumView {
        uint256 listingId;
        uint256 premium;
        uint256 basePrice;
        uint256 vegaUtilFee;
        uint256 optionPriceFee;
        uint256 spotPriceFee;
        uint256 newIv;
    }

    function getPremiumForOpen(
        uint256 _listingId,
        IOptionMarket.TradeType tradeType,
        uint256 amount
    ) external view returns (TradePremiumView memory);

    function getPremiumForClose(
        uint256 _listingId,
        IOptionMarket.TradeType tradeType,
        uint256 amount
    ) external view returns (TradePremiumView memory);
}