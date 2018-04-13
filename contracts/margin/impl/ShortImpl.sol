pragma solidity 0.4.21;
pragma experimental "v0.5.0";

import { SafeMath } from "zeppelin-solidity/contracts/math/SafeMath.sol";
import { MarginCommon } from "./MarginCommon.sol";
import { MarginState } from "./MarginState.sol";
import { ShortShared } from "./ShortShared.sol";
import { TransferInternal } from "./TransferInternal.sol";
import { LoanOwner } from "../interfaces/LoanOwner.sol";
import { ShortOwner } from "../interfaces/ShortOwner.sol";


/**
 * @title ShortImpl
 * @author dYdX
 *
 * This library contains the implementation for the short function of Margin
 */
library ShortImpl {
    using SafeMath for uint256;

    // ------------------------
    // -------- Events --------
    // ------------------------

    /**
     * A short sell occurred
     */
    event ShortInitiated(
        bytes32 indexed marginId,
        address indexed shortSeller,
        address indexed lender,
        bytes32 loanHash,
        address baseToken,
        address quoteToken,
        address loanFeeRecipient,
        uint256 shortAmount,
        uint256 quoteTokenFromSell,
        uint256 depositAmount,
        uint256 interestRate,
        uint32  callTimeLimit,
        uint32  maxDuration,
        uint32  interestPeriod
    );

    // -------------------------------------------
    // ----- Public Implementation Functions -----
    // -------------------------------------------

    function shortImpl(
        MarginState.State storage state,
        address[11] addresses,
        uint256[9] values256,
        uint32[4] values32,
        uint8 sigV,
        bytes32[2] sigRS,
        bool depositInQuoteToken,
        bytes orderData
    )
        public
        returns (bytes32)
    {
        ShortShared.ShortTx memory transaction = parseShortTx(
            addresses,
            values256,
            values32,
            sigV,
            sigRS,
            depositInQuoteToken
        );

        bytes32 marginId = getNextmarginId(state, transaction.loanOffering.loanHash);

        uint256 quoteTokenFromSell;

        (quoteTokenFromSell,) = ShortShared.shortInternalPreStateUpdate(
            state,
            transaction,
            marginId,
            orderData
        );

        // Comes before updateState() so that ShortInitiated event is before Transferred events
        recordShortInitiated(
            marginId,
            msg.sender,
            transaction,
            quoteTokenFromSell
        );

        updateState(
            state,
            marginId,
            transaction
        );

        ShortShared.shortInternalPostStateUpdate(
            state,
            transaction,
            marginId
        );

        return marginId;
    }

    // --------- Helper Functions ---------

    function getNextmarginId(
        MarginState.State storage state,
        bytes32 loanHash
    )
        internal
        view
        returns (bytes32)
    {
        bytes32 marginId = keccak256(
            loanHash,
            state.loanNumbers[loanHash]
        );

        // Make this marginId doesn't already exist
        assert(!MarginCommon.containsShortImpl(state, marginId));

        return marginId;
    }

    function recordShortInitiated(
        bytes32 marginId,
        address shortSeller,
        ShortShared.ShortTx transaction,
        uint256 quoteTokenReceived
    )
        internal
    {
        emit ShortInitiated(
            marginId,
            shortSeller,
            transaction.loanOffering.payer,
            transaction.loanOffering.loanHash,
            transaction.baseToken,
            transaction.quoteToken,
            transaction.loanOffering.feeRecipient,
            transaction.effectiveAmount,
            quoteTokenReceived,
            transaction.depositAmount,
            transaction.loanOffering.rates.interestRate,
            transaction.loanOffering.callTimeLimit,
            transaction.loanOffering.maxDuration,
            transaction.loanOffering.rates.interestPeriod
        );
    }

    function updateState(
        MarginState.State storage state,
        bytes32 marginId,
        ShortShared.ShortTx transaction
    )
        internal
    {
        assert(!MarginCommon.containsShortImpl(state, marginId));

        // Update global amounts for the loan and lender
        state.loanFills[transaction.loanOffering.loanHash] =
            state.loanFills[transaction.loanOffering.loanHash].add(transaction.effectiveAmount);
        state.loanNumbers[transaction.loanOffering.loanHash] =
            state.loanNumbers[transaction.loanOffering.loanHash].add(1);

        state.shorts[marginId].baseToken = transaction.baseToken;
        state.shorts[marginId].quoteToken = transaction.quoteToken;
        state.shorts[marginId].shortAmount = transaction.effectiveAmount;
        state.shorts[marginId].callTimeLimit = transaction.loanOffering.callTimeLimit;
        state.shorts[marginId].startTimestamp = uint32(block.timestamp);
        state.shorts[marginId].maxDuration = transaction.loanOffering.maxDuration;
        state.shorts[marginId].interestRate = transaction.loanOffering.rates.interestRate;
        state.shorts[marginId].interestPeriod = transaction.loanOffering.rates.interestPeriod;

        bool newLender = transaction.loanOffering.owner != transaction.loanOffering.payer;
        bool newSeller = transaction.owner != msg.sender;

        state.shorts[marginId].lender = TransferInternal.grantLoanOwnership(
            marginId,
            newLender ? transaction.loanOffering.payer : address(0),
            transaction.loanOffering.owner);

        state.shorts[marginId].seller = TransferInternal.grantShortOwnership(
            marginId,
            newSeller ? msg.sender : address(0),
            transaction.owner);
    }

    // -------- Parsing Functions -------

    function parseShortTx(
        address[11] addresses,
        uint256[9] values256,
        uint32[4] values32,
        uint8 sigV,
        bytes32[2] sigRS,
        bool depositInQuoteToken
    )
        internal
        view
        returns (ShortShared.ShortTx memory)
    {
        ShortShared.ShortTx memory transaction = ShortShared.ShortTx({
            owner: addresses[0],
            baseToken: addresses[1],
            quoteToken: addresses[2],
            effectiveAmount: values256[7],
            lenderAmount: values256[7],
            depositAmount: values256[8],
            loanOffering: parseLoanOffering(
                addresses,
                values256,
                values32,
                sigV,
                sigRS
            ),
            exchangeWrapper: addresses[10],
            depositInQuoteToken: depositInQuoteToken
        });

        return transaction;
    }

    function parseLoanOffering(
        address[11] addresses,
        uint256[9] values256,
        uint32[4] values32,
        uint8 sigV,
        bytes32[2] sigRS
    )
        internal
        view
        returns (MarginCommon.LoanOffering memory)
    {
        MarginCommon.LoanOffering memory loanOffering = MarginCommon.LoanOffering({
            payer: addresses[3],
            signer: addresses[4],
            owner: addresses[5],
            taker: addresses[6],
            feeRecipient: addresses[7],
            lenderFeeToken: addresses[8],
            takerFeeToken: addresses[9],
            rates: parseLoanOfferRates(values256, values32),
            expirationTimestamp: values256[5],
            callTimeLimit: values32[0],
            maxDuration: values32[1],
            salt: values256[6],
            loanHash: 0,
            signature: parseLoanOfferingSignature(sigV, sigRS)
        });

        loanOffering.loanHash = MarginCommon.getLoanOfferingHash(
            loanOffering,
            addresses[2],
            addresses[1]
        );

        return loanOffering;
    }

    function parseLoanOfferRates(
        uint256[9] values256,
        uint32[4] values32
    )
        internal
        pure
        returns (MarginCommon.LoanRates memory)
    {
        MarginCommon.LoanRates memory rates = MarginCommon.LoanRates({
            maxAmount: values256[0],
            minAmount: values256[1],
            minQuoteToken: values256[2],
            interestRate: values32[2],
            lenderFee: values256[3],
            takerFee: values256[4],
            interestPeriod: values32[3]
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
