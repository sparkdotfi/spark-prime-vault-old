# Redeem: instant claim

No one is waiting in the Withdraw Queue and the vault holds enough idle base asset, so the redeem is claimable straight away.

```mermaid
sequenceDiagram
    actor User
    participant Vault as spPRIME Vault

    User->>Vault: requestRedeem (sends spPRIME shares)
    Note over Vault: No Withdraw Queue and enough<br/>idle base asset
    Vault->>Vault: Burn the shares
    Vault->>Vault: Set aside the base asset owed
    Note over User,Vault: Instant Claim
    User->>Vault: redeem
    Vault->>User: Base asset
    Note over User,Vault: Claimed
```

Instant redeems are paid from the vault's idle base asset only, never from the Savings Vault.

If the idle base asset covers only part of the request, that part follows this flow and the rest [joins the Withdraw Queue](redeem-queued.md).

`withdraw` claims the same way as `redeem`. Spark can claim on the user's behalf once the user sets Spark as their operator.
