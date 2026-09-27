# Deposit: instant claim

No one is waiting in the Deposit Queue and the vault is below its max capacity, so the deposit is claimable straight away.

```mermaid
sequenceDiagram
    actor User
    participant Vault as spPRIME Vault

    User->>Vault: requestDeposit (sends base asset)
    Note over Vault: No Deposit Queue and room<br/>under the max capacity
    Vault->>Vault: Mint spPRIME shares into the vault's escrow
    Note over Vault: The base asset stays in the vault<br/>as idle liquidity
    Note over User,Vault: Instant Claim
    User->>Vault: deposit
    Vault->>User: spPRIME shares from the escrow
    Note over User,Vault: Claimed
```

If the room under the max capacity covers only part of the request, that part follows this flow and the rest [joins the Deposit Queue](deposit-queued.md).

`mint` claims the same way as `deposit`. Spark can claim on the user's behalf once the user sets Spark as their operator.
