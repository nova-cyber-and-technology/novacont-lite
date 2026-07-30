# Security Policy

NovaCont Lite is a non-custodial escrow contract holding real user funds on TON. We take security reports seriously and rely on responsible disclosure from the research community.

This policy covers the NovaCont Lite repository. For NOVA's org-wide policy see [NOVA's SECURITY.md](https://github.com/nova-cyber-and-technology/.github/blob/main/SECURITY.md); where the two differ, this document governs for NovaCont Lite. The Base-side protocol has its own policy in the [NovaCont repository](https://github.com/nova-cyber-and-technology/novacont).

---

## Supported Deployment

TON contracts are immutable once deployed. "Supported version" means the currently deployed, canonical contract address, not a package version.

| Network | Contract | Version | Address | Status |
|---|---|---|---|---|
| TON Mainnet | `NovaCont_Lite.tact` | v1.2.0 | `EQBE_CfERNFq87KvPunGzEcakNAzb3NPIqVxlWvouWp952hZ` | ✅ Canonical, supported |

Earlier versions (v1.0.x, v1.1.0, v1.1.1) are superseded. If you're reporting an issue, confirm you're looking at v1.2.0 and at the address above, not an address found elsewhere. The README explains [how to verify](README.md#verifying-the-deployed-contract) that the source in this repository matches the code running at that address.

---

## Reporting a Vulnerability

**Do not disclose vulnerabilities publicly before they've been reviewed and addressed.**

Report privately to **security@novatechnology.app**.

Include as much of the following as you can:

- Description of the issue
- Steps to reproduce, or a proof of concept
- Expected impact
- Suggested mitigation (optional)

### If Your Report Involves the Deployed Contract

Also include:

- Contract address (confirm it matches the published one)
- Transaction hash and, if applicable, the affected `escrowId`
- The message handler involved (`CreateEscrow`, `ResolveDispute`, etc.)
- Whether user funds are at risk, and roughly how much

---

## Severity Guidelines

Grounded in the contract's actual surface rather than a generic list:

**Critical**
- Any path to unauthorized withdrawal of locked TON
- Bypassing the `require(sender == escrow.client)` / `escrow.provider` party checks to act on someone else's agreement
- Unauthorized invocation of `ResolveDispute` by an address that is neither the owner nor the assigned support member
- A fund distribution path where the sum of outbound transfers exceeds `totalLocked`

**High**
- A reachable state where funds are permanently locked with no exit (no release, no timeout, no cancel path). One instance of this class was found and fixed in v1.2.0, see [Security Review Status](#security-review-status); reports of further instances are in scope
- Forcing a state transition out of order, for example reaching `Completed` without passing through `Delivered` or `Disputed`
- Manipulating `clientShareBps` outside its 0 to 10000 bound, or causing `distributeFunds` to miscalculate a split
- Bypassing the 7-day `REVIEW_TIMEOUT` to claim payment early, or settling a dispute before `DISPUTE_TIMEOUT` has elapsed without resolver authority
- Bypassing the owner check on `TransferOwnership` or on the pause controls

**Medium**
- Denial of service against a specific escrow or message handler
- Incorrect fee calculation (`PLATFORM_FEE_BPS`) or incorrect application of the 1.25x extra deposit rule
- Support pool assignment logic errors, for example `nextSupportAssign` desynchronizing from `supportCount` after `RemoveSupport`
- A removed support member retaining any authority over an escrow

**Low**
- Gas inefficiencies, `SuboptimalSend`-class findings
- Missing or misleading event emissions
- Documentation errors with no on-chain impact

---

## Known, Accepted Risks (Not Eligible for Reward)

These are documented, deliberate design tradeoffs, not vulnerabilities. Reports that only restate them won't be treated as new findings, though we're glad to hear if you've found a way to exploit one further than described here:

- **Centralized dispute resolution.** The contract owner and the assigned support member can resolve any disputed escrow with any `clientShareBps` split. This is the design, not a flaw. There is no jury, no appeal, and no on-chain constraint forcing a resolution to be fair. The trust assumption is stated plainly in the README; NovaCont on Base is the deployment that addresses it.
- **Owner is the sole resolver when the support pool is empty.** If `supportCount` is 0 at the time `RaiseDispute` is processed, `assignedSupport` stays null and only the owner can resolve. Since v1.2.0 this is bounded rather than open-ended: if nobody resolves within `DISPUTE_TIMEOUT`, either party can settle the escrow themselves.
- **Owner controls the admin and support sets.** `AddAdmin`, `RemoveAdmin`, `AddSupport`, and `RemoveSupport` are owner-gated. Whoever holds the owner key controls who can resolve disputes.
- **Owner can pause new agreements.** Added in v1.2.0 as an incident control. Pausing does not touch existing agreements, which continue to settle normally, but the ability to halt intake is a centralization point and is documented as one.
- **`STORAGE_RESERVE` is deducted per outbound transfer.** 0.05 TON is withheld from each transfer to keep the contract solvent against TON storage rent. This is intentional and is not fund loss to the platform, it stays with the contract.
- **Integer division rounding.** Fee and split calculations round down at nanoTON precision. The residual is dust-level and stays in the contract.
- **Off-chain evidence permanence.** `evidenceUrl` points to external resources. The contract cannot guarantee they remain reachable, and a dead link at dispute time is the submitter's problem.
- **No maximum length on `description` / `evidenceUrl`.** Long strings raise gas cost for the sender rather than creating a security issue, but the absence of a bound is known.
- **Native TON only.** No Jetton support. This is a deliberate simplification.
- **Not registered on verifier.ton.org.** Verification is currently manual and reproducible rather than badge-backed. The procedure is in the README.

---

## Response Targets

| Stage | Target |
|---|---|
| Initial acknowledgement | Within 48 hours |
| Initial triage | Within 7 days |
| Status updates | As needed while remediation is in progress |

Because TON contracts are immutable, remediation of a confirmed issue may mean deploying a new contract version and migrating, which takes longer than patching a server. We'll be explicit about the plan and timeline once an issue is confirmed.

---

## Safe Harbor

We won't pursue legal action against researchers who act in good faith:

- Avoid violating user privacy
- Don't exploit a vulnerability beyond what's needed to demonstrate impact
- Don't intentionally disrupt the contract or the Mini App
- Follow this disclosure policy

---

## Scope

**In scope:**

| Component | Status |
|---|---|
| `contracts/NovaCont_Lite.tact` | ✅ In scope |

**Out of scope:**

- The Telegram Mini App frontend and the bot backend. Neither is published in this repository, and neither holds user funds; the contract is the security boundary. Report Mini App issues to support@novatechnology.app as regular bugs rather than security reports, unless the issue causes an on-chain effect you can demonstrate.
- Third-party infrastructure: TON network itself, TonConnect, Telegram, wallet applications, public RPC endpoints.
- Social engineering against users or the team.
- Denial-of-service requiring unrealistic resources or gas expenditure.
- Findings from a static analysis tool with no demonstrated exploitability, especially `SuboptimalSend` and `PreferredStdlibApi`-class results, which are already documented in our own Misti run.
- Issues that only affect superseded versions (v1.0.x, v1.1.0, v1.1.1) and are already fixed in v1.2.0.

### Rewards

NovaCont Lite doesn't currently offer a monetary or material bug bounty. Verified reports are credited in the Hall of Fame below (with your permission) regardless of severity. We treat this as recognition rather than compensation and would rather say so directly than imply otherwise.

### Reporting Conduct

Testing that violates these rules falls outside the disclosure process and may create legal liability:

- No live attacks against real user funds on mainnet. Test on TON testnet or with your own wallets on both sides of an escrow.
- No testing that could deny service to real users.
- No social engineering or phishing against real users or the team.

---

## Security Review Status

NovaCont Lite has **not completed a formal third-party audit**. What has been done, in full:

**Two rounds of manual review.** The first examined architecture and state-transition logic before launch. The second re-examined the live contract afterwards. Both rounds are described below with their findings and fix status.

### Round one, fixed in v1.1.0

Six findings were raised, including one High and one Medium, and all were fixed and verified.

The High-severity finding is worth stating openly rather than burying: all `send()` calls originally used `SendIgnoreErrors`, which silently swallows a failed transfer. A failed payout would have left contract state claiming a payment had completed when no funds moved. Every `send()` now uses `SendBounceIfActionFail`, so a failed transfer bounces rather than leaving state inconsistent with reality.

Other fixes from that round:

- **State-mutation ordering in `CancelEscrow`.** A `state == STATE_CREATED` check was evaluated after the state had already been reassigned to `STATE_CANCELLED`, making the check permanently false. Only the `acceptTime == 0` condition was actually in effect, which happened to be a safe proxy, so there was no practical impact. But a dead condition is a latent bug waiting for a refactor, so the original state is now captured in `wasNotYetAccepted` before mutation.
- **Duplicated fund-splitting logic.** The penalized-cancellation branch of `CancelEscrow` had its own split logic separate from `distributeFunds`, meaning a fix in one path wouldn't reach the other. All distribution now routes through `distributeFunds`, which also guarantees `STORAGE_RESERVE` handling is consistent everywhere.
- **Client-chosen escrow IDs.** Two clients could previously pick the same ID. IDs are now assigned sequentially from `escrowCount`.
- **Single-reviewer dispute resolution.** Disputes originally depended on one account. A support pool with round-robin assignment now distributes them. This reduces operational centralization; it does not eliminate the trust assumption.

### Round two, fixed in v1.2.0

Eight further findings were raised against the live contract and all were fixed. The three with direct user impact:

- **Disputes had no resolution deadline.** Once raised, a dispute depended on someone actually resolving it. If nobody did, the funds stayed locked with no path out. Not stolen, not lost, but permanently unavailable, which from the user's side is the same outcome. `DISPUTE_TIMEOUT` (2592000 seconds, 30 days) now bounds this: after it elapses, either party can settle the escrow themselves. This finding is also why the Terms of Service were rewritten, since the previous text described a resolution process without describing what happens when the process doesn't happen.
- **No ownership transfer and no pause.** Neither existed. A contract holding funds needs a way to hand over control and a way to halt new agreements during an incident. Both were added.
- **Removing a support member did not revoke their authority.** A removed member kept the ability to resolve disputes already assigned to them. Revocation now applies to existing assignments.

### Static analysis

**Misti.** Zero Critical or High findings. Everything flagged was gas optimization (`SuboptimalSend`, 9 findings) or API style preference (`PreferredStdlibApi`, `PreferSenderFunction`, 29 findings), with no behavioral difference. Three of Misti's detector categories require Souffle, which was not installed in the environment used, so those detectors did not execute; they were covered by manual review instead, and re-running the scan in an environment with Souffle present remains outstanding.

Every finding above came from manual review of state transitions rather than from tooling. That is worth stating plainly: static analysis found no functional issues in this contract, and it should not be read as evidence that none existed.

The full review is published in the [documentation](https://novacont.gitbook.io/nova-docs).

This is a positive signal about the codebase's maturity. It is **not** a substitute for an independent audit.

**Don't deposit funds you can't afford to lose until a formal audit is complete.**

---

## Hall of Fame

We're grateful to researchers who disclose responsibly. Verified reporters are listed here (with permission) as they're confirmed.

- *List will be updated as reports are resolved.*

---

## Contact

Security Team
security@novatechnology.app
https://novatechnology.app

Thank you for helping keep NovaCont Lite secure.
