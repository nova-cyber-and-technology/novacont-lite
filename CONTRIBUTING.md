# Contributing to NovaCont Lite

Thank you for your interest in contributing to NovaCont Lite.

NovaCont Lite is a minimal, non-custodial escrow contract for TON, written in Tact and accessed through a Telegram Mini App. Contributions are welcome, whether they involve the contract itself, documentation, or integration examples.

Please read this guide before opening an Issue or Pull Request.

---

## Table of Contents

- Code of Conduct
- Ways to Contribute
- Before You Start
- Repository Structure
- Development Environment
- Development Workflow
- Branch Naming
- Commit Messages
- Tact Guidelines
- Testing
- Security Guidelines
- Pull Requests
- Documentation
- Reporting Bugs
- Feature Requests
- Licensing

---

## Code of Conduct

By participating in this project, you agree to follow our Code of Conduct.

See: [CODE_OF_CONDUCT.md](https://github.com/nova-cyber-and-technology/.github/blob/main/CODE_OF_CONDUCT.md) (org-wide)

---

## Ways to Contribute

- Contract improvements and gas optimization
- Security research and responsible disclosure
- Integration examples using the Tact-generated TypeScript wrappers
- Documentation improvements

Not every contribution requires writing Tact.

---

## Before You Start

- Read the [README](./README.md), particularly the Known Limitations section. Several things that look like bugs are deliberate design choices, and the README says which.
- Review the user documentation at https://novacont.gitbook.io/nova-docs
- Search existing Issues before opening a new one.
- Open a discussion first for anything that changes contract behavior. The contract is deployed and immutable; a change to it means a new deployment and a migration, so the bar for changing it is high and the conversation should happen before the code.

---

## Repository Structure

```
contracts/
  NovaCont_Lite.tact   The escrow contract
```

The Telegram Mini App frontend and the bot backend are not published here. Issues and PRs about those components are out of scope for this repository.

---

## Development Environment

NovaCont Lite is written in [Tact](https://tact-lang.org) and built with [Blueprint](https://github.com/ton-org/blueprint), the standard TON development framework.

To work on the contract locally, you'll need Node.js 18+ and a Blueprint project scaffold. A build configuration isn't committed to this repository yet, so if you're planning contract work, open an Issue first and we'll coordinate on the setup rather than have you guess at it.

Once you have a Blueprint project:

```bash
npx blueprint build     # compiles the contract and generates TypeScript wrappers
npx blueprint test      # runs tests, if a test suite is present
```

Compilation output lands in `build/` and is gitignored. The generated TypeScript wrappers are how you integrate with the contract, see the Integration section in the [README](./README.md).

---

## Development Workflow

1. Fork the repository.
2. Create a dedicated branch.
3. Make your changes.
4. Verify the contract compiles cleanly.
5. Open a Pull Request describing what you changed and how you verified it.

Keep Pull Requests focused on a single change.

---

## Branch Naming

```
feature/jetton-support
fix/cancel-state-check
docs/update-integration-example
refactor/distribute-funds
```

---

## Commit Messages

Clear, descriptive messages:

```
feat: add maximum length check on description
fix: correct support pool index after removal
docs: clarify storage reserve behavior
refactor: extract deadline calculation
```

Avoid vague messages like `update`, `fix`, `changes`.

---

## Tact Guidelines

TON and Tact differ from EVM and Solidity in ways that matter for contributions here:

- **Always use `SendBounceIfActionFail` for outbound transfers.** Never `SendIgnoreErrors`. A silently swallowed transfer leaves contract state claiming something happened that didn't; this was a real High-severity finding in this codebase and was fixed for exactly that reason.
- **Account for `STORAGE_RESERVE` in any new distribution path.** TON charges storage rent, and a contract that fully drains itself can be frozen with its data lost. All fund distribution should route through `distributeFunds` rather than reimplementing the reserve logic.
- **Capture state before mutating it** when a later check depends on the prior value. An earlier version of `CancelEscrow` had a check that read a field after it had already been reassigned, making the check permanently dead. That pattern is easy to reintroduce.
- **Emit an event for every meaningful state change.** The Mini App and any integrator depend on these.
- **Keep string fields bounded in intent.** There's no maximum length on `description` or `evidenceUrl` today; don't add new unbounded string fields without a reason.
- **Match the existing style** of the surrounding code. If you want to restructure something broadly, open an Issue for it as a separate change rather than mixing it into a functional PR.

---

## Testing

A public test suite isn't in this repository yet. The contract has been through two rounds of manual review and static analysis with Misti (see [SECURITY.md](./SECURITY.md) for the full picture), but automated tests aren't published.

If you're contributing a contract change, describe in the PR how you verified it: a testnet deployment, a Blueprint test, a specific transaction, whatever you actually did. Be prepared to help build out a shared test fixture as part of the PR discussion.

This will get stricter as the test infrastructure matures. We won't reject a PR for missing tests we don't yet require of ourselves.

---

## Security Guidelines

The contract holds real user funds. Security comes before features.

- Never submit code that weakens the contract's guarantees.
- Explain the security implications of your change in the PR, including what you considered and ruled out.
- Preserve deterministic behavior. Every state must keep a defined exit path; a change that introduces a reachable state with no way out is not acceptable regardless of how unlikely that state seems.
- Don't introduce new trust assumptions without saying so explicitly.

For reporting vulnerabilities, see [SECURITY.md](./SECURITY.md). Do not open a public Issue for a suspected vulnerability.

---

## Pull Requests

Before submitting:

- The contract compiles cleanly.
- You've described how you verified the change.
- Documentation is updated where relevant.
- No unrelated changes are bundled in.
- Commit history is reasonably clean.

Because the deployed contract is immutable, a merged change doesn't automatically reach users. Merging means the change is accepted into the codebase for a future deployment, not that it's live.

---

## Documentation

If your PR changes contract behavior, message signatures, constants, or protocol rules, update the relevant documentation in the same PR.

In-repo docs (README, SECURITY, this file) go in the PR itself. The user-facing GitBook documentation at https://novacont.gitbook.io/nova-docs is maintained separately, note in the PR if a GitBook update is also needed.

---

## Reporting Bugs

Use GitHub Issues for bugs, documentation problems, and feature requests.

Security vulnerabilities should **not** be reported publicly. Follow the process in [SECURITY.md](./SECURITY.md).

When reporting a bug against the deployed contract, include the `escrowId`, the transaction hash, and which message handler was involved.

---

## Feature Requests

Feature requests should explain:

- The problem being solved.
- Why it's worth the cost of a new contract deployment.
- Possible implementation ideas (optional).

That second point matters more here than on a typical project. NovaCont Lite is intentionally minimal, no Jettons, no oracle, no jury, and each of those absences is a deliberate reduction in dependencies and attack surface. A feature request that adds one of them needs to justify the tradeoff, not just the benefit.

---

## Licensing

NovaCont Lite is licensed under the PolyForm Shield License 1.0.0, a source-available license, not a standard open source license. You may read, audit, and build on this code for non-competing purposes, but the license does not permit using it to build or ship a competing escrow product or service.

By submitting code, documentation, or other contributions, you agree that your contribution will be licensed under these same terms.

Please review [LICENSE](./LICENSE) before contributing.

---

Thank you for helping build NovaCont Lite.
