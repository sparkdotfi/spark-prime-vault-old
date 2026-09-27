### Settlement Ledger
A `Settlement` entry exists for all participating users. It is the users accounting ledger, and is used by helper view functions as well as the core accounting logic for mint/burning/queuing. 

### Transaction
An element in the FIFO queue is represented as a `Transaction` object. The queue is represented as a `TransactionQueue`, with it's own library `TransactionLib` built on-top of the OpenZeppelin Double-Ended Queue. 

### Interest 
Skys default interest rate model is mirrored, compounding rate per-second. It is not possible to set the value below `1 RAY` i.e negative rate. 


### Actors
The Spark Planner orchestrates. Entry-point can be either the planner directly or the PAU. From my understanding, the FLC PAU can only ever transfer funds to this vault via normal ERC20 transfer. The contract is agnostic to the existence of an FLC.

## SPARK PAU 
The Spark PAU is responsible for extracting and injecting funds via `take` and `ERC20.transfer`:
 `LIQUIDITY_MANAGER` (see `ILiquidityManagement`)

## Spark Automated Software (Planner)
The Spark Planner is responsible for Adjusting Interest Rates, Lowering totalAssets to reflect a realized loss, Unrestrictedly moving idle funds to/from Spark Savings Vault and executing order-matching
Acts as the `REBALANCER` (see `IRebalancer`)
Acts as the `VAULT_MANAGER` (see `IVaultManagement`)

### Deposits 
#### Request Deposit
When a deposit queue does not exist and available capacity exists (diff between totalSupply and maximumCapacity), we can mark a `requestDeposit` amount as claimable immediately. 

In the edge case that an instant claim can only be partially filled via available capacity, the remainder is pushed to the deposit queue (see next) (This how the first deposit queue member comes into existence). 

Once capacity is exceeded (a.k.a a deposit queue already exists), all deposits enter the FIFO deposit queue. 

The user funds are transferred to the vault contract, regardless of instant claim/queueing.


#### Enter Deposit Queue 
A Deposit Queue is a FIFO queue of `Transaction` object hashes. A transaction defines the amount (in savings vault shares), beneficiary, controller and nonce. The hash is the `keccack256(controller, nonce)`. We don't hash the entire struct as the `amount` field is mutable in the case of a partial fill (The last processed element is usually always partially filled)

The user funds are directly deposited into the Savings Vault, which returns a `shares` amount. This share amount is pushed in the deposit queue as a `Transaction`. 

### Process Deposit Queue
A queued transaction enters processing via curator function `processQueue(tradeVolume)`

At this stage the users Savings Vault Shares are withdrawn from the Savings Vault, returning `assets` denominated in baseAssets.
The baseAssets are converted to `shares` via `convertToShares(assets)`. We store both inside the users `Settlement` ledger as `depositedAssets` and `sharesOwed`, which we'll use to lock the yield.

Locking Yield: A user should earn yield whilst being a member of the queue via the Savings Vault. Once Spark marks their deposit claimable, they no longer earn any yield. They hold a claim for `X baseAssets in, Y shares out`.

The queue itself is either fully or partially filled. 

