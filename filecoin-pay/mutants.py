# (id, description, old, new) - each `old` must occur exactly once in src/FilecoinPayV1.sol
M = [
 ("M01","termination endEpoch one epoch short","rail.endEpoch = payer.lockupLastSettledAt + rail.lockupPeriod;","rail.endEpoch = payer.lockupLastSettledAt + rail.lockupPeriod - 1;"),
 ("M02","network fee rounds down instead of up","fee = (amount * NETWORK_FEE_NUMERATOR + (NETWORK_FEE_DENOMINATOR - 1)) / NETWORK_FEE_DENOMINATOR;","fee = (amount * NETWORK_FEE_NUMERATOR) / NETWORK_FEE_DENOMINATOR;"),
 ("M03","one-time payment not taken out of rail fixed lockup","rail.lockupFixed = rail.lockupFixed - oneTimePayment;","rail.lockupFixed = rail.lockupFixed - oneTimePayment / 2;"),
 ("M04","one-time payment does not consume lockupAllowance","oneTimePayment > approval.lockupAllowance ? 0 : approval.lockupAllowance - oneTimePayment;","approval.lockupAllowance;"),
 ("M05","rate change re-locks over full period instead of effective period (terminated rails)","updateOperatorLockupUsage(operatorApproval, oldRate * effectiveLockupPeriod, newRate * effectiveLockupPeriod);","updateOperatorLockupUsage(operatorApproval, oldRate * rail.lockupPeriod, newRate * rail.lockupPeriod);"),
 ("M06","validator-withheld funds stay locked","payer.lockupCurrent -= requiredLockup;","payer.lockupCurrent -= grossSettledAmount;"),
 ("M07","account settlement boundary: exactly-funded treated as short","if (account.funds >= account.lockupCurrent + additionalLockup) {","if (account.funds > account.lockupCurrent + additionalLockup) {"),
 ("M08","partial account settlement rounds epochs up","uint256 fractionalEpochs = availableFunds / account.lockupRate;","uint256 fractionalEpochs = (availableFunds + account.lockupRate - 1) / account.lockupRate;"),
 ("M09","finalization does not unlock unused fixed lockup","payer.lockupCurrent -= rail.lockupFixed;","payer.lockupCurrent -= rail.lockupFixed / 2;"),
 ("M10","live-rail settlement not capped at payer's settled epoch","maxSettlementEpoch = min(untilEpoch, payer.lockupLastSettledAt);","maxSettlementEpoch = untilEpoch;"),
 ("M11","terminated-rail settlement not capped at endEpoch","maxSettlementEpoch = min(untilEpoch, rail.endEpoch);","maxSettlementEpoch = untilEpoch;"),
 ("M12","rate decrease frees only half the rate usage","approval.rateUsage = approval.rateUsage > rateDecrease ? approval.rateUsage - rateDecrease : 0;","approval.rateUsage = approval.rateUsage > rateDecrease ? approval.rateUsage - rateDecrease / 2 : 0;"),
 ("M13","commission credited to recipient twice","serviceFeeRecipientAccount.funds += operatorCommission;","serviceFeeRecipientAccount.funds += 2 * operatorCommission;"),
 ("M14","payer can terminate while in debt","(msg.sender == rail.from && isAccountLockupFullySettled(payer)) || msg.sender == rail.operator,","(msg.sender == rail.from) || msg.sender == rail.operator,"),
]
