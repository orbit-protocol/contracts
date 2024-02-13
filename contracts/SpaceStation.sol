// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./OToken.sol";
import "./ErrorReporter.sol";
import "./PriceOracle.sol";
import "./Core/ComptrollerInterface.sol";
import "./Core/ComptrollerStorage.sol";
import "./SpaceStationUpgradable.sol";
import "./Governance/Orbit.sol";

/**
 * @title Orbit's Space Station
 * @author Orbit
 */
contract OrbitSpaceStation is
    ComptrollerV7Storage,
    ComptrollerInterface,
    ComptrollerErrorReporter,
    ExponentialNoError
{
    /// @notice Emitted when an admin supports a market
    event MarketListed(OToken oToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(OToken oToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(OToken oToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(
        uint oldCloseFactorMantissa,
        uint newCloseFactorMantissa
    );

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(
        OToken oToken,
        uint oldCollateralFactorMantissa,
        uint newCollateralFactorMantissa
    );

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(
        uint oldLiquidationIncentiveMantissa,
        uint newLiquidationIncentiveMantissa
    );

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(
        PriceOracle oldPriceOracle,
        PriceOracle newPriceOracle
    );

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(OToken oToken, string action, bool pauseState);

    /// @notice Emitted when a new borrow-side COMP speed is calculated for a market
    event CompBorrowSpeedUpdated(OToken indexed oToken, uint newSpeed);

    /// @notice Emitted when a new supply-side COMP speed is calculated for a market
    event CompSupplySpeedUpdated(OToken indexed oToken, uint newSpeed);

    /// @notice Emitted when a new COMP speed is set for a contributor
    event ContributorCompSpeedUpdated(
        address indexed contributor,
        uint newSpeed
    );

    /// @notice Emitted when COMP is distributed to a supplier
    event DistributedSupplierComp(
        OToken indexed oToken,
        address indexed supplier,
        uint compDelta,
        uint compSupplyIndex
    );

    /// @notice Emitted when COMP is distributed to a borrower
    event DistributedBorrowerComp(
        OToken indexed oToken,
        address indexed borrower,
        uint compDelta,
        uint compBorrowIndex
    );

    /// @notice Emitted when borrow cap for a oToken is changed
    event NewBorrowCap(OToken indexed oToken, uint newBorrowCap);

    /// @notice Emitted when borrow cap guardian is changed
    event NewBorrowCapGuardian(
        address oldBorrowCapGuardian,
        address newBorrowCapGuardian
    );

    /// @notice Emitted when COMP is granted by admin
    event CompGranted(address recipient, uint amount);

    /// @notice Emitted when COMP accrued for a user has been manually adjusted.
    event CompAccruedAdjusted(
        address indexed user,
        uint oldCompAccrued,
        uint newCompAccrued
    );

    /// @notice Emitted when COMP receivable for a user has been updated.
    event CompReceivableUpdated(
        address indexed user,
        uint oldCompReceivable,
        uint newCompReceivable
    );

    /// @notice The initial COMP index for a market
    uint224 public constant compInitialIndex = 1e36;

    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    constructor() {
        admin = msg.sender;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(
        address account
    ) external view returns (OToken[] memory) {
        OToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param oToken The oToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(
        address account,
        OToken oToken
    ) external view returns (bool) {
        return markets[address(oToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param oTokens The list of addresses of the oToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(
        address[] memory oTokens
    ) public override returns (uint[] memory) {
        uint len = oTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            OToken oToken = OToken(oTokens[i]);

            results[i] = uint(addToMarketInternal(oToken, msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param oToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(
        OToken oToken,
        address borrower
    ) internal returns (Error) {
        Market storage marketToJoin = markets[address(oToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(oToken);

        emit MarketEntered(oToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param oTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(
        address oTokenAddress
    ) external override returns (uint) {
        OToken oToken = OToken(oTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the oToken */
        (uint oErr, uint tokensHeld, uint amountOwed, ) = oToken
            .getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return
                fail(
                    Error.NONZERO_BORROW_BALANCE,
                    FailureInfo.EXIT_MARKET_BALANCE_OWED
                );
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint allowed = redeemAllowedInternal(
            oTokenAddress,
            msg.sender,
            tokensHeld
        );
        if (allowed != 0) {
            return
                failOpaque(
                    Error.REJECTION,
                    FailureInfo.EXIT_MARKET_REJECTION,
                    allowed
                );
        }

        Market storage marketToExit = markets[address(oToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        /* Set oToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete oToken from the account’s list of assets */
        // load into memory for faster iteration
        OToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == oToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        OToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(oToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param oToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(
        address oToken,
        address minter,
        uint mintAmount
    ) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[oToken], "mint is paused");

        // Shh - currently unused
        minter;
        mintAmount;

        if (!markets[oToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        updateCompSupplyIndex(oToken);
        distributeSupplierComp(oToken, minter);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param oToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(
        address oToken,
        address minter,
        uint actualMintAmount,
        uint mintTokens
    ) external override {
        // Shh - currently unused
        oToken;
        minter;
        actualMintAmount;
        mintTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param oToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of oTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(
        address oToken,
        address redeemer,
        uint redeemTokens
    ) external override returns (uint) {
        uint allowed = redeemAllowedInternal(oToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateCompSupplyIndex(oToken);
        distributeSupplierComp(oToken, redeemer);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(
        address oToken,
        address redeemer,
        uint redeemTokens
    ) internal view returns (uint) {
        if (!markets[oToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[oToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(
            redeemer,
            OToken(oToken),
            redeemTokens,
            0
        );
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param oToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(
        address oToken,
        address redeemer,
        uint redeemAmount,
        uint redeemTokens
    ) external override {
        // Shh - currently unused
        oToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param oToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(
        address oToken,
        address borrower,
        uint borrowAmount
    ) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[oToken], "borrow is paused");

        if (!markets[oToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[oToken].accountMembership[borrower]) {
            // only oTokens may call borrowAllowed if borrower not in market
            require(msg.sender == oToken, "sender must be oToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(OToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // it should be impossible to break the important invariant
            assert(markets[oToken].accountMembership[borrower]);
        }

        if (oracle.getUnderlyingPrice(OToken(oToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }

        uint borrowCap = borrowCaps[oToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint totalBorrows = OToken(oToken).totalBorrows();
            uint nextTotalBorrows = add_(totalBorrows, borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(
            borrower,
            OToken(oToken),
            0,
            borrowAmount
        );
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: OToken(oToken).borrowIndex()});
        updateCompBorrowIndex(oToken, borrowIndex);
        distributeBorrowerComp(oToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param oToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(
        address oToken,
        address borrower,
        uint borrowAmount
    ) external override {
        // Shh - currently unused
        oToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param oToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address oToken,
        address payer,
        address borrower,
        uint repayAmount
    ) external override returns (uint) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[oToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: OToken(oToken).borrowIndex()});
        updateCompBorrowIndex(oToken, borrowIndex);
        distributeBorrowerComp(oToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param oToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address oToken,
        address payer,
        address borrower,
        uint actualRepayAmount,
        uint borrowerIndex
    ) external override {
        // Shh - currently unused
        oToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param oTokenBorrowed Asset which was borrowed by the borrower
     * @param oTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address oTokenBorrowed,
        address oTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount
    ) external override returns (uint) {
        // Shh - currently unused
        liquidator;

        if (
            !markets[oTokenBorrowed].isListed ||
            !markets[oTokenCollateral].isListed
        ) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        uint borrowBalance = OToken(oTokenBorrowed).borrowBalanceStored(
            borrower
        );

        /* allow accounts to be liquidated if the market is deprecated */
        if (isDeprecated(OToken(oTokenBorrowed))) {
            require(
                borrowBalance >= repayAmount,
                "Can not repay more than the total borrow"
            );
        } else {
            /* The borrower must have shortfall in order to be liquidatable */
            (Error err, , uint shortfall) = getAccountLiquidityInternal(
                borrower
            );
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            if (shortfall == 0) {
                return uint(Error.INSUFFICIENT_SHORTFALL);
            }

            /* The liquidator may not repay more than what is allowed by the closeFactor */
            uint maxClose = mul_ScalarTruncate(
                Exp({mantissa: closeFactorMantissa}),
                borrowBalance
            );
            if (repayAmount > maxClose) {
                return uint(Error.TOO_MUCH_REPAY);
            }
        }
        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param oTokenBorrowed Asset which was borrowed by the borrower
     * @param oTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address oTokenBorrowed,
        address oTokenCollateral,
        address liquidator,
        address borrower,
        uint actualRepayAmount,
        uint seizeTokens
    ) external override {
        // Shh - currently unused
        oTokenBorrowed;
        oTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param oTokenCollateral Asset which was used as collateral and will be seized
     * @param oTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address oTokenCollateral,
        address oTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");

        // Shh - currently unused
        seizeTokens;

        if (
            !markets[oTokenCollateral].isListed ||
            !markets[oTokenBorrowed].isListed
        ) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (
            OToken(oTokenCollateral).comptroller() !=
            OToken(oTokenBorrowed).comptroller()
        ) {
            return uint(Error.COMPTROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updateCompSupplyIndex(oTokenCollateral);
        distributeSupplierComp(oTokenCollateral, borrower);
        distributeSupplierComp(oTokenCollateral, liquidator);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param oTokenCollateral Asset which was used as collateral and will be seized
     * @param oTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address oTokenCollateral,
        address oTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external override {
        // Shh - currently unused
        oTokenCollateral;
        oTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param oToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of oTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(
        address oToken,
        address src,
        address dst,
        uint transferTokens
    ) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(oToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateCompSupplyIndex(oToken);
        distributeSupplierComp(oToken, src);
        distributeSupplierComp(oToken, dst);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param oToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of oTokens to transfer
     */
    function transferVerify(
        address oToken,
        address src,
        address dst,
        uint transferTokens
    ) external override {
        // Shh - currently unused
        oToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `oTokenBalance` is the number of oTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint oTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(
        address account
    ) public view returns (uint, uint, uint) {
        (
            Error err,
            uint liquidity,
            uint shortfall
        ) = getHypotheticalAccountLiquidityInternal(
                account,
                OToken(address(0)),
                0,
                0
            );

        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code,
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityInternal(
        address account
    ) internal view returns (Error, uint, uint) {
        return
            getHypotheticalAccountLiquidityInternal(
                account,
                OToken(address(0)),
                0,
                0
            );
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param oTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address oTokenModify,
        uint redeemTokens,
        uint borrowAmount
    ) public view returns (uint, uint, uint) {
        (
            Error err,
            uint liquidity,
            uint shortfall
        ) = getHypotheticalAccountLiquidityInternal(
                account,
                OToken(oTokenModify),
                redeemTokens,
                borrowAmount
            );
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param oTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral oToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        OToken oTokenModify,
        uint redeemTokens,
        uint borrowAmount
    ) internal view returns (Error, uint, uint) {
        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;

        // For each asset the account is in
        OToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            OToken asset = assets[i];

            // Read the balances and exchange rate from the oToken
            (
                oErr,
                vars.oTokenBalance,
                vars.borrowBalance,
                vars.exchangeRateMantissa
            ) = asset.getAccountSnapshot(account);
            if (oErr != 0) {
                // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({
                mantissa: markets[address(asset)].collateralFactorMantissa
            });
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> ether (normalized price value)
            vars.tokensToDenom = mul_(
                mul_(vars.collateralFactor, vars.exchangeRate),
                vars.oraclePrice
            );

            // sumCollateral += tokensToDenom * oTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(
                vars.tokensToDenom,
                vars.oTokenBalance,
                vars.sumCollateral
            );

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                vars.oraclePrice,
                vars.borrowBalance,
                vars.sumBorrowPlusEffects
            );

            // Calculate effects of interacting with oTokenModify
            if (asset == oTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                    vars.tokensToDenom,
                    redeemTokens,
                    vars.sumBorrowPlusEffects
                );

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                    vars.oraclePrice,
                    borrowAmount,
                    vars.sumBorrowPlusEffects
                );
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (
                Error.NO_ERROR,
                vars.sumCollateral - vars.sumBorrowPlusEffects,
                0
            );
        } else {
            return (
                Error.NO_ERROR,
                0,
                vars.sumBorrowPlusEffects - vars.sumCollateral
            );
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in oToken.liquidateBorrowFresh)
     * @param oTokenBorrowed The address of the borrowed oToken
     * @param oTokenCollateral The address of the collateral oToken
     * @param actualRepayAmount The amount of oTokenBorrowed underlying to convert into oTokenCollateral tokens
     * @return (errorCode, number of oTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(
        address oTokenBorrowed,
        address oTokenCollateral,
        uint actualRepayAmount
    ) external view override returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(
            OToken(oTokenBorrowed)
        );
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(
            OToken(oTokenCollateral)
        );
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = OToken(oTokenCollateral)
            .exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(
            Exp({mantissa: liquidationIncentiveMantissa}),
            Exp({mantissa: priceBorrowedMantissa})
        );
        denominator = mul_(
            Exp({mantissa: priceCollateralMantissa}),
            Exp({mantissa: exchangeRateMantissa})
        );
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
     * @notice Sets a new price oracle for the comptroller
     * @dev Admin function to set a new price oracle
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK
                );
        }

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sets the closeFactor used when liquidating borrows
     * @dev Admin function to set closeFactor
     * @param newCloseFactorMantissa New close factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure
     */
    function _setCloseFactor(
        uint newCloseFactorMantissa
    ) external returns (uint) {
        // Check caller is admin
        require(msg.sender == admin, "only admin can set close factor");

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sets the collateralFactor for a market
     * @dev Admin function to set per-market collateralFactor
     * @param oToken The market to set the factor on
     * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setCollateralFactor(
        OToken oToken,
        uint newCollateralFactorMantissa
    ) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK
                );
        }

        // Verify market is listed
        Market storage market = markets[address(oToken)];
        if (!market.isListed) {
            return
                fail(
                    Error.MARKET_NOT_LISTED,
                    FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS
                );
        }

        Exp memory newCollateralFactorExp = Exp({
            mantissa: newCollateralFactorMantissa
        });

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return
                fail(
                    Error.INVALID_COLLATERAL_FACTOR,
                    FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION
                );
        }

        // If collateral factor != 0, fail if price == 0
        if (
            newCollateralFactorMantissa != 0 &&
            oracle.getUnderlyingPrice(oToken) == 0
        ) {
            return
                fail(
                    Error.PRICE_ERROR,
                    FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE
                );
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(
            oToken,
            oldCollateralFactorMantissa,
            newCollateralFactorMantissa
        );

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sets liquidationIncentive
     * @dev Admin function to set liquidationIncentive
     * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setLiquidationIncentive(
        uint newLiquidationIncentiveMantissa
    ) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK
                );
        }

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(
            oldLiquidationIncentiveMantissa,
            newLiquidationIncentiveMantissa
        );

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Add the market to the markets mapping and set it as listed
     * @dev Admin function to set isListed and add support for the market
     * @param oToken The address of the market (token) to list
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _supportMarket(OToken oToken) external returns (uint) {
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SUPPORT_MARKET_OWNER_CHECK
                );
        }

        if (markets[address(oToken)].isListed) {
            return
                fail(
                    Error.MARKET_ALREADY_LISTED,
                    FailureInfo.SUPPORT_MARKET_EXISTS
                );
        }

        oToken.isCToken(); // Sanity check to make sure its really a OToken

        // Note that isComped is not in active use anymore
        Market storage newMarket = markets[address(oToken)];
        newMarket.isListed = true;
        newMarket.isComped = false;
        newMarket.collateralFactorMantissa = 0;

        _addMarketInternal(address(oToken));
        _initializeMarket(address(oToken));

        emit MarketListed(oToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(address oToken) internal {
        for (uint i = 0; i < allMarkets.length; i++) {
            require(allMarkets[i] != OToken(oToken), "market already added");
        }
        allMarkets.push(OToken(oToken));
    }

    function _initializeMarket(address oToken) internal {
        uint32 blockNumber = safe32(
            getBlockNumber(),
            "block number exceeds 32 bits"
        );

        CompMarketState storage supplyState = compSupplyState[oToken];
        CompMarketState storage borrowState = compBorrowState[oToken];

        /*
         * Update market state indices
         */
        if (supplyState.index == 0) {
            // Initialize supply state index with default value
            supplyState.index = compInitialIndex;
        }

        if (borrowState.index == 0) {
            // Initialize borrow state index with default value
            borrowState.index = compInitialIndex;
        }

        /*
         * Update market state block numbers
         */
        supplyState.block = borrowState.block = blockNumber;
    }

    /**
     * @notice Set the given borrow caps for the given oToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
     * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
     * @param oTokens The addresses of the markets (tokens) to change the borrow caps for
     * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
     */
    function _setMarketBorrowCaps(
        OToken[] calldata oTokens,
        uint[] calldata newBorrowCaps
    ) external {
        require(
            msg.sender == admin || msg.sender == borrowCapGuardian,
            "only admin or borrow cap guardian can set borrow caps"
        );

        uint numMarkets = oTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(
            numMarkets != 0 && numMarkets == numBorrowCaps,
            "invalid input"
        );

        for (uint i = 0; i < numMarkets; i++) {
            borrowCaps[address(oTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(oTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Admin function to change the Borrow Cap Guardian
     * @param newBorrowCapGuardian The address of the new Borrow Cap Guardian
     */
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external {
        require(msg.sender == admin, "only admin can set borrow cap guardian");

        // Save current value for inclusion in log
        address oldBorrowCapGuardian = borrowCapGuardian;

        // Store borrowCapGuardian with value newBorrowCapGuardian
        borrowCapGuardian = newBorrowCapGuardian;

        // Emit NewBorrowCapGuardian(OldBorrowCapGuardian, NewBorrowCapGuardian)
        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) public returns (uint) {
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK
                );
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint(Error.NO_ERROR);
    }

    function _setMintPaused(OToken oToken, bool state) public returns (bool) {
        require(
            markets[address(oToken)].isListed,
            "cannot pause a market that is not listed"
        );
        require(
            msg.sender == pauseGuardian || msg.sender == admin,
            "only pause guardian and admin can pause"
        );
        require(msg.sender == admin || state == true, "only admin can unpause");

        mintGuardianPaused[address(oToken)] = state;
        emit ActionPaused(oToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(OToken oToken, bool state) public returns (bool) {
        require(
            markets[address(oToken)].isListed,
            "cannot pause a market that is not listed"
        );
        require(
            msg.sender == pauseGuardian || msg.sender == admin,
            "only pause guardian and admin can pause"
        );
        require(msg.sender == admin || state == true, "only admin can unpause");

        borrowGuardianPaused[address(oToken)] = state;
        emit ActionPaused(oToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        require(
            msg.sender == pauseGuardian || msg.sender == admin,
            "only pause guardian and admin can pause"
        );
        require(msg.sender == admin || state == true, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(
            msg.sender == pauseGuardian || msg.sender == admin,
            "only pause guardian and admin can pause"
        );
        require(msg.sender == admin || state == true, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _become(SpaceStationUpgradable unitroller) public {
        require(
            msg.sender == unitroller.admin(),
            "only unitroller admin can change brains"
        );
        require(
            unitroller._acceptImplementation() == 0,
            "change not authorized"
        );
    }

    /// @notice Delete this function after proposal 65 is executed
    function fixBadAccruals(
        address[] calldata affectedUsers,
        uint[] calldata amounts
    ) external {
        require(msg.sender == admin, "Only admin can call this function"); // Only the timelock can call this function
        require(
            !proposal65FixExecuted,
            "Already executed this one-off function"
        ); // Require that this function is only called once
        require(affectedUsers.length == amounts.length, "Invalid input");

        // Loop variables
        address user;
        uint currentAccrual;
        uint amountToSubtract;
        uint newAccrual;

        // Iterate through all affected users
        for (uint i = 0; i < affectedUsers.length; ++i) {
            user = affectedUsers[i];
            currentAccrual = compAccrued[user];

            amountToSubtract = amounts[i];

            // The case where the user has claimed and received an incorrect amount of COMP.
            // The user has less currently accrued than the amount they incorrectly received.
            if (amountToSubtract > currentAccrual) {
                // Amount of COMP the user owes the protocol
                uint accountReceivable = amountToSubtract - currentAccrual; // Underflow safe since amountToSubtract > currentAccrual

                uint oldReceivable = compReceivable[user];
                uint newReceivable = add_(oldReceivable, accountReceivable);

                // Accounting: record the COMP debt for the user
                compReceivable[user] = newReceivable;

                emit CompReceivableUpdated(user, oldReceivable, newReceivable);

                amountToSubtract = currentAccrual;
            }

            if (amountToSubtract > 0) {
                // Subtract the bad accrual amount from what they have accrued.
                // Users will keep whatever they have correctly accrued.
                compAccrued[user] = newAccrual = sub_(
                    currentAccrual,
                    amountToSubtract
                );

                emit CompAccruedAdjusted(user, currentAccrual, newAccrual);
            }
        }

        proposal65FixExecuted = true; // Makes it so that this function cannot be called again
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == comptrollerImplementation;
    }

    /*** Comp Distribution ***/

    /**
     * @notice Set COMP speed for a single market
     * @param oToken The market whose COMP speed to update
     * @param supplySpeed New supply-side COMP speed for market
     * @param borrowSpeed New borrow-side COMP speed for market
     */
    function setCompSpeedInternal(
        OToken oToken,
        uint supplySpeed,
        uint borrowSpeed
    ) internal {
        Market storage market = markets[address(oToken)];
        require(market.isListed, "comp market is not listed");

        if (compSupplySpeeds[address(oToken)] != supplySpeed) {
            // Supply speed updated so let's update supply state to ensure that
            //  1. COMP accrued properly for the old speed, and
            //  2. COMP accrued at the new speed starts after this block.
            updateCompSupplyIndex(address(oToken));

            // Update speed and emit event
            compSupplySpeeds[address(oToken)] = supplySpeed;
            emit CompSupplySpeedUpdated(oToken, supplySpeed);
        }

        if (compBorrowSpeeds[address(oToken)] != borrowSpeed) {
            // Borrow speed updated so let's update borrow state to ensure that
            //  1. COMP accrued properly for the old speed, and
            //  2. COMP accrued at the new speed starts after this block.
            Exp memory borrowIndex = Exp({mantissa: oToken.borrowIndex()});
            updateCompBorrowIndex(address(oToken), borrowIndex);

            // Update speed and emit event
            compBorrowSpeeds[address(oToken)] = borrowSpeed;
            emit CompBorrowSpeedUpdated(oToken, borrowSpeed);
        }
    }

    /**
     * @notice Accrue COMP to the market by updating the supply index
     * @param oToken The market whose supply index to update
     * @dev Index is a cumulative sum of the COMP per oToken accrued.
     */
    function updateCompSupplyIndex(address oToken) internal {
        CompMarketState storage supplyState = compSupplyState[oToken];
        uint supplySpeed = compSupplySpeeds[oToken];
        uint32 blockNumber = safe32(
            getBlockNumber(),
            "block number exceeds 32 bits"
        );
        uint deltaBlocks = sub_(uint(blockNumber), uint(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint supplyTokens = OToken(oToken).totalSupply();
            uint compAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0
                ? fraction(compAccrued, supplyTokens)
                : Double({mantissa: 0});
            supplyState.index = safe224(
                add_(Double({mantissa: supplyState.index}), ratio).mantissa,
                "new index exceeds 224 bits"
            );
            supplyState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            supplyState.block = blockNumber;
        }
    }

    /**
     * @notice Accrue COMP to the market by updating the borrow index
     * @param oToken The market whose borrow index to update
     * @dev Index is a cumulative sum of the COMP per oToken accrued.
     */
    function updateCompBorrowIndex(
        address oToken,
        Exp memory marketBorrowIndex
    ) internal {
        CompMarketState storage borrowState = compBorrowState[oToken];
        uint borrowSpeed = compBorrowSpeeds[oToken];
        uint32 blockNumber = safe32(
            getBlockNumber(),
            "block number exceeds 32 bits"
        );
        uint deltaBlocks = sub_(uint(blockNumber), uint(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(
                OToken(oToken).totalBorrows(),
                marketBorrowIndex
            );
            uint compAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0
                ? fraction(compAccrued, borrowAmount)
                : Double({mantissa: 0});
            borrowState.index = safe224(
                add_(Double({mantissa: borrowState.index}), ratio).mantissa,
                "new index exceeds 224 bits"
            );
            borrowState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            borrowState.block = blockNumber;
        }
    }

    /**
     * @notice Calculate COMP accrued by a supplier and possibly transfer it to them
     * @param oToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute COMP to
     */
    function distributeSupplierComp(address oToken, address supplier) internal {
        // TODO: Don't distribute supplier COMP if the user is not in the supplier market.
        // This check should be as gas efficient as possible as distributeSupplierComp is called in many places.
        // - We really don't want to call an external contract as that's quite expensive.

        CompMarketState storage supplyState = compSupplyState[oToken];
        uint supplyIndex = supplyState.index;
        uint supplierIndex = compSupplierIndex[oToken][supplier];

        // Update supplier's index to the current index since we are distributing accrued COMP
        compSupplierIndex[oToken][supplier] = supplyIndex;

        if (supplierIndex == 0 && supplyIndex >= compInitialIndex) {
            // Covers the case where users supplied tokens before the market's supply state index was set.
            // Rewards the user with COMP accrued from the start of when supplier rewards were first
            // set for the market.
            supplierIndex = compInitialIndex;
        }

        // Calculate change in the cumulative sum of the COMP per oToken accrued
        Double memory deltaIndex = Double({
            mantissa: sub_(supplyIndex, supplierIndex)
        });

        uint supplierTokens = OToken(oToken).balanceOf(supplier);

        // Calculate COMP accrued: oTokenAmount * accruedPerOToken
        uint supplierDelta = mul_(supplierTokens, deltaIndex);

        uint supplierAccrued = add_(compAccrued[supplier], supplierDelta);
        compAccrued[supplier] = supplierAccrued;

        emit DistributedSupplierComp(
            OToken(oToken),
            supplier,
            supplierDelta,
            supplyIndex
        );
    }

    /**
     * @notice Calculate COMP accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param oToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute COMP to
     */
    function distributeBorrowerComp(
        address oToken,
        address borrower,
        Exp memory marketBorrowIndex
    ) internal {
        // TODO: Don't distribute supplier COMP if the user is not in the borrower market.
        // This check should be as gas efficient as possible as distributeBorrowerComp is called in many places.
        // - We really don't want to call an external contract as that's quite expensive.

        CompMarketState storage borrowState = compBorrowState[oToken];
        uint borrowIndex = borrowState.index;
        uint borrowerIndex = compBorrowerIndex[oToken][borrower];

        // Update borrowers's index to the current index since we are distributing accrued COMP
        compBorrowerIndex[oToken][borrower] = borrowIndex;

        if (borrowerIndex == 0 && borrowIndex >= compInitialIndex) {
            // Covers the case where users borrowed tokens before the market's borrow state index was set.
            // Rewards the user with COMP accrued from the start of when borrower rewards were first
            // set for the market.
            borrowerIndex = compInitialIndex;
        }

        // Calculate change in the cumulative sum of the COMP per borrowed unit accrued
        Double memory deltaIndex = Double({
            mantissa: sub_(borrowIndex, borrowerIndex)
        });

        uint borrowerAmount = div_(
            OToken(oToken).borrowBalanceStored(borrower),
            marketBorrowIndex
        );

        // Calculate COMP accrued: oTokenAmount * accruedPerBorrowedUnit
        uint borrowerDelta = mul_(borrowerAmount, deltaIndex);

        uint borrowerAccrued = add_(compAccrued[borrower], borrowerDelta);
        compAccrued[borrower] = borrowerAccrued;

        emit DistributedBorrowerComp(
            OToken(oToken),
            borrower,
            borrowerDelta,
            borrowIndex
        );
    }

    /**
     * @notice Calculate additional accrued COMP for a contributor since last accrual
     * @param contributor The address to calculate contributor rewards for
     */
    function updateContributorRewards(address contributor) public {
        uint compSpeed = compContributorSpeeds[contributor];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, lastContributorBlock[contributor]);
        if (deltaBlocks > 0 && compSpeed > 0) {
            uint newAccrued = mul_(deltaBlocks, compSpeed);
            uint contributorAccrued = add_(
                compAccrued[contributor],
                newAccrued
            );

            compAccrued[contributor] = contributorAccrued;
            lastContributorBlock[contributor] = blockNumber;
        }
    }

    /**
     * @notice Claim all the incentive tokens accrued by holder in all markets
     * @param holder The address to claim tokens for
     */
    function claimComp(address holder) public {
        return claimComp(holder, allMarkets);
    }

    /**
     * @notice Claim all the comp accrued by holder in the specified markets
     * @param holder The address to claim tokens for
     * @param oTokens The list of markets to claim tokens in
     */
    function claimComp(address holder, OToken[] memory oTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimComp(holders, oTokens, true, true);
    }

    /**
     * @notice Claim all comp accrued by the holders
     * @param holders The addresses to claim tokens for
     * @param oTokens The list of markets to claim tokens in
     * @param borrowers Whether or not to claim tokens earned by borrowing
     * @param suppliers Whether or not to claim tokens earned by supplying
     */
    function claimComp(
        address[] memory holders,
        OToken[] memory oTokens,
        bool borrowers,
        bool suppliers
    ) public {
        for (uint i = 0; i < oTokens.length; i++) {
            OToken oToken = oTokens[i];
            require(markets[address(oToken)].isListed, "market must be listed");
            if (borrowers == true) {
                Exp memory borrowIndex = Exp({mantissa: oToken.borrowIndex()});
                updateCompBorrowIndex(address(oToken), borrowIndex);
                for (uint j = 0; j < holders.length; j++) {
                    distributeBorrowerComp(
                        address(oToken),
                        holders[j],
                        borrowIndex
                    );
                }
            }
            if (suppliers == true) {
                updateCompSupplyIndex(address(oToken));
                for (uint j = 0; j < holders.length; j++) {
                    distributeSupplierComp(address(oToken), holders[j]);
                }
            }
        }
        for (uint j = 0; j < holders.length; j++) {
            compAccrued[holders[j]] = grantCompInternal(
                holders[j],
                compAccrued[holders[j]]
            );
        }
    }

    /**
     * @notice Transfer tokens to the user
     * @dev Note: If there is not enough tokens, we do not perform the transfer all.
     * @param user The address of the user to transfer tokens to
     * @param amount The amount of tokens to (possibly) transfer
     * @return The amount of tokens which was NOT transferred to the user
     */
    function grantCompInternal(
        address user,
        uint amount
    ) internal returns (uint) {
        OrbitToken comp = OrbitToken(getCompAddress());
        uint compRemaining = comp.balanceOf(address(this));
        if (amount > 0 && amount <= compRemaining) {
            comp.transfer(user, amount);
            return 0;
        }
        return amount;
    }

    /*** Distribution Admin ***/

    /**
     * @notice Transfer tokens to the recipient
     * @dev Note: If there is not enough tokens, we do not perform the transfer all.
     * @param recipient The address of the recipient to transfer tokens to
     * @param amount The amount of tokens to (possibly) transfer
     */
    function _grantComp(address recipient, uint amount) public {
        require(adminOrInitializing(), "only admin can grant comp");
        uint amountLeft = grantCompInternal(recipient, amount);
        require(amountLeft == 0, "insufficient comp for grant");
        emit CompGranted(recipient, amount);
    }

    /**
     * @notice Set tokens borrow and supply speeds for the specified markets.
     * @param oTokens The markets whose tokens speed to update.
     * @param supplySpeeds New supply-side tokens speed for the corresponding market.
     * @param borrowSpeeds New borrow-side tokens speed for the corresponding market.
     */
    function _setCompSpeeds(
        OToken[] memory oTokens,
        uint[] memory supplySpeeds,
        uint[] memory borrowSpeeds
    ) public {
        require(adminOrInitializing(), "only admin can set tokens speed");

        uint numTokens = oTokens.length;
        require(
            numTokens == supplySpeeds.length &&
                numTokens == borrowSpeeds.length,
            "Comptroller::_setCompSpeeds invalid input"
        );

        for (uint i = 0; i < numTokens; ++i) {
            setCompSpeedInternal(oTokens[i], supplySpeeds[i], borrowSpeeds[i]);
        }
    }

    /**
     * @notice Set tokens speed for a single contributor
     * @param contributor The contributor whose tokens speed to update
     * @param compSpeed New tokens speed for contributor
     */
    function _setContributorCompSpeed(
        address contributor,
        uint compSpeed
    ) public {
        require(adminOrInitializing(), "only admin can set comp speed");

        // note that tokens speed could be set to 0 to halt liquidity rewards for a contributor
        updateContributorRewards(contributor);
        if (compSpeed == 0) {
            // release storage
            delete lastContributorBlock[contributor];
        } else {
            lastContributorBlock[contributor] = getBlockNumber();
        }
        compContributorSpeeds[contributor] = compSpeed;

        emit ContributorCompSpeedUpdated(contributor, compSpeed);
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (OToken[] memory) {
        return allMarkets;
    }

    /**
     * @notice Returns true if the given oToken market has been deprecated
     * @dev All borrows in a deprecated oToken market can be immediately liquidated
     * @param oToken The market to check if deprecated
     */
    function isDeprecated(OToken oToken) public view returns (bool) {
        return
            markets[address(oToken)].collateralFactorMantissa == 0 &&
            borrowGuardianPaused[address(oToken)] == true &&
            oToken.reserveFactorMantissa() == 1e18;
    }

    function getBlockNumber() public view virtual returns (uint) {
        return block.number;
    }

    /**
     * @notice Return the address of the tokens token
     * @return The address of tokens
     */
    function getCompAddress() public view virtual returns (address) {
        return 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    }
}
