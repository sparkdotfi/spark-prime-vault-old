### Settlement Ledger
A `Settlement` entry exists for all participating users. It is the users accounting ledger, and is used by helper view functions as well as the core accounting logic for mint/burning/queuing. 

### Transaction
An element in the FIFO queue is represented as a `Transaction` object. The queue is represented as a `TransactionQueue.RequestQueue`, with it's own library `TransactionQueue` built on-top of the OpenZeppelin Double-Ended Queue. 

### Interest 
Skys default interest rate model is mirrored, compounding rate per-second. It is not possible to set the value below `1 RAY` i.e negative rate, or above `MAX_RATE` (100% APY). 


### Actors
The Spark Planner orchestrates. Entry-point can be either the planner directly or the PAU. From my understanding, the FLC PAU can only ever transfer funds to this vault via normal ERC20 transfer. The contract is agnostic to the existence of an FLC.

## SPARK PAU 
The Spark PAU is responsible for extracting and injecting funds via `take` and `ERC20.transfer`:
 `LIQUIDITY_MANAGER` (see `ILiquidityManagement`)

## Spark Automated Software (Planner)
The Spark Planner is responsible for Adjusting Interest Rates, Setting capacity and minimums, Moving idle funds to/from Spark Savings Vault (never funds owed to claimers or the shares backing the deposit queue, see Accounting) and executing order-matching
Acts as the `REBALANCER` (see `IRebalancer`)
Acts as the `VAULT_MANAGER` (see `IVaultManagement`)

## Guardian
Pauses requests and claims, and cancels queued deposits for compliance: `GUARDIAN`

## Risk Manager
Lowers totalAssets to reflect a realized loss (only while paused) and sets the withdraw fee: `RISK_MANAGER`

Each role is held by a different actor, see Separation of concerns in the README for what each can do and the worst case if it is compromised.

### Deposits 
#### Request Deposit
When a deposit queue does not exist and available capacity exists (diff between totalSupply and maximumCapacity), we can mark a `requestDeposit` amount as claimable immediately. 

In the edge case that an instant claim can only be partially filled via available capacity, the remainder is pushed to the deposit queue (see next) (This how the first deposit queue member comes into existence). 

Once capacity is exceeded (a.k.a a deposit queue already exists), all deposits enter the FIFO deposit queue. 

The user funds are transferred to the vault contract, regardless of instant claim/queueing.


#### Enter Deposit Queue 
A Deposit Queue is a FIFO queue of `Transaction` object hashes. A transaction defines the controller, owner, amount (in savings vault shares), nonce and withdraw fee (always 0 for deposits). The hash is the `keccack256(controller, nonce)`. We don't hash the entire struct as the `amount` field is mutable in the case of a partial fill (The last processed element is usually always partially filled)

The user funds are directly deposited into the Savings Vault, which returns a `shares` amount. This share amount is pushed in the deposit queue as a `Transaction`. 

### Process Deposit Queue
A queued transaction enters processing via curator function `processQueue(tradeVolume)`

At this stage the users Savings Vault Shares are withdrawn from the Savings Vault, returning `assets` denominated in baseAssets.
The baseAssets are converted to `shares` via `convertToShares(assets)`. We store both inside the users `Settlement` ledger as `depositedAssets` and `sharesOwed`, which lock the price of the fill.

Locking Yield: A user should earn yield whilst being a member of the queue via the Savings Vault. Once Spark marks their deposit claimable, the price is locked: they hold a claim for `X baseAssets in, Y shares out`. The `Y` shares are minted into escrow at that point, so from then on they earn the vault's rate, whether or not they have been claimed yet.

The queue itself is either fully or partially filled. 

