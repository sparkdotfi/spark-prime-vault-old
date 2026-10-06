# Vault queue refactor review (revised)

Scope: [Vault.sol](file:///Users/michaeldeluca/Projects/sp-prime-vault/src/Vault.sol),
[TransactionQueue.sol](file:///Users/michaeldeluca/Projects/sp-prime-vault/src/libraries/TransactionQueue.sol),
[ERC-7540](file:///Users/michaeldeluca/Projects/sp-prime-vault/docs/erc-7540.md),
[ERC-7887](file:///Users/michaeldeluca/Projects/sp-prime-vault/docs/erc-7887.md).
Analysis only; no code was changed.

## What changed in this revision

| Your comment                                        | Effect                                                                                                    |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Want granular **and** broad cancel                  | Design in §5: cancel by queue ID, plus an O(1) per-controller "cancel all" watermark.                     |
| Redeem cancel is nice-to-have                       | §5.4: cheap once the machinery is shared. Recommended as phase 2.                                         |
| Guardian keeps compliance cancel                    | §5.3: separate entry point, credits a claimable bucket instead of pushing.                                |
| Disjoint ID spaces; can't tell what the spec allows | §3.1: **I overstated "not required" last time.** The text is ambiguous, and disjoint is the safe reading. |
| Global monotonic IDs enable watermarks              | §3.3: per-queue monotonic IDs already give you watermarks.                                                |
| Force every request through the queue               | §4: do it for redeems. For deposits there is a cost and a cheaper equivalent.                             |
| Every claim, even instant, gets an ID               | §3.2: this is where non-zero ERC-7540 IDs run into the claim path. Two plans.                             |

## 1. Verdicts

| #   | Suggestion                                                                 | Verdict                                                                                    |
| --- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| 1   | Hoist the deque; `entries` keyed by index; drop `sanitize` and `cancelled` | **Correct.**                                                                               |
| 2   | Peek-and-edit instead of pop-and-reinsert                                  | **Do it.** It deletes `pushFront`.                                                         |
| 3   | Request ID = queue slot, disjoint per operation type                       | **Good as a queue ID.** As the ERC-7540 `requestId` it needs a claim-side redesign (§3.2). |
| 4   | Force every request through one pipeline                                   | **Yes for redeems. For deposits, use the allocate-then-split form** (§4).                  |
| 5   | ERC-7887                                                                   | **Feasible**, including your granular and broad cancel.                                    |

---

## 2. Queue structure (unchanged conclusions, updated sketch)

OZ `Bytes32Deque` is `{uint128 _begin; uint128 _end; mapping(uint128 => bytes32) _data}`. `_data` holds a hash that only exists to look up `entries[hash]`, so collapse them. `sanitize` and `cancelled` go away:

- Cancel is O(1): delete the entry. `fill` skips deleted slots lazily.
- `sanitize` costs more per tombstone than `fill` does, because it pops every entry and pushes the survivors back.
- `isEmpty()` becomes `pending == 0`. Every live entry has `amount > 0`.
- `pending` lives in the queue struct and replaces `totalDepositQueueSavingsShares` and `totalWithdrawQueueShares`.

```solidity
struct Queue {
    uint128 consumed;   // highest slot removed from the front; slots are 1-based
    uint128 issued;     // highest slot ever assigned
    uint256 pending;    // sum of live amounts
    mapping(uint256 slot => Transaction) entries;   // Transaction = {controller, fee, amount}
}

function reserve(Queue storage q) internal returns (uint256 slot) { slot = ++q.issued; }

function store(Queue storage q, uint256 slot, Transaction memory t) internal {
    q.entries[slot] = t;
    q.pending += t.amount;
}

function push(Queue storage q, Transaction memory t) internal returns (uint256 slot) {
    store(q, slot = reserve(q), t);
}

function cancel(Queue storage q, uint256 slot) internal returns (Transaction memory t) {
    t = q.entries[slot];
    if (t.controller == address(0)) revert NotQueued(slot);  // never issued, filled, or cancelled
    delete q.entries[slot];
    q.pending -= t.amount;
}

/// First live entry; lazily advances past deleted slots.
function peek(Queue storage q) internal returns (uint256 slot, Transaction storage t) {
    while (q.consumed < q.issued) {
        slot = q.consumed + 1;
        t = q.entries[slot];
        if (t.controller != address(0)) return (slot, t);
        ++q.consumed;
    }
    revert QueueEmpty();
}

/// Consume `amount` from the entry returned by `peek`.
function take(Queue storage q, uint256 slot, uint256 amount) internal {
    Transaction storage t = q.entries[slot];
    q.pending -= amount;
    if (t.amount == amount) { delete q.entries[slot]; ++q.consumed; }
    else                    { t.amount -= amount; }
}

/// Discard the entry returned by `peek` without touching `pending` (already removed by a broad cancel).
function drop(Queue storage q, uint256 slot) internal { delete q.entries[slot]; ++q.consumed; }
```

## 2b. Peek-and-edit

```solidity
function _fillWithdraws(uint256 shares) internal {
    VaultStorage storage $ = _getStorage();
    Queue storage q = $.withdrawQueue;
    uint256 filled;
    while (shares > 0) {
        (uint256 slot, Transaction storage t) = q.peek();         // reverts QueueEmpty
        if (slot <= $.ledger[t.controller].cancelledRedeemUpTo) { q.drop(slot); continue; }  // §5.2
        uint256 fill = Math.min(t.amount, shares);
        _creditClaimableWithdraw(t.controller, fill, t.fee);
        q.take(slot, fill);
        shares -= fill; filled += fill;
    }
    if (filled > 0) _burn(address(this), filled);
}
```

- One `min` replaces the three branches. `pushFront` disappears and the queue becomes a plain FIFO whose head can shrink.
- The slot is stable by construction. Pop-then-`pushFront` only returned to the same slot because `begin - 1 == slot` after the pop, which is an invariant you would have to test.
- `_fillUnbounded` goes away: "fill all" is `shares = q.pending`. Keep the `fillAll` branch, since `convertToShares(tradeVolume)` can floor to 1 wei under the total.
- The `bool instantClaim` flag goes away. Queue bookkeeping moves into `take`, and `_credit…` only credits. Credit functions take `(controller, amount, fee)`, not a `Transaction memory`.

---

## 3. Request IDs

### 3.1 Disjoint ID spaces: what the spec says

I said last time that I found no requirement that deposit and redeem IDs be disjoint, and that the prefix was optional. **That overstated it.** The spec is ambiguous:

- [L86](file:///Users/michaeldeluca/Projects/sp-prime-vault/docs/erc-7540.md#L86): "Requests of the same `requestId` MUST be fungible… transition from Pending to Claimable at the same time and receive the same exchange rate." It does not scope this by operation type, and a deposit and a redeem can't satisfy it together.
- [L90](file:///Users/michaeldeluca/Projects/sp-prime-vault/docs/erc-7540.md#L90): "If a Vault returns `0` for the `requestId` of _any_ request, it MUST return `0` for _all_ requests." This is explicitly vault-wide across `requestDeposit` and `requestRedeem`, which supports reading the ID namespace as shared.

I can't prove overlap is forbidden, but the conservative reading is that it is. So disjoint is the right call. It also costs almost nothing.

**Encoding.** Use a type tag in the high bits rather than an additive offset:

```solidity
uint256 constant REDEEM_FLAG = 1 << 128;
depositId = slot;                 // 1 .. 2^128-1
redeemId  = REDEEM_FLAG | slot;   // 2^128+1 ..
slot = uint128(id);  isRedeem = (id >> 128) != 0;
```

- IDs are non-zero (slots are 1-based), disjoint, and monotonic per queue, and they decode in one shift.
- Your `type(uint128).max + end` also works if `end` is 1-based. The flag is just easier to read in hex.
- A deposit ID passed to a redeem function decodes as "not found". Views return 0 and never revert.

### 3.2 The claim-side problem

Your IDs resolve cleanly to a queue slot for **pending** and **cancel**. They don't resolve for **claimable**.

- With non-zero IDs, `claimableDepositRequest(id, controller)` and `claimableRedeemRequest(id, controller)` must report _that ID's_ claimable amount.
- Today claimable state is aggregated per controller (`Settlement`) and claimed through ERC-4626 `deposit`/`mint`/`redeem`/`withdraw`, which take no ID.
- The spec concedes this ([L435](file:///Users/michaeldeluca/Projects/sp-prime-vault/docs/erc-7540.md#L435)): the 4626 claim path is written for `requestId == 0`, and claiming by non-zero ID is for a future standard.
- With IDs 5 and 6 each claimable, `deposit(100, …)` has no defined answer to "which ID did I draw from?".
- I looked for an O(1) FIFO attribution trick. Claims at different fill rates mean claiming X assets spans requests with different share rates, so it needs iteration, and the aggregate pro-rata rule would stop matching the per-ID numbers.

Two coherent ways out:

|                                  | **Plan A: slot IDs are vault-level queue IDs; ERC-7540 `requestId` stays 0**               | **Plan B: slot IDs are the ERC-7540 `requestId`**                                                                                                                                            |
| -------------------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Claim path                       | Unchanged (aggregate, 4626)                                                                | Per-ID claimable state, plus a defined draw-down rule for 4626 claims                                                                                                                        |
| Extra storage                    | A watermark per controller and a cancel bucket per controller                              | Claimable per ID, plus a per-controller ordered list of unclaimed IDs (≈ one extra SSTORE per request)                                                                                       |
| Spam surface                     | None new                                                                                   | `requestDeposit(controller = victim)` is open to anyone, so dust requests would lengthen the victim's list, and the victim's aggregate claim walks it (they can bypass it by claiming by ID) |
| ERC-7540                         | Valid (`0` everywhere)                                                                     | Valid if the claim semantics are defined carefully                                                                                                                                           |
| ERC-7887                         | `0` means "all pending". A non-zero ID is a documented extension that cancels one request. | Natural                                                                                                                                                                                      |
| Code size                        | Smaller than today                                                                         | **Larger** than today. This is a claim-model redesign                                                                                                                                        |
| Slot-based getter / ID in events | Yes, via `DepositQueued` / `WithdrawQueued` and `request(id)`                              | Yes, in `DepositRequest` / `RedeemRequest` as well                                                                                                                                           |

**Recommendation: Plan A.** It gets you the granular and broad cancel, the unique per-request IDs, the slot getter, and the watermarks without touching claims. What you give up is the non-zero ID in the ERC-7540 `DepositRequest` / `RedeemRequest` events, which would carry `0`, and `claimable*Request(id, …)` being per request. If integrators need non-zero ERC-7540 IDs, Plan B is a separate project. Don't mix it into this refactor.

Under Plan A the disjointness question is moot for ERC-7540, because ERC-7540 IDs are all 0. I'd still tag slots, so one `request(id)` getter and one cancel namespace work across both queues, which is your original motivation.

### 3.3 Watermarks and a global counter

You don't need a single global counter for watermarks. Per-queue monotonic slots already give you "up to ID N" semantics within each queue, and the type tag tells you which queue.

A shared counter would solve disjointness trivially, but slots would no longer be contiguous per queue. Each queue would then need a `next` pointer per entry. That is about the same extra cost as the README's linked-list estimate (≈ 25k gas per request).

Uses of a watermark:

- **Cancel all** pending for a controller, in O(1) (§5.2).
- **Process up to ID**: `processQueue(tradeVolume, maxId)` stops at the watermark.
    - The rebalancer can pin work to a snapshot it planned against.
    - It also bounds tombstone-walking gas.
    - Partial fills without enough queue up to the watermark would stop instead of reverting `PartialFillFailure`, so the exact-fill guarantee needs a decision.

---

## 4. Single request pipeline

### Redeems: do it literally

Escrow shares, push, then fill if the queue was empty. This reuses `_fillWithdraws`, which also burns, so the instant branch (L566–602) disappears:

```solidity
_transfer(owner, address(this), shares);
bool wasEmpty = q.pending == 0;
uint256 id = q.push(Transaction(controller, $.withdrawFee, shares));
emit WithdrawQueued(controller, owner, id, shares);              // + RedeemRequest(…, 0, …) in Plan A
if (wasEmpty) _fillWithdraws(_instantShares(shares));            // 0 if no liquid assets

function _instantShares(uint256 shares) internal view returns (uint256) {
    int256 liquid = availableLiquidAssets();
    if (liquid <= 0) return 0;
    return liquid.toUint256() >= convertToAssets(shares) ? shares : convertToShares(liquid.toUint256());
}
```

I kept the existing `liquid >= convertToAssets(shares)` test rather than `convertToShares(liquid) >= shares`. They can differ by 1 wei at the boundary, and this preserves current behavior. The `wasEmpty` guard preserves FIFO fairness: a request never jumps an older one.

### Deposits: literal "push then pop" has a real cost

Queue entries are denominated in **savings-vault shares**. A queued deposit is put into the savings vault immediately, so the depositor earns savings yield while waiting. Forcing an instant deposit through the same path means:

1. `savingsVault.deposit(assets)`
2. push
3. fill
4. `savingsVault.redeem(shares)`
5. credit `convertToAssets(shares)`

Consequences:

- Two extra external calls on every deposit.
- Every deposit now depends on the savings vault being deposit-able and redeem-able. That is a liveness coupling the instant path doesn't have today.
- A wei or so of rounding dust per request, since credited assets are `convertToAssets(shares)` and floor.
- Pushing then deleting the entry in one transaction is about 0 → x → 0 on its slots. Net gas metering refunds most of it, but refunds are capped at 20% of the transaction's gas. Expect tens of thousands of gas of overhead per instant request; measure with `forge snapshot`.

**Recommended: allocate-then-split.** It gives the same single, always-the-same sequence of calls without the round trip:

```solidity
uint256 id    = q.reserve();                                        // every request gets an ID
uint256 slice = q.pending == 0 ? Math.min(assets, capacityAssets) : 0;
if (slice > 0) _creditClaimableDeposit(controller, slice);          // instant slice (0 if the queue is non-empty)
uint256 rest  = assets - slice;
if (rest > 0) q.store(id, Transaction(controller, 0, _depositToSavings(rest)));
else          q.consumed = id;    // only reachable when the queue was empty, so consumed == id - 1
emit DepositQueued(controller, owner, id, assets, slice);
```

There are no more three branches (`!isEmpty || capacity == 0` / `assets > capacity` / else), no flag, and no early returns. Every request, even a fully instant one, gets a queue ID. Redeems do the same shape if you prefer symmetry: compute the instant slice, credit it, and store the rest.

If the savings vault is always deep and liquid and you want a literal single pipeline, the round-trip version is acceptable. I'd measure it first.

---

## 5. Cancelation

### 5.1 Granular: by queue ID (O(1))

```solidity
function cancelDepositRequest(uint256 requestId, address controller)  // ERC-7887 signature
```

- `requestId != 0`: cancel that one queue entry. Check that its `controller` matches and that the caller is the controller or an operator. This is a documented extension.
- `requestId == 0`: cancel all pending for `controller` (§5.2). This is spec-correct for a vault whose ERC-7540 IDs are all 0.
- For batches, `cancelDepositRequests(uint256[] ids, address controller)` is O(k) and each cancel is O(1).

Either way, cancel credits the controller's **claimable-cancel bucket** (savings shares). `claimCancelDepositRequest(0, receiver, controller)` then pulls it by redeeming from the savings vault. That keeps the "pull, don't push" requirement ([L46](file:///Users/michaeldeluca/Projects/sp-prime-vault/docs/erc-7887.md#L46)) and means cancel can't be blocked by savings-vault illiquidity. The bucket must count as reserved in the free-savings-shares check in `withdrawFromSavings`.

### 5.2 Broad: per-controller watermark (O(1))

```solidity
// Settlement gains: uint128 cancelledDepositUpTo; uint128 cancelledRedeemUpTo;
$.ledger[c].cancelledDepositUpTo = q.issued;                // everything currently queued is cancelled
uint256 amount = $.ledger[c].pendingSavingsShares;          // existing aggregate
q.pending -= amount; $.ledger[c].pendingSavingsShares = 0;
$.ledger[c].claimableCancelSavingsShares += amount;
```

- `fill` treats `slot <= ledger[controller].cancelledDepositUpTo` as dead and `drop`s it (§2b). This replaces the per-entry epoch I proposed earlier, so no extra field is needed.
- A partially filled head entry is handled too: its remainder is part of `pendingSavingsShares`.
- **Limitation:** "cancel all of this controller's requests with ID ≤ W" for an arbitrary `W < issued` needs the sum of just those entries, and the vault can't enumerate a controller's entries. So the O(1) forms are _single ID_ and _all pending_. Arbitrary-W is the batch function in §5.1, or an off-chain-enumerated ID list.

### 5.3 Guardian

Separate entry points, e.g. `guardianCancelDeposit(uint256 requestId, address controller)` with the same `requestId` semantics (`0` means all pending). Rationale: ERC-7887 limits `cancel*` to the controller or an operator.

They credit the controller's claimable-cancel bucket, which the controller then claims to a `receiver` of their choosing. A compromised Guardian can no longer redirect refunds to the owner or anyone else. This is strictly safer than today.

### 5.4 Redeem cancel (`cancelRedeemRequest`)

Cheap once the machinery is shared, because shares are already escrowed in the vault and still count toward supply and capacity:

- delete the entry, `q.pending -= amount`, `ledger.pendingSharesOut -= amount`;
- `ledger.claimableCancelRedeemShares += amount`;
- `claimCancelRedeemRequest` transfers shares from the vault to `receiver`.

Notes:

- The withdraw fee is a snapshot per request, so a cancel doesn't touch it.
- The rebalancer planner sees `totalPendingWithdraws` shrink, which is already handled by `maxTradeVolume` clamping.
- The README currently lists "Redemption requests cannot be cancelled" as a property. Decide whether that was a policy or just scope.

I recommend it as phase 2. The interface IDs are independent (`0x8bf840e3` deposit side, `0xe76cffc7` redeem side), so the deposit side can ship first.

### 5.5 ERC-7887 mapping

| Spec                                                | Plan                                                                                                                                                                                                    |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cancelDepositRequest(requestId, controller)`       | §5.1. Controller or operator only.                                                                                                                                                                      |
| `pendingCancelDepositRequest(id, c)`                | Always `false`, since cancel is synchronous and never leaves a pending state.                                                                                                                           |
| `claimableCancelDepositRequest(id, c)`              | `savingsVault.convertToAssets(claimableCancelSavingsShares[c])`                                                                                                                                         |
| `claimCancelDepositRequest(id, receiver, c)`        | Redeem from the savings vault to `receiver`. **Not** `whenNotPaused`, to preserve "cancellation keeps working while paused". A refund in savings shares is unaffected by `setTotalAssets` loss booking. |
| Events `CancelDepositRequest`, `CancelDepositClaim` | Replace `DepositRequestCancelled`. A broad cancel emits `requestId = 0`.                                                                                                                                |
| ERC-165 `0x8bf840e3`                                | Use `type(IERC7887DepositCancel).interfaceId` rather than a magic constant.                                                                                                                             |
| "New requests blocked while cancel is Pending"      | Vacuous, because cancel is never pending.                                                                                                                                                               |

---

## 6. Other simplifications

- **`Transaction`** becomes `{address controller; uint16 fee; uint256 amount}`, two slots instead of five, with `nonce` and `owner` dropped. `owner` only appears in the request event. This is a behavior change: the owner loses the right to cancel or receive the refund, since refunds go to the `receiver` the controller names.
- **Queue getters.** `depositQueueLength`, `withdrawQueueLength` (one subtracts cancelled, the other doesn't), `depositQueueHead`, `withdrawQueueHead` and `front` (an O(n) scan) are replaced by `consumed`/`issued` and an `entries(id)` getter. Update the tests that use `*QueueHead()`: [Withdraw.unit.t.sol](file:///Users/michaeldeluca/Projects/sp-prime-vault/test/Withdraw.unit.t.sol), [Deposit.unit.t.sol](file:///Users/michaeldeluca/Projects/sp-prime-vault/test/Deposit.unit.t.sol), [QueueSolvency.t.sol](file:///Users/michaeldeluca/Projects/sp-prime-vault/test/QueueSolvency.t.sol).
- **Drop `_accrueInterest` in cancel.** It doesn't touch vault index state.
- **Operators on request.** `requestDeposit` and `requestRedeem` reject `msg.sender != owner` outright ([L353](file:///Users/michaeldeluca/Projects/sp-prime-vault/src/Vault.sol#L353), [L551](file:///Users/michaeldeluca/Projects/sp-prime-vault/src/Vault.sol#L551)). The spec says operator approval is the way around that ([L106](file:///Users/michaeldeluca/Projects/sp-prime-vault/docs/erc-7540.md#L106)), so this is stricter than the standard.
- **README.** The "Cancelled Deposit Entries" and "migrate to a linked list" sections become obsolete.
- **Storage layout.** Moving totals into the queue struct and adding ledger fields changes `VaultStorage`. That is free if the vault isn't deployed yet.

## 7. Decisions needed

1. **Plan A or Plan B** (§3.2). Is it acceptable for the ERC-7540 `requestId` in events to stay `0`, with the unique ID surfaced through `DepositQueued` / `WithdrawQueued`, the cancel and `request(id)` views, and the `requestId != 0` cancel extension? If integrators require non-zero ERC-7540 IDs, Plan B is a separate project.
2. **Deposit pipeline** (§4): allocate-then-split (recommended), or the literal push-and-pop with a savings-vault round trip on every deposit?
3. **`processQueue` watermark** (§3.3): do you want a `maxId` parameter, and what should happen when the watermark stops a fill short of the requested volume?
