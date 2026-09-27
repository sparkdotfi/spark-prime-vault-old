# Redeem: through the Withdraw Queue

Someone is already waiting in the Withdraw Queue, or the vault does not hold enough idle base asset, so the redeem waits until Spark processes the queue.

```mermaid
sequenceDiagram
    actor User
    actor Spark as Spark Planner (Rebalancer)
    participant Vault as spPRIME Vault

    User->>Vault: requestRedeem (sends spPRIME shares)
    Note over Vault: Withdraw Queue exists or<br/>not enough idle base asset
    Vault->>Vault: Hold the shares in the vault's escrow
    Vault->>Vault: Add the request to the Withdraw Queue
    Note over User,Vault: Pending: the shares keep earning the vault's interest

    rect rgba(128, 128, 128, 0.15)
        Spark->>Vault: processQueue
        Note over Vault: Black box, see process-queue.md
    end

    Note over Vault: Escrowed shares burnt and<br/>the base asset owed set aside
    Note over User,Vault: Claimable
    User->>Vault: redeem
    Vault->>User: Base asset
    Note over User,Vault: Claimed
```

A redeem cannot be cancelled once it is in the Withdraw Queue.

`withdraw` claims the same way as `redeem`. Spark can claim on the user's behalf once the user sets Spark as their operator.
