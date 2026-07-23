<div align="center">

# NovaCont Lite

**A minimal, non-custodial escrow contract for TON, accessible as a Telegram Mini App.**

Native TON. Deterministic timeouts. No custodian, ever.

[![License: PolyForm Shield 1.0.0](https://img.shields.io/badge/license-PolyForm%20Shield%201.0.0-blue.svg)](./LICENSE)
[![Network: TON](https://img.shields.io/badge/network-TON-0098EA.svg)](https://ton.org)
[![Language: Tact](https://img.shields.io/badge/language-Tact-1a1a1a.svg)](https://tact-lang.org)
[![Audit: Unaudited](https://img.shields.io/badge/audit-unaudited-orange.svg)](#security)

[Documentation](https://novacont.gitbook.io/nova-docs) · [Telegram Bot](https://t.me/NovaCont_Lite_bot) · [Security](./SECURITY.md) · [Contributing](./CONTRIBUTING.md)

</div>

---

## Project Status

NovaCont Lite is **live on TON** and accessible through [@NovaCont_Lite_bot](https://t.me/NovaCont_Lite_bot) on Telegram. The contract is at **v1.1.1**.

Dispute resolution is **handled by a designated support team by design**, there is no jury system here. That's a deliberate choice, not a missing feature: on TON, simplicity is prioritized for a small-scale start. If you need decentralized dispute resolution, [NovaCont on Base](https://github.com/nova-cyber-and-technology/novacont) is the protocol with that capability.

The contract has **not completed a formal third-party audit**. It has been through two rounds of manual review and static analysis with Misti, see [Security](#security) before committing significant funds.

---

## Overview

NovaCont Lite locks TON in a smart contract until an agreement completes, then releases it according to rules fixed at creation time. No individual, company, or entity, including NOVA, can unilaterally move, freeze, or redirect locked funds. The contract releases them only when a defined condition is met: approval, rejection, cancellation, timeout, or dispute resolution.

Where the main NovaCont protocol is built for higher-value agreements that may need decentralized arbitration, Lite is built for the opposite case: fast, low-value agreements between people who are already talking to each other on Telegram, and who want escrow without leaving the app or installing a browser extension.

---

## How It Differs From NovaCont

| | NovaCont | NovaCont Lite |
|---|---|---|
| Chain | Base (Ethereum L2) | TON |
| Language | Solidity | Tact |
| Access | Web dApp | Telegram Mini App |
| Currency | ETH / USDT | Native TON |
| Dispute resolution | Admin or NovaJury | Support team |
| Extra deposit threshold | $200 (oracle-priced) | 10 TON (no oracle) |
| Wallet | MetaMask / WalletConnect | TonConnect |

The absence of an oracle in Lite is worth noting: the collateral threshold is denominated in TON itself, not USD, which removes an entire class of dependency and failure mode at the cost of the threshold's fiat value moving with the TON price.

---

## Core Principles

- **Non-custodial by construction.** Locked TON lives at the contract address, not in any NOVA-controlled wallet.
- **Deterministic settlement.** Every state transition and its outcome is fixed in contract logic, not decided case by case.
- **No path to permanently stuck funds.** A provider can claim payment via timeout if the client goes silent; a client is refunded if the provider never accepts.
- **Minimal by choice.** No Jettons, no oracle, no jury. Each of those is a dependency and an attack surface; Lite does without them on purpose.
- **Honest about centralization.** Disputes here are resolved by a designated support team rather than an independent juror pool, and this README says so rather than describing Lite as fully decentralized.

---

## Features

- Non-custodial escrow with on-chain TON locking
- Adaptive collateral: agreements under 10 TON require a 1.25x deposit (the surplus is refundable, never paid to the provider)
- 3% platform fee, deducted at settlement from the provider's payment
- 7-day review window after delivery, with a provider-claimable timeout
- Configurable accept and delivery deadlines, specified in days plus hours
- Dedicated support pool with round-robin assignment: when a dispute is raised, the next support member in rotation is assigned to it on-chain, so no single reviewer is a bottleneck
- Proportional dispute resolution via basis points, a reviewer can split funds anywhere between 0 and 100%, not just all-or-nothing
- On-chain resolution reasoning, every dispute verdict is stored with its stated reason and is publicly queryable

---

## Escrow Lifecycle

```
Created ──accept──> Accepted ──deliver──> Delivered ──release──> Completed
   │                    │                     │
   │ reject             │ cancel              │ claimTimeout (after 7 days)
   │ cancel             │                     │        └────────> Completed
   ▼                    ▼                     │
Cancelled          Cancelled             dispute
                        │                     │
                        └──── dispute ────────┤
                                              ▼
                                          Disputed ──resolve──> Completed
```

The six on-chain states are `Created`, `Accepted`, `Delivered`, `Completed`, `Cancelled`, and `Disputed`.

- **Created**: the client has locked funds; the provider can accept or reject, and the client can cancel for a full refund.
- **Accepted**: the delivery countdown starts. Either party can still raise a dispute from here.
- **Delivered**: the provider has submitted an evidence URL and the client's 7-day review window opens. The client can approve or dispute; if they do neither, the provider can claim the timeout.
- **Completed / Cancelled**: terminal. Funds have been distributed.
- **Disputed**: normal flow stops. The support member assigned at dispute time resolves it with a `clientShareBps` split and a stated reason.

Every branch terminates. There is no reachable state where funds have no defined path out.

---

## Contract Constants

Read directly from `contracts/NovaCont_Lite.tact`:

| Constant | Value | Meaning |
|---|---|---|
| `PLATFORM_FEE_BPS` | 300 | 3% platform fee |
| `EXTRA_DEPOSIT_THRESHOLD` | 10 TON | Below this, a 1.25x deposit is required |
| `REVIEW_TIMEOUT` | 7 days | Client review window after delivery |
| `STORAGE_RESERVE` | 0.05 TON | Reserved per transfer to keep the contract rent-solvent on TON |

`STORAGE_RESERVE` exists because TON charges storage rent; without reserving a small amount per outbound transfer, a contract can eventually be frozen and its data lost. This is a TON-specific concern with no equivalent on Base.

---

## Repository Structure

```
contracts/
  NovaCont_Lite.tact   The escrow contract
```

The Telegram Mini App frontend and bot backend are not published in this repository.

---

## Integration

Tact generates TypeScript wrappers at build time, so integrating doesn't require a separate SDK. Compile the contract, then use the generated wrapper with [`@ton/ton`](https://github.com/ton-org/ton):

```ts
import { TonClient, WalletContractV4, internal, toNano } from "@ton/ton";
import { NovaCont_Lite } from "./build/NovaCont_Lite";

const client = new TonClient({ endpoint: "<your TON RPC endpoint>" });
const escrow = client.open(
  NovaCont_Lite.fromAddress(CONTRACT_ADDRESS)
);

// Read state
const count = await escrow.getGetEscrowCount();
const data = await escrow.getGetEscrow(1n);

// Send a message (client locks funds for a new agreement)
await escrow.send(
  sender,
  { value: toNano("10.05") }, // agreed amount plus gas
  {
    $$type: "CreateEscrow",
    provider: providerAddress,
    description: "Design work, 3 mockups",
    acceptDays: 3n,
    acceptHours: 0n,
    deliveryDays: 7n,
    deliveryHours: 0n,
  }
);
```

Exact wrapper names come from the Tact build output; check `build/` after compiling rather than copying the names above verbatim.

---

## Security

NovaCont Lite has **not completed a formal third-party audit**. What has been done:

- **Two rounds of manual review.** The first examined architecture and state-transition logic; the second verified fixes at the source level. Six findings from the first round, including one High and one Medium, were fixed and verified in v1.1.0.
- **Static analysis with Misti.** Zero Critical or High findings. Everything flagged was gas optimization or API style preference, with no functional security impact.

Notable fixes from that process, documented rather than quietly patched:

- A state-mutation ordering bug in `CancelEscrow` where a state check was evaluated after the state had already been reassigned, making the check dead. It had no practical impact at the time but was a latent risk under future refactoring.
- All `send()` calls moved from `SendIgnoreErrors` (which silently swallows failed transfers) to `SendBounceIfActionFail`, so a failed transfer now bounces rather than leaving state inconsistent with reality.
- Fund distribution centralized into a single `distributeFunds` function, eliminating a duplicated split path in `CancelEscrow` that could have drifted out of sync.
- Escrow IDs changed from client-chosen to sequential via `escrowCount`, removing a collision risk.

The full review is published in the [documentation](https://novacont.gitbook.io/nova-docs).

Found a vulnerability? Don't open a public Issue, follow [SECURITY.md](./SECURITY.md).

**Don't deposit funds you can't afford to lose until a formal audit is complete.**

---

## Dispute Resolution

Either party can raise a dispute while an agreement is in `Accepted` or `Delivered` state. What happens then:

1. **`RaiseDispute` is sent on-chain.** The agreement moves to `Disputed` and normal flow stops. The stated reason is recorded on-chain.
2. **A support member is assigned automatically.** The contract picks the next address from the support pool in round-robin order and writes it to the agreement's `assignedSupport` field. If the pool is empty, no member is assigned and the contract owner is the only party who can resolve.
3. **The assigned member reviews the evidence** shared through the support channel and decides how funds should be split.
4. **`ResolveDispute` is sent on-chain** with a `clientShareBps` value between 0 and 10000 and a written reason. The split executes immediately and the reason is stored on-chain, queryable by anyone.

Two properties worth calling out:

- **Resolution is proportional, not binary.** `clientShareBps` lets a reviewer award any split, including partial outcomes where both parties are partly right.
- **Every verdict carries a public reason.** The reasoning is stored in contract state alongside the split, so a resolution can be audited after the fact by anyone, not just the parties involved.

The trust assumption this leaves in place is stated under [Known Limitations](#known-limitations).

---

## Known Limitations

Stated plainly rather than left for a reader to discover:

- **Dispute resolution is centralized.** When a dispute is raised, the contract assigns the next support member from the pool in round-robin order, and that member resolves it. The contract owner holds the same resolve authority in parallel, and is the only resolver if the support pool is empty. Rotating assignment spreads the workload and removes an operational single point of failure, but it does not remove the trust assumption: resolvers are chosen by NOVA, not by the parties or by an independent pool.
- **No appeal mechanism.** A resolution is final once executed on-chain.
- **Off-chain evidence.** Evidence URLs point to external resources; the contract can't guarantee they remain reachable.
- **Native TON only.** No Jetton support. This is a deliberate simplification, not an oversight.
- **Collateral threshold is TON-denominated.** With no oracle, the 10 TON threshold's fiat value moves with the TON price.

---

## Documentation

Full user documentation, including the Mini App walkthrough and dispute process: **https://novacont.gitbook.io/nova-docs**

---

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## License

Licensed under the [PolyForm Shield License 1.0.0](./LICENSE). You're free to read, audit, and build on this code for non-competing purposes; you can't use it to build or ship a competing escrow product or service.

---

## Contact

| Purpose | Channel |
|---|---|
| General questions | support@novatechnology.app |
| Security reports | security@novatechnology.app |
| Community | [Discord](https://discord.gg/novacont) |

<div align="center">

**NOVA Cyber & Technology**
*Building Secure, Digital Futures.*

</div>