### Claim Deposit
A user or Spark (if they've been authorized by the user) can perform a claim for the deposits. The share amount is calculated using the total `depositedAssets` and `sharesOwed` amounts stored in the users `Settlement` ledger. 

The users ledger is updated and the owed share amount is transferred to the user from the vault's escrow. The shares were already minted when the deposit became Claimable, so the claim only changes the share ownership. This means `totalSupply()` does not move.

`claimableDepositTotal()` is decremented when the transfer occurs.

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

As for deposits, the price is locked at the time of processing. Unlike a deposit, whose escrowed shares keep earning, a withdraw earns yield only from Pending until Claimable state. This mitigates any concerns of withdrawers indefinitely remaining unclaimed and earning interest.

At the time of processing:
The `Settlement` entry for each queue member is updated, incrementing their claimable asset amounts.
Their `withdrawnShares` is incremented by the processed amount in the `Transaction` (can be fully, or partially)
Their `assetsOwed` is incremented by the `convertToAssets(tx.amount)` less the request's withdraw fee, this locks in their yield. 

### Claim Withdraw Queue
Mirroring deposits, the locked `withdrawnShares` and `assetsOwed` are used to calculate the baseAsset amount owed to the user, and are transferred. Their `Settlement` entry is updated accordingly. 

`claimableWithdrawTotal()` is decremented and `TotalClaimableWithdraws` is emitted.

### Withdraw fee
`updateWithdrawFee(bps)` sets the fee for redemption requests made from then on, up to `MAX_WITHDRAW_BPS` (5,000 bps, 50%). Each request stores the fee in force when it was made (`Transaction.fee`), so a later change never reaches it, even while it waits in the queue. The fee is taken from the base asset owed when the request becomes Claimable, rounded up, so `assetsOwed` and `maxWithdraw` are net of it while `withdrawnShares` and `maxRedeem` stay the full share amount. The fee stays in the vault as free liquidity, which Spark can `take`.

### Accounting
Idle Base Assets 
where does it come from: Instant Claim Deposits, Redeemed Deposits from Queue Processing and Injected Capital from Spark.
Usage: Withdraws eat

Savings Vault Shares
where does it come from: Queued Depositors + Rebalancer positioning of spark capital via IRebalancer
Usage: Pending Deposits (on `processQueue`) unwind savings vault shares into Idle Base Assets and are rewarded with spPRIME vault shares

Note for auditor:

Invariant: Savings Balance >= totalPendingDeposits.
`withdrawFromSavings` reverts with `ExceedsFreeSavingsShares` rather than unwind the savings shares backing the deposit queue.

Invariant: Idle Base Assets >= Total Claimable Withdraws.
`take` and `depositToSavings` revert with `ExceedsAvailableLiquidity` above `availableLiquidAssets()`, so they cannot spend base asset owed to claimable withdrawals.

Spark is still responsible for supplying the liquidity that `processQueue` settles with.

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
- `processQueue` clamps `tradeVolume` to `convertToAssets(totalPendingWithdraws() + availableCapacity())`, so a fill never mints more shares than it burns plus `availableCapacity()`. We check the invaraint post-fill for sanity 

- `deposit` and `mint` only transfer shares out of the escrow, leaving supply unchanged,

- `setCapacity` reverts below `totalSupply()`. It also reverts above `type(uint128).max`, as does `initialize`, so share conversions can't overflow.

`test/Capacity.invariant.t.sol` checks it across every user entry point, `processQueue`, `setCapacity`, time and savings yield, together with `balanceOf(address(this)) == totalPendingWithdraws() + claimableDepositTotal()`.

`MAXIMUM_CAPACITY` in the deploy script is a share amount. The index starts at RAY, so at deployment it equals the same amount of base asset.

Note for auditor: an instant credit fills the capacity exactly only while the index is at least RAY. The index starts at RAY and never falls, because `setInterestRate` reverts with `InterestRateBelowRay` for any rate below RAY, as sUSDS does. `initialize` applies the same range check as `setInterestRate`. `setInterestRate` also accrues at the old rate before switching, so a new rate never applies to time that has already passed, as sUSDS and Spark Vaults require.

### `take()` cannot spend assets owed to claimers
`take` transfers at most `availableLiquidAssets()`, the idle base asset not already owed to claimable withdrawals, and reverts with `ExceedsAvailableLiquidity` above it (`test_cannot_take_afterMatching_theAssetsOwedToClaimers`). `depositToSavings` has the same floor, and `withdrawFromSavings` cannot unwind the savings shares backing the deposit queue (see Accounting).

`pause` blocks claims (`deposit`, `mint`, `redeem`, `withdraw`) as well as requests, so users cannot reach amounts already set aside for them while paused. `take` and `withdrawFromSavings` are not paused and stay available to Spark.

### The savings position is not liquidity
`availableLiquidAssets()` counts idle base asset only. Savings shares the Rebalancer holds outside the deposit queue are counted nowhere, so moving idle capital into savings reduces what `processQueue` can settle and what instant withdrawers receive. It cannot strand a Claimable redemption, because `depositToSavings` reverts above `availableLiquidAssets()` (`test_cannot_depositToSavings_theAssetsOwedToAClaimableRedeemer`). Spark's planner is responsible for unwinding before it processes.

### The savings vault is fixed at initialization and cannot be changed
`initialize` sets the savings vault once and checks that its `asset()` is the base asset. There is no setter: switching venue requires a proxy upgrade, and only while the deposit queue is empty, since every queue entry is denominated in the current venue's shares.

### `setOperator` follows the ERC-7540 reference model
Operators are stored per controller as `mapping(controller => mapping(operator => bool))`, so a user can approve several operators and approving one never revokes another. Spark rotates keys via the `AdministeredAgent`: the user approves the agent's address once, and the approval stays valid for as long as the agent's address is the same.

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
The ERC 7540 spec defines that a user set operator should be able to perform requests on behalf of the user, the contract violates this spec. Every operator is restricted the same way: it can only claim, only to the controller (`receiver == controller`), and can never request or cancel. The blast radius of this spec violation is the operators a user approves, which should only ever be Spark. This is a known trade off in order to guarantee Spark can only perform claims on behalf of users, not requests.

Note for auditor: Spark could not be the `controller` instead. A controller owns its requests and can claim them to any receiver, and every user's request would be aggregated under Spark's controller (requestId is always 0). The controller spec should not be violated as users may automate or delegate their request lifecycles, we opted to make Spark an Operator instead.

Note: PAU goes through the wrapper for operators

### Queued deposits wait in the savings vault
The part of a `requestDeposit` that cannot be claimed instantly is deposited into the savings vault immediately, and the queue entry stores the savings shares received. The instantly claimable part stays as idle base asset.

`totalPendingDeposits()` is denominated in savings shares, the way `totalPendingWithdraws()` is denominated in spPRIME shares. `pendingDepositRequest` converts the controller's savings shares with the savings vault's `convertToAssets`, so it grows with the savings yield while the request waits.

At `processQueue` the deposit fill takes a single rate snapshot (the base asset value of the fill divided by the savings shares it consumes), credits every entry at that rate, and redeems all matched savings shares in one call. The redeemed base asset lands as idle and pays the withdrawers matched in the same call.

Instant withdrawers are only paid from idle base asset. The savings shares backing the deposit queue are never used for them.

Cancelling a queued deposit redeems its savings shares straight to the owner, so the refund is the principal plus the savings yield earned while queued.

Note for auditor: the vault must be able to deposit into and redeem from the savings vault. A deposit cap or pause on the savings vault makes queued `requestDeposit` calls revert, and missing redemption liquidity, or a USDC blacklisted owner, makes cancellations revert. `processQueue` only fills deposits up to what the savings vault can redeem now (`maxRedeem`), so missing liquidity shrinks the fill instead of reverting it.

### Claimable deposits are escrowed in spPRIME shares
When a deposit becomes Claimable (instantly in `requestDeposit`, or in `processQueue`) the vault fixes the spPRIME shares owed (`Settlement.sharesOwed`) alongside the base asset (`Settlement.depositedAssets`). `deposit` and `mint` pay against that stored ratio, the mirror of `redeem` and `withdraw`. A depositor receives the same shares whenever they claim.

The shares are minted into the vault's escrow at the Claimable transition, so `totalSupply()` and `totalAssets()` include every processed deposit from that moment, claimed or not. `claimableDepositTotal()` counts the escrowed shares until they are claimed.

### Rounding favours the vault
Everything a user receives rounds down and everything a user pays rounds up: `deposit` and `redeem` pay out rounded down, `mint` and `withdraw` charge rounded up, and the withdraw fee rounds up. Queue fills round each credit down, and a partial deposit fill consumes savings shares rounded up, so the redemption always covers the matched withdrawers and the surplus stays in the vault.

The index compounds with `_rpow` copied verbatim from Sky's sUSDS, the same code Spark Vaults use, and each accrual then rounds the index down, as sUSDS does. `_rpow` rounds each squaring and multiplication to the nearest 1e-27 rather than down, so the compounding factor can land slightly above the exact value. This is the one exception to the rule above, kept so the index follows Sky's arithmetic exactly.

A credit too small to buy one spPRIME share is forfeited instead of recorded, and a `requestDeposit` too small to buy one share reverts, so no controller can hold a claimable balance they cannot claim. The instant part of a `requestDeposit` pays for the remaining capacity rounded up.


### `processQueue` clamps Trade Volume to liquidity and capacity
The curator can define `tradeVolume`, the amount of volume in base asset units that should be exchanged between queues should consume. `processQueue` clamps it to `maxTradeVolume()`, the smaller of two limits, after accrual and before either queue is walked, so a call sized from an earlier read, or front-run by a cancel or an instant request, processes what it can instead of reverting:

- Base asset: idle liquidity (`availableLiquidAssets()`) plus the value of the deposit queue the savings vault can redeem now. The idle liquidity is what would have been instant claimed if no queues existed; once a queue exists, it is consumed by `processQueue`.
- Shares: `convertToAssets(totalPendingWithdraws() + availableCapacity())`. The withdraw side burns up to `totalPendingWithdraws()` and the deposit side locks at most the shares `tradeVolume` buys, so a volume within this limit never locks more shares than it burns plus `availableCapacity()`. The natural volume, the smaller of the two queue values, is never clamped, even at zero capacity.

After the fills, `processQueue` checks both again: `AssetInvariantBroken` if the vault owes more base asset than it holds, `ShareInvariantBroken` if `totalSupply()` exceeds `maxCapacity()`.

`maxTradeVolume()` on `ILiquidityManagement` is the smaller of the two limits, and is what the liquidity manager sizes a call from; passing `type(uint256).max` processes as much as both limits allow. The share limit costs no useful volume: above it, a volume either does nothing beyond filling both queues, or would lock more shares than the withdraw side burns plus `availableCapacity()`.

Note for auditor: `take` and `depositToSavings` cannot push `availableLiquidAssets()` below zero. The deposit side counts only the part of the deposit queue the savings vault can redeem now (`maxRedeem`), and the deposit fill is capped at the same amount, so an illiquid savings vault shrinks the volume instead of reverting `processQueue`.

## `processQueue` loop is bounded by tradeVolume, not by elements
The curator defines exactly how much volume should be traded between the deposit and withdraw queues, and iteration occurs until this volume is fulfilled.

Note for auditor: It has already been discussed that a minimum deposit + withdraw amount must be defined, to prevent users bloating queue length.

## Cancellations only for deposits
A withdraw cannot be cancelled, once a user enters a queue they can only exit after fulfillment. This is agreed upon with Spark.

The owner, the controller and the Guardian can cancel a deposit request as long as it has NOT been processed a.ka it can only be cancelled while it is pending. The nonce to cancel with is emitted in `DepositQueued` when the request enters the queue.

The refund comes from unwinding entry's savings share amount which accounts for their principle + yield.