### Claim Deposit
A user or Spark (if they've been authorized by the user) can perform a claim for the deposits. The share amount is calculated using the total `depositedAssets` and `sharesOwed` amounts stored in the users `Settlement` ledger. 

The users ledger is updated and the owed share amount is transferred to the user from the vault's escrow. The shares were already minted when the deposit became Claimable, so the claim only changes the share ownership. This means `totalSupply()` does not move.

TotalClaimableDeposits is decremented when the transfer occurs.

### Request Withdraw

The shares are immediately transferred to the vault.

When a withdraw queue doesn't exist, the request is fulfilled by the vaults avalable idle base asset balance (Sleeve). The users `Settlement` ledger `withdrawnShares` and `assetsOwed` are incremented using the `shares` and `assets`

Similar to Deposit Queue, if the entire requested amount cannot be fulfilled, the remainder is pushed to the FIFO Withdraw Queue (This is how the first member of the Withdraw Queue is born)

When the request is instantly fulfilled, the shares are burnt.

### Enter Withdraw Queue

Any remainder amounts are pushed to the FIFO Withdraw queue. The funds remain unburnt and held by the vault. This allows withdrawers to earn the vaults yield as they wait for exit. The shares will be burnt during queue processing `processQueue` (see Process Withdraw Queue)

The mechanisms work exactly the same as a Deposit Queue, a `Transaction` object is pushed to the FIFO Withdraw Queue. The queue itself is either fully or partially filled. The `amount` field represents the vault share amount.


### Process Withdraw Queue
A queued transaction enters processing via curator function `processQueue(tradeVolume)`

All shares processed in the withdraw queue are burnt in a single `burn(totalShares)` call. The withdraw queue is always processed before the deposit queue, this is so that the Vault Accounting aligns. All burnt shares from the withdraw queue increase the available capacity of the vault. This is what allows deposit queue entries to be marked claimable, minting their shares into the vault's escrow in a single batch.

Similar to Deposits, we lock the yield at the time of processing. A withdraw earns yield from Pending until Claimable state. This mitigates any concerns of withdrawers indefinitely remaining unclaimed and earning interest.

At the time of processing:
The `Settlement` entry for each queue member is updated, incrementing their claimable asset amounts.
Their `withdrawnShares` is incremented by the processed amount in the `Transaction` (can be fully, or partially)
Their `assetsOwed` is incremented by the `convertToAssets(tx.amount)`, this locks in their yield. 

### Claim Withdraw Queue
Mirroring deposits, the locked `withdrawnShares` and `assetsOwed` are used to calculate the baseAsset amount owed to the user, and are transferred. Their `Settlement` entry is updated accordingly. 

TotalClaimableWithdraws is decremented.

### Accounting
Idle Base Assets 
where does it come from: Instant Claim Deposits, Redeemed Deposits from Queue Processing and Injected Capital from Spark.
Usage: Withdraws eat

Savings Vault Shares
where does it come from: Queued Depositors + Rebalancer positioning of spark capital via IRebalancer
Usage: Pending Deposits (on `processQueue`) unwind savings vault shares into Idle Base Assets and are rewarded with spPRIME vault shares

Note for auditor:

Previous Invariant: Savings Balance >= totalPendingDeposits;
Invariant DOES NOT hold, insolvency is possible. Spark wants complete control over savings vault balance via IRebalancer, unwinding savings vault shares will leave the depositors blocked.

Previous Invariant: Idle Base Assets >= Total Claimable Withdraws
Invariant DOES NOT hold, insolvency is possible. Same reason as above, Spark may allocate idle base assets and block withdrawers.

This means Spark is fully responsible for ensuring liquidity is available to withdrawers and depositors, and that a processQueue function doesn't fail as a result of neglected accounting.

### Mint and Burns
Simply put: Withdraw Queue member shares are burnt, Deposit Queue member shares are minted. We can mint at most how much we have burnt + the available capacity (diff between totalSupply and maximumCapacity)

Redeemed shares are burned. Shares leave the owner's custody on
`requestRedeem` and are escrowed by the vault while the request is Pending; they are
burned at the moment the request becomes Claimable. Queue fills burn once for the whole
batch.

Deposit shares are minted into the vaults escrow when the deposit becomes Claimable: 

per request on the instant path of `requestDeposit`

once for the whole batch in `processQueue`. `deposit` and `mint` transfer them from the escrow to the receiver.

The vault's share balance is exactly the sum of the two escrows, and invariant `balanceOf(address(this)) == totalPendingWithdraws() + claimableDepositTotal()`

 `totalClaimableDepositShares` is never derived from the balance, since anyone can transfer spPRIME to the vault and perform a form of donation manipulation

The Withdraw Queue is always processed before the Deposit Queue. Because the burn reduces supply, which frees up shares to be minted in the Deposit Queue fill

### Capacity is counted in spPRIME shares
`maxCapacity()` caps `totalSupply()`, which includes the shares escrowed for pending redeems until `processQueue` burns them and the shares escrowed for claimable deposits until they are claimed. `availableCapacity()` is what is left, `maxCapacity() - totalSupply()`.

The index does not consume capacity. A vault at its cap stays exactly at its cap as interest accrues, while the base asset value of a full vault grows with the index. Once capacity is reached, newer deposits are queued, and `processQueue` must be called by the curator to fulfill deposit demand through withdraw demand. If no withdraw demand exists, the curator may raise the capacity and then call `processQueue`.

Invariant: `totalSupply() <= maxCapacity()`. It holds because:
- an instant `requestDeposit` pays for the remaining capacity rounded up and mints exactly those shares
- `processQueue` rejects any `tradeVolume` above `convertToAssets(totalPendingWithdraws() + availableCapacity())`, so a fill never mints more shares than it burns plus `availableCapacity()`. We check the invaraint post-fill for sanity 

- `deposit` and `mint` only transfer shares out of the escrow, leaving supply unchanged,

- `setCapacity` reverts below `totalSupply()`.

`test/Capacity.invariant.t.sol` checks it across every user entry point, `processQueue`, `setCapacity`, time and savings yield, together with `balanceOf(address(this)) == totalPendingWithdraws() + claimableDepositTotal()`.

`MAXIMUM_CAPACITY` in the deploy script is a share amount. The index starts at RAY, so at deployment it equals the same amount of base asset.

Note for auditor: an instant credit fills the capacity exactly only while the index is at least RAY. The index starts at RAY and never falls, because `setInterestRate` reverts with `InterestRateBelowRay` for any rate below RAY, as sUSDS does. `initialize` does not check the rate, so the deployment must pass one at or above RAY. `setInterestRate` also accrues at the old rate before switching, so a new rate never applies to time that has already passed, as sUSDS and Spark Vaults require.

### `take()` has no solvency guard
`take` transfers any amount up to the full base-asset balance, with no check against `claimableWithdrawTotal()`. These assets are already promised to users, and will result in revert with `Insolvency` at claim time. 

The `take()` function is access controlled to the PAU, It was suggested to Spark to add insolvency safe guards but it was decided they want full control via PAU over funds. `test_takeAfterMatching_makesVaultInsolvent`

The same holds for `withdrawFromSavings` and the savings shares backing the deposit queue (see Accounting).

`pause` blocks claims (`deposit`, `mint`, `redeem`, `withdraw`) as well as requests, so users cannot reach amounts already set aside for them while paused. `take` and `withdrawFromSavings` are not paused and stay available to Spark.

### The savings position is not liquidity
`availableLiquidAssets()` counts idle base asset only. Savings shares the Rebalancer holds outside the deposit queue are counted nowhere, so moving idle capital into savings reduces what `processQueue` can settle and what instant withdrawers receive, and can leave a Claimable redemption unpaid until Spark unwinds it (`test_depositToSavings_canStrandAClaimableRedeemer`). Spark's planner is responsible for unwinding before it processes.

### The savings vault is fixed at initialization and cannot be changed
`initialize` sets the savings vault once and checks that its `asset()` is the base asset. There is no setter: switching venue requires a proxy upgrade, and only while the deposit queue is empty, since every queue entry is denominated in the current venue's shares.

### `setOperator` stores a single operator
To simplify the model and allow Spark to rotate keys via the `AdministeredAgent`, a single Operator entry is permitted per user. This is set once by the user before they begin their Vault Journey, and Spark rotates it's keys that interact with the address in question.

## Claimable redemptions are paid at the rate during their processQueue execution

When a request becomes Claimable the vault records the asset value owed
(`Settlement.assetsOwed`) alongside the shares burnt (`Settlement.withdrawnShares`)

 `redeem` and `withdraw` pay against that stored asset value, not against the live
index. 

A claim may sit unclaimed, it will not accrue interest or occupy shares. 

Yield accrues for the whole time a request is Pending, which is the period users are
actually waiting. It stops at the Claimable transition (`processQueue`), where the vault has
already set the assets aside and they are no longer at work.

A user who never claims wont cost anyone anything because their shares are already
burned and the capacity is already released, so depositors are unaffected. The assets owed
to them stay inside `claimableWithdrawTotal()`, which `availableLiquidAssets`
subtracts. 

### `requestRedeem` and `requestDeposit` are Operator barred functions
The ERC 7540 spec defines that a user set operator should be able to perform requests on behalf of the user, the contract violates this spec. The blast radius of this spec violation is Spark itself (as Spark is the only Operator that should ever be set). This is a known trade off in order to guarantee Spark can only perform claims on behalf of users, not requests.

Note for auditor: A `controller` could not be used, as the 7540 spec clearly defines either a user or a controller can perform a clain, never both. The controller spec should not be violated as users may automate or delegate their request lifecycles, we opted to make Spark an Operator instead.

Note: PAU goes through the wrapper for operators

### Queued deposits wait in the savings vault
The part of a `requestDeposit` that cannot be claimed instantly is deposited into the savings vault immediately, and the queue entry stores the savings shares received. The instantly claimable part stays as idle base asset.

`totalPendingDeposits()` is denominated in savings shares, the way `totalPendingWithdraws()` is denominated in spPRIME shares. `pendingDepositRequest` converts the controller's savings shares with the savings vault's `convertToAssets`, so it grows with the savings yield while the request waits.

At `processQueue` the deposit fill takes a single rate snapshot (the base asset value of the fill divided by the savings shares it consumes), credits every entry at that rate, and redeems all matched savings shares in one call. The redeemed base asset lands as idle and pays the withdrawers matched in the same call.

Instant withdrawers are only paid from idle base asset. The savings shares backing the deposit queue are never used for them.

Cancelling a queued deposit redeems its savings shares straight to the owner, so the refund is the principal plus the savings yield earned while queued.

Note for auditor: the vault must be able to deposit into and redeem from the savings vault. A deposit cap or pause on the savings vault makes queued `requestDeposit` calls revert, and missing redemption liquidity makes `processQueue` (when it fills deposits) and cancellations revert. If Spark unwinds the savings shares backing the queue (see Accounting), restoring them means depositing enough base asset to mint the missing shares back (`previewMint`), which can cost more than was unwound.

### Claimable deposits are escrowed in spPRIME shares
When a deposit becomes Claimable (instantly in `requestDeposit`, or in `processQueue`) the vault fixes the spPRIME shares owed (`Settlement.sharesOwed`) alongside the base asset (`Settlement.depositedAssets`). `deposit` and `mint` pay against that stored ratio, the mirror of `redeem` and `withdraw`. A depositor receives the same shares whenever they claim.

The shares are minted into the vault's escrow at the Claimable transition, so `totalSupply()` and `totalAssets()` include every processed deposit from that moment, claimed or not. `claimableDepositTotal()` counts the escrowed shares until they are claimed.

### Rounding favours the vault
Everything a user receives rounds down and everything a user pays rounds up: `deposit` and `redeem` pay out rounded down, `mint` and `withdraw` charge rounded up. Queue fills round each credit down, and a partial deposit fill consumes savings shares rounded up, so the redemption always covers the matched withdrawers and the surplus stays in the vault.

The index compounds with `_rpow` copied verbatim from Sky's sUSDS, the same code Spark Vaults use, and each accrual then rounds the index down, as sUSDS does. `_rpow` rounds each squaring and multiplication to the nearest 1e-27 rather than down, so the compounding factor can land slightly above the exact value. This is the one exception to the rule above, kept so the index follows Sky's arithmetic exactly.

A credit too small to buy one spPRIME share is forfeited instead of recorded, and a `requestDeposit` too small to buy one share reverts, so no controller can hold a claimable balance they cannot claim. The instant part of a `requestDeposit` pays for the remaining capacity rounded up.


### `processQueue` reverts if Trade Volume exceeds liquidity or capacity
The curator can define `tradeVolume`, the amount of volume in base asset units that should be exchanged between queues should consume. `processQueue` accepts it only if it is within both limits that make up `maxTradeVolume()`, checked after accrual and before either queue is walked:

- Base asset: `tradeVolume` cannot be larger than idle liquidity (`availableLiquidAssets()`) plus the value of the deposit queue, or the call reverts with `InputVolumeExceedsLiquidity`. The idle liquidity is what would have been instant claimed if no queues existed; once a queue exists, it is consumed by `processQueue`.
- Shares: `tradeVolume` cannot be larger than `convertToAssets(totalPendingWithdraws() + availableCapacity())`, or the call reverts with `InputVolumeExceedsAvailableCapacity`. The withdraw side burns up to `totalPendingWithdraws()` and the deposit side locks at most the shares `tradeVolume` buys, so a volume within this limit never locks more shares than it burns plus `availableCapacity()`. The natural volume, the smaller of the two queue values, always passes, even at zero capacity.

After the fills, `processQueue` checks both again: `AssetInvariantBroken` if the vault owes more base asset than it holds, `ShareInvariantBroken` if `totalSupply()` exceeds `maxCapacity()`.

`maxTradeVolume()` on `ILiquidityManagement` is the smaller of the two limits, and is what the liquidity manager sizes a call from. It reads the stored index; `processQueue` accrues first and accrual only raises the share limit, so a value read before the call still passes. The share limit rejects no useful volume: above it, a volume either does nothing beyond filling both queues, or would lock more shares than the withdraw side burns plus `availableCapacity()`.

Note for auditor: when Spark has already taken base asset owed to claimable withdrawals (see `take()`), `availableLiquidAssets()` is negative and every `processQueue` reverts with `AssetInvariantBroken` until Spark returns it.

## `processQueue` loop is bounded by tradeVolume, not by elements
The curator defines exactly how much volume should be traded between the deposit and withdraw queues, and iteration occurs until this volume is fulfilled.

Note for auditor: It has already been discussed that a minimum deposit + withdraw amount must be defined, to prevent users bloating queue length.

## Cancellations only for deposits
A withdraw cannot be cancelled, once a user enters a queue they can only exit after fulfillment. This is agreed upon with Spark.

A user, controller, Operator and Vault Manager can cancel a deposit request as long as it has NOT been processed a.ka it can only be cancelled while it is pending.

The refund comes from unwinding entry's savings share amount which accounts for their principle + yield.