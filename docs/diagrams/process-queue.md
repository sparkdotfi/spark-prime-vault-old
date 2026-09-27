# processQueue

Spark matches the waiting redeems against the waiting deposits. `tradeVolume` is how much base asset value Spark wants to settle in this call.

```mermaid
sequenceDiagram
    actor Spark as Spark Planner (Rebalancer)
    participant Vault as spPRIME Vault
    participant Savings as Savings Vault

    Spark->>Vault: processQueue(tradeVolume)
    Vault->>Vault: Accrue interest
    Note over Vault: Rejected if tradeVolume is more<br/>than the vault can settle

    loop Withdraw Queue, oldest first, up to tradeVolume
        Vault->>Vault: Mark the redeem Claimable at the current share value
    end
    Vault->>Vault: Burn all the matched escrowed shares at once
    Note over Vault: The burn makes room under<br/>the max capacity for the deposits

    loop Deposit Queue, oldest first, up to tradeVolume
        Vault->>Vault: Mark the deposit Claimable at the current savings share value
    end
    Vault->>Vault: Mint all their spPRIME shares into the vault's escrow at once
    Vault->>Savings: Redeem the matched savings shares
    Savings->>Vault: Base asset
    Note over Vault: This base asset pays the<br/>redeems matched above

    Note over Vault: Rejected if the vault owes more base asset<br/>than it holds, or spPRIME supply is above<br/>the max capacity
```

The Withdraw Queue always goes first, because its burn frees room under the max capacity for the deposit mints.

The last request matched in each queue can be partly filled. The rest of it stays at the front of its queue for the next call.

Requests stop earning yield once they are Claimable. The value each user will claim is fixed at this point.

A `tradeVolume` is rejected when it is more than either:
- the idle base asset plus the value of the Deposit Queue, or
- the value of the Withdraw Queue plus the room left under the max capacity.

`maxTradeVolume()` returns the largest `tradeVolume` that passes both checks.
