# Spark spPRIME Vault
**Author:** 0xpotionseller (arkis.xyz)


**Email:** rayyan.jafri@arkis.xyz


**Abstract:**: spPRIME vault allows retail and institutional investors alike to deposit funds into a Spark managed vault. Spark has a free hand over liquidity management, extracting funds out via their Sky PAU system to allocate into Arkis Private Vaults and vice versa: Inject capital into the vault to show profits or cover upto 10% of the losses incurred in the Arkis Vault via Sky PAU FLC (First Loss Capital).



Whenever immediate liquidity is exhausted (No more share supply for depositors/No more immediate base assets for withdrawers): The vault system transitions into FIFO Deposit-Withdraw Queue fulfillment, which are matched order book style against eachother when Spark deems necessary. 

Deposit Queue Members earn yields from Spark Savings Vault, making their capital efficient as they wait to gain shares of spPRIME

Withdraw Queue Members earn yield from spPRIME as they wait to be processed.

Share prices are locked at processing time, preventing any gaming of the queue system. Spark also defines minimum deposit and withdraw entries for users, to prevent grief attacking the FIFO structure. 

Spark reserves the right to cancel deposits for compliance reasons, a user also reserves the right to cancel a deposit. Cancellations can take place at any time before processing. 

## Cancelled Deposit Entries

The deposit queue is an OpenZeppelin `DoubleEndedQueue`, which can only remove from its ends. Cancelling a queued deposit deletes the request but leaves its key in the queue. `TransactionQueue.RequestQueue.cancelled` counts these dead keys, so `depositQueueLength()` and `isEmpty()` only count live requests. Fills drop dead keys as they pop past them.

Dead keys still cost gas when `processQueue` walks over them. `sanitizeDepositQueue(maxIterations)` removes the cancelled keys among the first `maxIterations` entries without changing queue order. Anyone can call it, and it does nothing when no cancellations are pending, so the planner should call it before every `processQueue`.

### Future work: migrate to a linked list

If audit scope and timeline allow, replace the deque inside `TransactionQueue` with a doubly linked list keyed by the existing request key (`controller`, `nonce`). A cancel would unlink its entry in O(1), dead keys would never exist, and fills would only touch live entries. The `cancelled` counte +  `sanitizeDepositQueue` can then be deleted.

The costs: roughly 25k more gas per queued request (two pointer slots per entry), a custom unaudited data structure that needs its own fuzz tests