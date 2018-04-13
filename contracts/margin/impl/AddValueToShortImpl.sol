pragma solidity 0.4.21;
pragma experimental "v0.5.0";

import { AddressUtils } from "zeppelin-solidity/contracts/AddressUtils.sol";
import { SafeMath } from "zeppelin-solidity/contracts/math/SafeMath.sol";
import { MarginCommon } from "./MarginCommon.sol";
import { MarginState } from "./MarginState.sol";
import { ShortShared } from "./ShortShared.sol";
import { Vault } from "../Vault.sol";
import { MathHelpers } from "../../lib/MathHelpers.sol";
import { ExchangeWrapper } from "../interfaces/ExchangeWrapper.sol";
import { LoanOwner } from "../interfaces/LoanOwner.sol";
import { ShortOwner } from "../interfaces/ShortOwner.sol";


/**
 * @title AddValueToShortImpl
 * @author dYdX
 *
 * This library contains the implementation for the addValueToShort function of Margin
 */
library AddValueToShortImpl {
    using SafeMath for uint256;

    // ------------------------
    // -------- Events --------
    // ------------------------

    /*
     * Value was added to a short sell
     */
    event ValueAddedToShort(
        bytes32 indexed marginId,
        address indexed shortSeller,
        address indexed lender,
        address shortOwner,
        address loanOwner,
        bytes32 loanHash,
        address loanFeeRecipient,
        uint256 amountBorrowed,
        uint256 effectiveAmountAdded,
        uint256 quoteTokenFromSell,
        uint256 depositAmount
    );

    // -------------------------------------------
    // ----- Public Implementation Functions -----
    // -------------------------------------------

    function addValueToShortImpl(
        MarginState.State storage state,
        bytes32 marginId,
        address[7] addresses,
        uint256[8] values256,
        uint32[2] values32,
        uint8 sigV,
        bytes32[2] sigRS,
        bool depositInQuoteToken,
        bytes orderData
    )
        public
        returns (uint256)
    {
        MarginCommon.Short storage short = MarginCommon.getShortObject(state, marginId);

        ShortShared.ShortTx memory transaction = parseAddValueToShortTx(
            short,
            addresses,
            values256,
            values32,
            sigV,
            sigRS,
            depositInQuoteToken
        );

        uint256 quoteTokenFromSell = preStateUpdate(
            state,
            transaction,
            short,
            marginId,
            orderData
        );

        updateState(
            short,
            marginId,
            transaction.effectiveAmount,
            transaction.loanOffering.payer
        );

        // Update global amounts for the loan
        state.loanFills[transaction.loanOffering.loanHash] =
            state.loanFills[transaction.loanOffering.loanHash].add(transaction.effectiveAmount);

        ShortShared.shortInternalPostStateUpdate(
            state,
            transaction,
            marginId
        );

        // LOG EVENT
        recordValueAddedToShort(
            transaction,
            marginId,
            short,
            quoteTokenFromSell
        );

        return transaction.lenderAmount;
    }

    function addValueToShortDirectlyImpl(
        MarginState.State storage state,
        bytes32 marginId,
        uint256 amount
    )
        public
        returns (uint256)
    {
        MarginCommon.Short storage short = MarginCommon.getShortObject(state, marginId);

        uint256 quoteTokenAmount = getPositionMinimumQuoteToken(
            marginId,
            state,
            amount,
            short
        );

        Vault(state.VAULT).transferToVault(
            marginId,
            short.quoteToken,
            msg.sender,
            quoteTokenAmount
        );

        updateState(
            short,
            marginId,
            amount,
            msg.sender
        );

        emit ValueAddedToShort(
            marginId,
            msg.sender,
            msg.sender,
            short.seller,
            short.lender,
            "",
            address(0),
            0,
            amount,
            0,
            quoteTokenAmount
        );

        return quoteTokenAmount;
    }

    // --------- Helper Functions ---------

    function preStateUpdate(
        MarginState.State storage state,
        ShortShared.ShortTx transaction,
        MarginCommon.Short storage short,
        bytes32 marginId,
        bytes orderData
    )
        internal
        returns (uint256 /* quoteTokenFromSell */)
    {
        validate(transaction, short);
        uint256 positionMinimumQuoteToken = setDepositAmount(
            state,
            transaction,
            short,
            marginId,
            orderData
        );

        uint256 quoteTokenFromSell;
        uint256 totalQuoteTokenReceived;

        (quoteTokenFromSell, totalQuoteTokenReceived) = ShortShared.shortInternalPreStateUpdate(
            state,
            transaction,
            marginId,
            orderData
        );

        // This should always be true unless there is a faulty ExchangeWrapper (i.e. the
        // ExchangeWrapper traded at a different price from what it said it would)
        assert(positionMinimumQuoteToken == totalQuoteTokenReceived);

        return quoteTokenFromSell;
    }

    function validate(
        ShortShared.ShortTx transaction,
        MarginCommon.Short storage short
    )
        internal
        view
    {
        require(short.callTimeLimit <= transaction.loanOffering.callTimeLimit);

        // require the short to end no later than the loanOffering's maximum acceptable end time
        uint256 shortEndTimestamp = uint256(short.startTimestamp).add(short.maxDuration);
        uint256 offeringEndTimestamp = block.timestamp.add(transaction.loanOffering.maxDuration);
        require(shortEndTimestamp <= offeringEndTimestamp);

        // Do not allow value to be added after the max duration
        require(block.timestamp < shortEndTimestamp);
    }

    function setDepositAmount(
        MarginState.State storage state,
        ShortShared.ShortTx transaction,
        MarginCommon.Short storage short,
        bytes32 marginId,
        bytes orderData
    )
        internal
        view // Does modify transaction
        returns (uint256 /* positionMinimumQuoteToken */)
    {
        // Amount of quote token we need to add to the position to maintain the position's ratio
        // of quote token to base token
        uint256 positionMinimumQuoteToken = getPositionMinimumQuoteToken(
            marginId,
            state,
            transaction.effectiveAmount,
            short
        );

        if (transaction.depositInQuoteToken) {
            uint256 quoteTokenFromSell = ExchangeWrapper(transaction.exchangeWrapper)
                .getTradeMakerTokenAmount(
                    transaction.quoteToken,
                    transaction.baseToken,
                    transaction.lenderAmount,
                    orderData
                );

            require(quoteTokenFromSell <= positionMinimumQuoteToken);
            transaction.depositAmount = positionMinimumQuoteToken.sub(quoteTokenFromSell);
        } else {
            uint256 baseTokenToSell = ExchangeWrapper(transaction.exchangeWrapper)
                .getTakerTokenPrice(
                    transaction.quoteToken,
                    transaction.baseToken,
                    positionMinimumQuoteToken,
                    orderData
                );

            require(transaction.lenderAmount <= baseTokenToSell);
            transaction.depositAmount = baseTokenToSell.sub(transaction.lenderAmount);
        }

        return positionMinimumQuoteToken;
    }

    function getPositionMinimumQuoteToken(
        bytes32 marginId,
        MarginState.State storage state,
        uint256 effectiveAmount,
        MarginCommon.Short storage short
    )
        internal
        view
        returns (uint256)
    {
        uint256 quoteTokenBalance = Vault(state.VAULT).balances(marginId, short.quoteToken);

        return MathHelpers.getPartialAmountRoundedUp(
            effectiveAmount,
            short.shortAmount,
            quoteTokenBalance
        );
    }

    function updateState(
        MarginCommon.Short storage short,
        bytes32 marginId,
        uint256 effectiveAmount,
        address loanPayer
    )
        internal
    {
        short.shortAmount = short.shortAmount.add(effectiveAmount);

        address seller = short.seller;
        address lender = short.lender;

        // Unless msg.sender is the position short seller and is not a smart contract, call out
        // to the short seller to ensure they consent to value being added
        if (msg.sender != seller || AddressUtils.isContract(seller)) {
            require(
                ShortOwner(seller).additionalShortValueAdded(
                    msg.sender,
                    marginId,
                    effectiveAmount
                )
            );
        }

        // Unless the loan offering's lender is the owner of the loan position and is not a smart
        // contract, call out to the owner of the loan position to ensure they consent
        // to value being added
        if (loanPayer != lender || AddressUtils.isContract(lender)) {
            require(
                LoanOwner(lender).additionalLoanValueAdded(
                    loanPayer,
                    marginId,
                    effectiveAmount
                )
            );
        }
    }

    function recordValueAddedToShort(
        ShortShared.ShortTx transaction,
        bytes32 marginId,
        MarginCommon.Short storage short,
        uint256 quoteTokenFromSell
    )
        internal
    {
        emit ValueAddedToShort(
            marginId,
            msg.sender,
            transaction.loanOffering.payer,
            short.seller,
            short.lender,
            transaction.loanOffering.loanHash,
            transaction.loanOffering.feeRecipient,
            transaction.lenderAmount,
            transaction.effectiveAmount,
            quoteTokenFromSell,
            transaction.depositAmount
        );
    }

    // -------- Parsing Functions -------

    function parseAddValueToShortTx(
        MarginCommon.Short storage short,
        address[7] addresses,
        uint256[8] values256,
        uint32[2] values32,
        uint8 sigV,
        bytes32[2] sigRS,
        bool depositInQuoteToken
    )
        internal
        view
        returns (ShortShared.ShortTx memory)
    {
        ShortShared.ShortTx memory transaction = ShortShared.ShortTx({
            owner: short.seller,
            baseToken: short.baseToken,
            quoteToken: short.quoteToken,
            effectiveAmount: values256[7],
            lenderAmount: MarginCommon.calculateLenderAmountForAddValue(
                short,
                values256[7],
                block.timestamp
            ),
            depositAmount: 0,
            loanOffering: parseLoanOfferingFromAddValueTx(
                short,
                addresses,
                values256,
                values32,
                sigV,
                sigRS
            ),
            exchangeWrapper: addresses[6],
            depositInQuoteToken: depositInQuoteToken
        });

        return transaction;
    }

    function parseLoanOfferingFromAddValueTx(
        MarginCommon.Short storage short,
        address[7] addresses,
        uint256[8] values256,
        uint32[2] values32,
        uint8 sigV,
        bytes32[2] sigRS
    )
        internal
        view
        returns (MarginCommon.LoanOffering memory)
    {
        MarginCommon.LoanOffering memory loanOffering = MarginCommon.LoanOffering({
            payer: addresses[0],
            signer: addresses[1],
            owner: short.lender,
            taker: addresses[2],
            feeRecipient: addresses[3],
            lenderFeeToken: addresses[4],
            takerFeeToken: addresses[5],
            rates: parseLoanOfferingRatesFromAddValueTx(short, values256),
            expirationTimestamp: values256[5],
            callTimeLimit: values32[0],
            maxDuration: values32[1],
            salt: values256[6],
            loanHash: 0,
            signature: parseLoanOfferingSignature(sigV, sigRS)
        });

        loanOffering.loanHash = MarginCommon.getLoanOfferingHash(
            loanOffering,
            short.quoteToken,
            short.baseToken
        );

        return loanOffering;
    }

    function parseLoanOfferingRatesFromAddValueTx(
        MarginCommon.Short storage short,
        uint256[8] values256
    )
        internal
        view
        returns (MarginCommon.LoanRates memory)
    {
        MarginCommon.LoanRates memory rates = MarginCommon.LoanRates({
            maxAmount: values256[0],
            minAmount: values256[1],
            minQuoteToken: values256[2],
            interestRate: short.interestRate,
            lenderFee: values256[3],
            takerFee: values256[4],
            interestPeriod: short.interestPeriod
        });

        return rates;
    }

    function parseLoanOfferingSignature(
        uint8 sigV,
        bytes32[2] sigRS
    )
        internal
        pure
        returns (MarginCommon.Signature memory)
    {
        MarginCommon.Signature memory signature = MarginCommon.Signature({
            v: sigV,
            r: sigRS[0],
            s: sigRS[1]
        });

        return signature;
    }
}
