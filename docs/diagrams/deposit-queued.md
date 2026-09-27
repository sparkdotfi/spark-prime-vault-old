# Deposit: through the Deposit Queue

Someone is already waiting in the Deposit Queue, or the vault is at its max capacity, so the deposit waits in the Savings Vault until Spark processes the queue.

```mermaid
sequenceDiagram
    actor User
    actor Spark as Spark Planner (Rebalancer)
    participant Vault as spPRIME Vault
    participant Savings as Savings Vault

    User->>Vault: requestDeposit (sends base asset)
    Note over Vault: Deposit Queue exists or<br/>the vault is at max capacity
    Vault->>Savings: Deposit the base asset
    Savings->>Vault: Savings shares
    Vault->>Vault: Add the request to the Deposit Queue
    Note over User,Savings: Pending: earns the Savings Vault yield while waiting

    rect rgba(128, 128, 128, 0.15)
        Spark->>Vault: processQueue
        Note over Vault,Savings: Black box, see process-queue.md
    end

    Note over Vault: spPRIME shares minted into<br/>the vault's escrow
    Note over User,Savings: Claimable
    User->>Vault: deposit
    Vault->>User: spPRIME shares from the escrow
    Note over User,Savings: Claimed
```

While the request is Pending, the user can cancel it and receive the base asset back from the Savings Vault, including the yield earned while waiting.

`mint` claims the same way as `deposit`. Spark can claim on the user's behalf once the user sets Spark as their operator.
