# Spark spPRIME Vault
**Author:** 0xpotionseller (arkis.xyz)


**Email:** rayyan.jafri@arkis.xyz


**Abstract:**: spPRIME vault allows retail and institutional investors alike to deposit funds into a Spark managed vault. Spark has a free hand over the vault's free liquidity, extracting funds out via their Sky PAU system to allocate into Arkis Private Vaults and vice versa: Inject capital into the vault to show profits or cover upto 10% of the losses incurred in the Arkis Vault via Sky PAU FLC (First Loss Capital). Funds already owed to claimable withdrawals, and the Savings Vault shares backing queued deposits, can never be extracted.



Whenever immediate liquidity is exhausted (No more share supply for depositors/No more immediate base assets for withdrawers): The vault system transitions into FIFO Deposit-Withdraw Queue fulfillment, which are matched order book style against eachother when Spark deems necessary. 

Deposit Queue Members earn yields from Spark Savings Vault, making their capital efficient as they wait to gain shares of spPRIME

Withdraw Queue Members earn yield from spPRIME as they wait to be processed.

Spark can charge a withdraw fee of up to 50%. A withdraw request keeps the fee in force when it was made, so changing the fee never affects existing requests.

Share prices are locked at processing time, preventing any gaming of the queue system. Spark also defines minimum deposit and withdraw entries for users, to prevent grief attacking the FIFO structure. The minimum applies to the request, so the part of a request that can't be filled instantly may enter the queue below it. 

Spark reserves the right to cancel deposits for compliance reasons, a user also reserves the right to cancel a deposit. Cancellations can take place at any time before processing. 

## Separation of concerns

Each role is held by a different actor, so a compromised actor can only do what its own role allows. No actor should hold two of these roles.

**Operator** (approved by each user, the Spark `AdministeredAgent`)
Can: claim deposits and withdrawals for a controller, paid only to that controller.
Worst case if compromised: claims are performed earlier than planned, can only goto owners. No loss.

**Rebalancer** (Spark Planner)
Can: `processQueue`, `depositToSavings`, `withdrawFromSavings`.
Worst case if compromised: the queues are processed slowly or not at all, and free idle cash is moved into or out of the Savings Vault. It can never move funds owed to claimers or the Savings Vault shares backing queued deposits. No loss.

**Vault Manager** (Spark Planner)
Can: `setInterestRate`, `setCapacity`, `setMinimumDeposit`, `setMinimumWithdraw`.
Worst case if compromised: the rate is set to the maximum (100% APY), so the vault accrues more than it earns at Spark's expense, or to 0%, so users earn nothing. Capacity and minimums can be set to block new deposits or withdraw requests. No funds leave the vault.

**Guardian**
Can: `pause`, and cancel queued deposits for compliance.
Worst case if compromised: requests and claims stay paused until the Admin unpauses, and queued deposits are cancelled, which refunds their owners but loses their place in the queue. No loss.

**Risk Manager**
Can: `setTotalAssets` (only while paused), `updateWithdrawFee`.
Worst case if compromised: the withdraw fee is raised to 50% for new withdraw requests. Booking a fake loss also needs the Guardian to pause the vault first, so cutting users' value takes two compromised actors.

**Liquidity Manager** (Spark PAU)
Can: `take`.
Worst case if compromised: the vault's free idle cash is taken, within the PAU's own rate limits. It can never take funds owed to claimers or the Savings Vault shares backing queued deposits.

**Admin**
Can: grant and revoke every role, `unpause`.
Worst case if compromised: everything, since it can grant itself any role. It should be a governance multisig behind a timelock, as should whoever can upgrade the vault.

Pairs that must never be held by the same actor:
- Guardian and Risk Manager: together they can pause and book a fake loss.
- Risk Manager and Liquidity Manager: together they can raise the fee or book a loss, then take what that frees up.
- Operator and any role: the operator would gain that role's powers over every user who approved it.

Rebalancer and Liquidity Manager together can unwind Spark's free Savings Vault position and take it. That is Spark's own capital, never users' funds.

## Cancelled Deposit Entries

The deposit queue is an OpenZeppelin `DoubleEndedQueue`, which can only remove from its ends. Cancelling a queued deposit deletes the request but leaves its key in the queue. `TransactionQueue.RequestQueue.cancelled` counts these dead keys, so `depositQueueLength()` and `isEmpty()` only count live requests. Fills drop dead keys as they pop past them.

Dead keys still cost gas when `processQueue` walks over them. `sanitizeDepositQueue(maxIterations)` removes the cancelled keys among the first `maxIterations` entries without changing queue order. Anyone can call it, and it does nothing when no cancellations are pending, so the planner should call it before every `processQueue`.

### Future work: migrate to a linked list

If audit scope and timeline allow, replace the deque inside `TransactionQueue` with a doubly linked list keyed by the existing request key (`controller`, `nonce`). A cancel would unlink its entry in O(1), dead keys would never exist, and fills would only touch live entries. The `cancelled` counter and `sanitizeDepositQueue` can then be deleted.

The costs: roughly 25k more gas per queued request (two pointer slots per entry), a custom unaudited data structure that needs its own fuzz tests.