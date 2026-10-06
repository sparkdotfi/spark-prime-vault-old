Viewed erc-7540.md:155-210
Viewed erc-7540.md:270-330

Here is a detailed breakdown of the issue with non-zero request IDs, a concrete walkthrough story of how it breaks with standard ERC-7540/4626 claims, what a full "Plan B" implementation entails, and how the clean deposit pipeline works without wasteful round trips.

---

### 1. The Core Disconnect in ERC-7540

The root of the issue lies in an asymmetry between **view functions** and **state-mutating claim functions** in the ERC-7540 specification:

- **View function:** [`claimableDepositRequest(uint256 requestId, address controller)`](file:///Users/michaeldeluca/Projects/sp-prime-vault/docs/erc-7540.md#L157-L181) accepts a specific `requestId`.
- **Claim function:** [`deposit(uint256 assets, address receiver, address controller)`](file:///Users/michaeldeluca/Projects/sp-prime-vault/docs/erc-7540.md#L318-L330) does **not** accept a `requestId`. It only takes `(assets, receiver, controller)`.

The authors of ERC-7540 acknowledged this tension explicitly in the standard's rationale ([L435](file:///Users/michaeldeluca/Projects/sp-prime-vault/docs/erc-7540.md#L435)):

> _"Certain Vaults, especially `requestId==0` cases, benefit from using the underlying ERC-4626 methods for claiming because there is no discrimination at the `requestId` level. This standard is written primarily with those use cases in mind. A future standard can optimize for nonzero request ID with support for claiming and transferring requests discriminated also with a `requestId`."_

---

### 2. Concrete Story: Alice and Request IDs 5 & 6

To see why returning non-zero request IDs causes accounting and interface headaches, consider the following story:

#### Step 1: Alice Submits Two Requests

- **Day 1:** Alice calls `requestDeposit(100 USDC, alice, alice)`.
    - The vault assigns queue slot / Request ID = **`5`**.
- **Day 2:** Alice calls `requestDeposit(200 USDC, alice, alice)`.
    - The vault assigns queue slot / Request ID = **`6`**.

#### Step 2: The Requests Get Processed

The rebalancer calls `processQueue`. Both requests are fulfilled:

- Request `5` (100 USDC) was converted to shares at an index rate of $1.00$ $\rightarrow$ **100 spPRIME owed**.
- Request `6` (200 USDC) was converted to shares at an index rate of $1.05$ $\rightarrow$ **190.47 spPRIME owed**.

#### Step 3: Off-chain UI / Integrator Inspects Alice's State

An integrator or wallet queries the ERC-7540 view functions:

- `claimableDepositRequest(5, alice)` returns `100 USDC`
- `claimableDepositRequest(6, alice)` returns `200 USDC`
- Total claimable: `300 USDC`

#### Step 4: Alice Claims Partial Assets

Alice wants to claim 100 USDC today. As mandated by ERC-7540 / ERC-4626, Alice calls:

```solidity
vault.deposit(100 USDC, alice, alice);
```

Notice: **Alice's transaction does not specify whether she is claiming Request `5` or Request `6`.**

#### Where the Crisis Happens:

1.  **Which ID's claimable balance decreases?**
    - When the UI next calls `claimableDepositRequest(5, alice)` and `claimableDepositRequest(6, alice)`, what must they return?
    - If the contract did not track Alice's IDs, it cannot update ID `5` to 0. If it reduces them pro-rata, ID `5` becomes 66.6 USDC and ID `6` becomes 133.3 USDC, which violates the premise that ID `5` was a discrete 100 USDC request.
2.  **Exchange Rate Blending vs Exact Rate:**
    - If the vault uses the current aggregate [`Settlement`](file:///Users/michaeldeluca/Projects/sp-prime-vault/src/Vault.sol#L456-L465) ledger:
        ```solidity
        shares = Math.mulDiv(settlement.sharesOwed, assets, settlement.depositedAssets);
        ```
        Alice receives a **blended** share payout ($100 \times \frac{290.47}{300} = 96.82$ shares). But if Request `5` was what was claimed, she was entitled to 100 shares! If Request `6` was claimed, she was entitled to 95.23 shares.
3.  **Dust / Griefing Vector:**
    - If the vault attempts to automatically draw down IDs in FIFO order (consuming ID 5 first, then ID 6), the contract must maintain a linked list or dynamic array of active claimable request IDs for Alice.
    - Anyone can call `requestDeposit(1 wei, alice, attacker)` on behalf of Alice. An attacker could flood Alice with hundreds of 1-wei requests, inflating Alice's claimable ID list so that Alice's subsequent `deposit(...)` call runs out of gas traversing them.

---

### 3. What "Plan B" Entails (Scope & Size)

To make non-zero ERC-7540 request IDs fully compliant and functional, the vault cannot use a simple aggregate per-controller [`Settlement`](file:///Users/michaeldeluca/Projects/sp-prime-vault/src/Vault.sol#L93) ledger. It must build a complete **per-request fulfillment and draw-down system**:

1.  **Storage per Request:**
    Instead of deleting or clearing a request when processed, every `requestId` must store its own settled state:
    ```solidity
    struct SettledRequest {
        address controller;
        uint256 depositedAssets;
        uint256 sharesOwed;
    }
    mapping(uint256 requestId => SettledRequest) public settledRequests;
    ```
2.  **Per-Controller Unclaimed Request Tracker:**
    Because standard ERC-4626 `deposit` does not accept a `requestId`, the contract must store an iterable queue/list of claimable IDs for every user:
    ```solidity
    mapping(address controller => EnumerableSet.UintSet) controllerClaimableIds;
    // or a custom doubly linked list of request IDs per controller
    ```
3.  **Iteration During Claim (`deposit` / `mint`):**
    When Alice calls `deposit(assets, ...)`, the vault must execute a while-loop across `controllerClaimableIds[alice]`:
    - Pop the oldest ID.
    - Deduct assets and shares from that specific ID's `SettledRequest`.
    - If partially consumed, leave remainder; if fully consumed, delete from set.
    - Repeat until `assets` is fulfilled.
4.  **Custom Non-Standard Claim Method:**
    To allow users to bypass looping if griefed with dust, you would need to introduce non-standard extensions like `depositById(uint256 requestId, uint256 assets, ...)`.
5.  **Scope & Complexity:**
    - **+150 to +250 lines of complex Solidity.**
    - Additional SSTOREs on every request fulfillment.
    - Significant gas overhead on every claim.
    - Added invariant fuzzing requirements for queue tracking.

---

### 4. Why Plan A is the Cleanest Pragmatic Solution

**Plan A** cleanly separates the **on-chain queue mechanics** from the **ERC-7540 standard interface**:

1.  **ERC-7540 Compatibility:**
    - `requestDeposit` and `requestRedeem` return `0`.
    - `pendingDepositRequest(0, controller)` and `claimableDepositRequest(0, controller)` aggregate per controller.
    - Standard ERC-4626 `deposit`/`mint` works cleanly with O(1) aggregate math, zero loops, and zero griefing surface.
2.  **Granular Queue Mechanics (What you actually wanted):**
    - The queue slot index is the **Vault Queue ID**.
    - When a request is submitted, the custom event `DepositQueued(controller, owner, queueId, amount)` is emitted with the exact slot index.
    - A public getter `depositQueueEntry(uint256 queueId)` lets any UI or user query their exact slot in the queue.
    - **Granular Cancel:** `cancelDepositRequest(uint256 queueId, address controller)` allows cancelling that specific entry in O(1).
    - **Broad Cancel:** `cancelDepositRequest(0, address controller)` triggers the O(1) watermark cancel to cancel all of the controller's pending requests at once.

You get all the ergonomics of slot-based IDs and granular cancelations without complicating the ERC-4626 claim path.

---

### 5. Clean Deposit Pipeline: "Allocate-Then-Split"

For the deposit pipeline, we want to eliminate multiple branching paths without paying for an expensive and wasteful round trip through the savings vault on every deposit.

Here is the **straight-line, 5-step pipeline** where every request follows the exact same sequence:

```solidity
function requestDeposit(uint256 assets, address controller, address owner)
    external
    whenNotPaused
    nonReentrant
    returns (uint256)
{
    // Step 1: Validation & Accrual (Standard)
    _validateDeposit(assets, controller, owner);
    _accrueInterest(_getStorage());

    // Step 2: Transfer Assets In
    IERC20(asset()).safeTransferFrom(owner, address(this), assets);

    // Step 3: Determine Instant vs Queued Split
    // If the queue is empty, up to available capacity can be filled immediately.
    // If the queue has items, slice is 0 (strict FIFO).
    uint256 slice = ($.depositQueue.pending == 0)
        ? Math.min(assets, _convertToAssets(availableCapacity(), Math.Rounding.Ceil))
        : 0;
    uint256 queued = assets - slice;

    // Step 4: Always Allocate a Queue ID
    uint256 id = $.depositQueue.reserve();

    // Step 5: Execute Determinate Actions (No branching divergences)
    if (slice > 0) {
        _creditClaimableDeposit($, controller, slice);
    }
    if (queued > 0) {
        uint256 savingsShares = _depositToSavings($, queued);
        $.depositQueue.store(id, Transaction(controller, 0, savingsShares));
    } else {
        // If 100% was instantly filled, mark this slot as already consumed
        $.depositQueue.consumed = uint128(id);
    }

    emit DepositRequest(controller, owner, 0, msg.sender, assets);
    emit DepositQueued(controller, owner, id, assets, slice);

    return 0;
}
```

#### Why this is clean:

1.  **No Savings Vault Round Trip:** Instant funds stay in the base asset and go directly to claimable deposits.
2.  **Single Sequence:** No early returns, no 3-way `if/else if/else` logic trees.
3.  **Uniform Queue ID:** Every deposit is assigned a monotonically increasing ID in the queue.
4.  **Preserves FIFO:** If `pending > 0`, `slice` is strictly 0—new deposits never bypass earlier queued depositors.

---

### 6. Status of Outstanding Decisions

1.  **Request ID Strategy:** Recommend proceeding with **Plan A** (Queue ID for events, views, and ERC-7887 cancels; ERC-7540 return value stays `0`).
2.  **Deposit Pipeline:** Adopt the **Allocate-Then-Split** pipeline above.
3.  **ProcessQueue Watermark (`maxId`):** Noted that this is a business decision being mulled over; we can leave the existing volume-based batching in place and introduce the watermark check later if desired.
