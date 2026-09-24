### Mint and Burns

Redeemed shares are burned. Shares leave the owner's custody on
`requestRedeem` and are escrowed by the vault while the request is Pending; they are
burned at the moment the request becomes Claimable. Queue fills burn once for the whole
batch, costing O(1) always. 

The vault never holds share inventory past the fulfillment lifecycle and invariant `balanceOf(address(this)) == totalPendingWithdraws()` should hold

The Withdraw Queue is always processed before the Deposit Queue. Because the burn reduces supply, it also avails capacity allowing Deposit Queue claims to directly mint.

`convertToAssets` is calculated by the index, which monotonically increases over time to track total input principle + yield. This means over time capacity will be reached, and newer deposits will be queued. At that point, `processQueue` must be called by the curator to fulfill deposit demand through withdraw demand.

If no withdraw demand exists, curator may increase the vault capacity allowing for more `totalMintableShares`, and then call `processQueue`.

Note that capacity tracks accrued yield, since the index feeds `convertToAssets`. A vault sitting at its capacity will start to queue deposits as the index climbs, and the curator must raise the capacity or call processQueue.

### `take()` has no solvency guard
`take` transfers any amount up to the full base-asset balance, with no check against `claimableWithdrawTotal()`. These assets are already promised to users, and will result in revert with `Insolvency` at claim time. 

The `take()` function is access controlled to the PAU, It was suggested to Spark to add insolvency safe guards but it was decided they want full control via PAU over funds. `test_takeAfterMatching_makesVaultInsolvent`

### `setOperator` stores a single operator
To simplify the model and allow Spark to rotate keys via the `AdministeredAgent`, a single Operator entry is permitted per user. This is set once by the user before they begin their Vault Journey, and Spark rotates it's keys that interact with the address in question.

## Claimable redemptions are paid at the rate during their processQueue execution

When a request becomes Claimable the vault records the asset value owed
(`Settlement.assetsOut`) alongside the shares burnt (`Settlement.sharesOut`)

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
The ERC 7540 spec defines that a user set operator should be able to perform requests on behalf of the user, the contract violates this spec. The blast radius of this spec violation is Spark itself (as Spark is the only Operator that should ever be set). This is a known trade off in order to guarantee Spark can only perform claims on behalf of users.

Note for auditor: A `controller` could not be used, as the 7540 spec clearly defines either a user or a controller can perform a clain, never both. The controller spec should not be violated as users may automated or delegate their request lifecycles, we opted to loosely follow Operator spec instead.


### `processQueue` reverts if capacity exceeds liquidity
The curator can define a `capacity`, the amount of volume in base asset units that both queues should consume.
The `capacity` cannot be larger than the minimum of total deposit liquidity and total withdraw liquidity.
The liquidity is determined by the total pending value of the queue + total idle liquidity (that would have been instant claimed if no queues existed, once a queue exists, this idle liquidity is consumed by `processQueue`)

## `processQueue` loop is bounded by capacity, not by elements
The curator defines exactly how much volume should be traded between the deposit and withdraw queues, and iteration occurs until this volume is fulfilled or queue depletes. 

Note for auditor: It has already been discussed that a minimum deposit + withdraw amount must be defined, to prevent users bloating queue length.