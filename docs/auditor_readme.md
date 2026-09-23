### `totalAssets` only ever increases *Shares are never burnt* 

We never burn LP tokens on redeem, or reduce totalAssets. Instead the vault itself holds these shares, and allocates them to future depositors. `totalAssets` becomes monotonically increasing by nature, with a ceiling at `maximumCapacity`

### `take()` has no solvency guard
`take` transfers any amount up to the full base-asset balance, with no check against `claimableWithdrawTotal()`. These assets are already promised to users, and will result in revert with `Insolvency` at claim time. 

The `take()` function is access controlled to the PAU, I'd still suggest adding some insolvency measures by preventing to dip into the claimable amounts. see `test_takeAfterMatching_makesVaultInsolvent`

### `setOperator` stores a single operator
To simplify the model and allow Spark to rotate keys via the `AdministeredAgent`, a single Operator entry is permitted per user. This is set once by the user before they begin their Vault Journey, and Spark rotates it's keys that interact with the address in question.

## Matched deposits are unclaimable until redeemers claim first
A hard business requirement from Spark was to allow accruing yield whilst waiting in the queue. This means a withdrawers shares are reclaimed/distributed when they CLAIM. 

Each withdrawer that doesn't claim increases the amount of assets not available to depositors when they claim.

Spark will be set as the operator and will claim on behalf of the users. It is Sparks responsibility to claim on behalf of users after queuing processing (or atleast, withdrawers) to produce liquidity for trade volume.

Note for auditor: It is possible for a user to NOT set Spark as an operator, in which case, they can potentially never claim to cause a grief attack against the depositors but this comes at the expense of their own funds being locked and becomes economomically infeasible for significant amounts.

### `requestRedeem` and `requestDeposit` are Operator barred functions
The ERC 7540 spec defines that a user set operator should be able to perform requests on behalf of the user, the contract violates this spec. The blast radius of this spec violation is Spark itself (as Spark is the only Operator that should ever be set). This is a known trade off in order to guarantee Spark can only perform claims on behalf of users.

Note for auditor: A `controller` could not be used, as the 7540 spec clearly defines either a user or a controller can perform a clain, never both. The controller spec should not be violated as users may automated or delegate their request lifecycles, we opted to loosely follow Operator spec instead.


### `processQueue` reverts if capacity exceeds liquidity
The curator can define a `capacity`, the amount of volume in base asset units that both queues should consume.
The `capacity` cannot be larger than the minimum of total deposit liquidity and total withdraw liquidity.
The liquidity is determined by the total pending value of the queue + total idle liquidity (that would have been instant claimed if no queues existed, once a queue exists, this idle liquidity is consumed by `processQueue`)

## `processQueue` loop is bounded by capacity, not by elements
The curator defines exactly how much volume should be traded between the deposit and withdraw queues, and iteration occurs until this volume is fulfilled or queue depletes. 

Note for auditor: It has already been discussed that a minimum deposit + withdraw amount must be defined, to prevent users bloating queue length.