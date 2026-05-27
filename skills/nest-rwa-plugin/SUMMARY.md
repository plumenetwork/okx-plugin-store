## Overview

Park idle stablecoins into Nest's RWA yield vaults — tokenized US Treasuries (`nTBILL`), regulated funds (`nWISDOM`), private credit (`nOPAL`, `nINSTO`, `nCREDIT`), CLOs (`nELIXIR`), and a diversified mix (`nALPHA`). Deposit, withdraw, claim, instantly redeem, bridge shares across chains, and check positions — all from natural-language prompts.

Core operations:

- Discover Nest vaults by APY / TVL / risk tier (`nest vaults`)
- Same-chain deposit with server-side compliance + simulation (`nest deposit`)
- Withdraw via solver-fulfilled AtomicQueue or cooldown-based redeem (`nest withdraw`)
- Claim matured redemptions, optionally across every vault in one multicall (`nest claim`)
- Skip the cooldown when liquidity is available (`nest instant-redeem`)
- Reduce a pending redemption (`nest update-redeem`)
- Enable auto-claim so matured shares come back automatically (`nest auto-claim`)
- Bridge already-owned shares between chains via LayerZero OFT (`nest bridge`)
- View live + 30-day vault performance (`nest history`)
- Aggregated position summary via Multicall3 (`nest positions`)

Compliance-gated (the on-chain `PredicateProxy` enforces it); non-custodial. Transaction signing happens in TEE via `okx-agentic-wallet`. The skill calls Plume's `nest` CLI (v0.2.1+) which itself talks to Plume's `evm-actions-api` for ABI encoding, predicate fetching, accountant rate reads, and `simulateCalls` preflight — eliminating brittle client-side plumbing.

Tags: `rwa` `real-world-assets` `tokenized-treasuries` `treasury-yield` `private-credit` `stablecoin-yield` `nest` `plume` `ethereum` `bsc` `arbitrum`

## Prerequisites

- `onchainos` CLI installed (`npx skills add okx/onchainos-skills`) and authenticated (`onchainos wallet status` should return a logged-in account)
- `nest` CLI v0.2.1+ on `PATH` — installed automatically by this skill's pre-flight (`curl -fsSL https://nestagents.io/cli/install.sh | sh`)
- A stablecoin balance on a supported chain:
  - Ethereum (USDC), BSC (USDT), Arbitrum (USDC), or Plasma (USDT0)
- Native gas on the deposit chain (~0.001–0.0015 ETH on Ethereum, ~0.001 BNB on BSC) **or** Gas Station enabled via `okx-agentic-wallet`
- Non-US jurisdiction (Nest's compliance gate blocks US persons at the contract level)

## Quick Start

1. **Discover vaults**: ask *"show me Nest vaults"* or *"what RWA vaults are available?"*. The skill calls `nest vaults -o json`, sorts by your risk preference + APY, and shows TVL, accepted assets, and per-chain availability.
2. **Pick a vault**: say *"deposit 100 USDC into Nest's safest vault on Ethereum"* or name one explicitly (`nTBILL`, `nALPHA`, `nWISDOM`, `nOPAL`, …).
3. **Deposit**: the skill runs `nest deposit --dry-run -o json …`, gets an `approve` + `deposit` bundle back from `evm-actions-api`, runs `okx-security tx-scan` on each transaction, then broadcasts via `okx-agentic-wallet wallet contract-call`. Compliance and predicate signing happen server-side — no manual JSON to manage.
4. **Check position**: *"show my Nest positions"* — runs `nest positions --address <user> -o json` and displays per-vault holdings, total USD value, and weighted APY.
5. **Withdraw**: *"withdraw 50 nTBILL on Ethereum"* — opens a redemption request (AtomicQueue or cooldown depending on vault type). Optionally `/schedule` a watcher to ping you when it's claimable.
6. **Claim**: *"claim my matured Nest redemption"* once the cooldown ends. Or enable auto-claim once per chain and matured shares come back automatically.
7. **Instant redeem** (optional): *"instantly redeem 10 nTBILL on Plume"* — bypasses the cooldown when the vault has buffer liquidity. Subject to a fee that the skill previews before broadcasting.
8. **Bridge shares** (optional): *"bridge my nTBILL from Ethereum to Plume"* — emits LayerZero OFT calldata locally; settles in 2–3 minutes.

For the full operational detail (Flow A through Flow J, edge cases, FAQ), see `SKILL.md`.
