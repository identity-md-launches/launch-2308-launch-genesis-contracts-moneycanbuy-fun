# Adaptation of the genesis launch (launch 1 of 4, `evm_contracts`, Ethereum mainnet)

The six genesis contracts of moneycanbuy.fun (`NftGate`, `IncentivesVesting`, `DevVesting`, `TeamVesting`,
`TreasuryVesting`, `YoloSplitter`) launch **as they arrived**. None of their code, shares, schedules, allowance per
NFT, recipients or constructor arguments changed. No owner, pause, upgrade path or fee was added anywhere.

The launch rules required two changes outside the six contracts, both in the core of a later launch
(`src/TaskVault.sol`, `src/YoloLockHub.sol`), because the launch's static analysis (Slither, run over the whole
`src/` tree) rejected the previous attempt on two high-impact / high-confidence findings. Both findings were
reproduced locally with Slither 0.11.6 on the code as it arrived, both are false positives of the analyser's
heuristics, and both were cleared by equivalent code rather than by suppression comments. Everything else the
analyser reported (high/medium and below) was reviewed and left as it is (see the end of this file).

## Changes

### 1. `src/YoloLockHub.sol`, `_checkpoint`: write `_history[who]` directly

- **Finding** (`uninitialized-state`, high/high): "`YoloLockHub._history` is never initialized. It is used in
  `_pointBefore`, `_last`, `_checkpoint`".
- **Cause**: `_checkpoint` wrote the history only through a local storage pointer (`Point[] storage h = _history[who];
  h.push(...)` / `h[n - 1] = ...`). The analyser does not credit a write through a local storage pointer to the state
  variable, so the mapping looked read-only.
- **Change**: `_checkpoint` reads the length and the last point and writes the point through `_history[who]` itself
  (`_history[who].push(p)`, `_history[who][n - 1] = p`). Same storage, same values, same events; the runtime is 20 bytes
  smaller. The behaviour is unchanged.
- **Tests**: the existing `test/YoloLockHub.t.sol` (22 tests: lock, extend, add, withdraw, power at a time, epochs)
  and `test/Adaptation.t.sol::test_LockHub_HistoryCheckpoints_SameBlockOverwritesLaterBlockAppends` (a same-block
  checkpoint overwrites the last point, a later block appends one, the earlier point stays readable, the history
  survives a withdrawal, `stakePower` sees the epoch change).

### 2. `src/TaskVault.sol`, `collectBondPart` and `_collect`: one `_pullToken` helper

- **Finding** (`arbitrary-send-erc20`, high/high): "`TaskVault.collectBondPart(address,uint256,address,uint256)` uses
  arbitrary `from` in `transferFrom`: `IERC20(currency).safeTransferFrom(from, address(this), amount)`".
- **Cause**: the analyser flags a `transferFrom` whose `from` is never derived from `msg.sender` or `address(this)`
  anywhere in the contract. `collectBondPart` is `onlyDesk` (only `caseDesk` and `disputeDesk`, wired in the
  vault's constructor, may call it) and the desks pass their own `msg.sender`, so the payer is always the wallet that
  submitted or disputed; the analyser cannot see across the two contracts. The same three lines existed in `_collect`
  (the createTask/topUp path, where `from` is `msg.sender`).
- **Change**: the identical pull of a plain token (USDC or $YOLO: `safeTransferFrom` from the payer, then
  `liabilities[currency] += amount`) in `_collect` and `collectBondPart` was moved into one private `_pullToken(from,
  currency, amount)` that both call. No condition, order, amount or event changed; the desk-only guard is where it
  was. The analyser now sees the payer derived from `msg.sender` on the user path and no longer flags the bond path.
  The runtime is 23 bytes larger.
- **Tests**: the bond suites (`test/BondBase.t.sol`, `test/Desks.t.sol`, `test/Disputes.t.sol`, the audit and review
  suites) and `test/Adaptation.t.sol::test_Vault_BondPartInUsdc_PulledFromTheSubmitter` (the USDC part of a doer bond is
  pulled from the submitter and booked) and `::test_Vault_CollectBondPart_OnlyADesk` (a non-desk caller cannot name
  an approved wallet as the payer: `NotAuthorized`).

### 3. Documented runtime sizes

- `docs/LAUNCH-TASK.md` (size headroom paragraph) and `test/review/ReviewLaunch.t.sol` (`DOC_MARGIN_VAULT`,
  `DOC_MARGIN_HUB`): the EIP-170 margins of TaskVault (3,975 to 3,952 bytes) and YoloLockHub (21,357 to 21,377 bytes)
  follow changes 1 and 2. `test_L1_perContractCodeMargin_matchesDoc` checks the doc against the compiled code and
  would otherwise fail. The gas figures of the doc's table are unaffected at their precision.

### 4. `test/Adaptation.t.sol` (new)

Five tests: the two changes above, and the imported audit's findings reproduced against the genesis contracts (below).

## The imported audit (4 findings), reproduced against the code as it arrived

1. **[low] YoloSplitter skips the starter binding when a vesting address holds no code; such a vesting's vested
   part is locked for good.** Reproduces as described (`test_Audit_LoneVestingHasNoClock_GenesisLaunchBindsAllFour`:
   a `DevVesting` deployed alone has `starter() == 0`, its `release` never starts a clock and 77,777,777 YOLO stay in
   it after ten years). **Not changed**: it is the designed guard, not a defect. `ProjectVesting.bindStarter` accepts
   a starter only inside the vesting's own deployment transaction, and the code-length skip in `YoloSplitter._bind`
   exists so the splitter's constructor also runs where no vesting exists (the launch's empty-chain constructor
   rehearsal). The launch deploys the four vestings and then the splitter in one factory transaction, which the same
   test performs through `LocalFactory` + `LaunchPlan.genesisLaunchWith`: all four report `starter() ==
   YoloSplitter`, a second `bindStarter` reverts `BindingClosed`, and the first `split` starts every clock and pays
   62,500,000 (incentives), 150,000,000 (stabilizer) and 74,074,074 (treasury) at once, with the remainder
   222,222,223 to the treasury vesting. The same holds in `test/audit/swarm117/VestingClockPreStart.t.sol` and in the
   fork rehearsal (`LaunchRehearsal.fork.t.sol` asserts `starter()` on the dev and treasury vestings). The audit's
   recommended operational check stands as a handoff item: after this launch and before the token launch, read
   `starter()` on all four vestings and require the YoloSplitter's address.
2. **[info] NftGate: the writer's powers before the seal are unbounded on chain.** Reproduces
   (`test_Audit_GateWriterPowersEndAtTheSeal`: `record([alice],[5000])` and `seal(...)` succeed). **Not changed**: the
   brief lists the off-chain snapshot by the project wallet, published with its block and `snapshotHash`, as known and
   accepted by design, and the audit itself files it as a trust assumption. After the seal the writer has no power
   (`record` and `seal` revert `AlreadySealed`), `consume` reverts until the seal, and books per calling token only
   what fits; all checked in the same test.
3. **[info] NftGate: a mis-recorded wallet cannot be amended before the seal.** Reproduces (second `record` of the same
   wallet reverts `AlreadyRecorded`, the first count stays). **Not changed**: "each wallet once" is the brief's rule;
   the remedy is a fresh gate before the token launch, as the audit notes. The snapshot script publishes the
   `hashAfter` per batch so the writer compares `snapshotHash()` before `seal`.
4. **[info] Coverage note.** No defect; nothing to change.

## Own review of the six, as they arrived

- Constructors take only addresses (2, 1, 1, 1, 1, 5 arguments), are nonpayable, make no external call except
  `bindStarter` guarded by a code-length check, and so run on an empty chain. No owner, admin, pause or upgrade path;
  no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`; runtime sizes 1,888 to 2,113 bytes (`ReviewLaunch`). The launch
  manifest's `$contract:` references for the YoloSplitter point backward to the four vestings.
- Reentrancy: the splitter sets `done[token]` before any transfer; the vestings update `released` before paying; the
  gate makes no external call. The vestings' `release` is callable by anyone and only pays the beneficiary what the
  schedule has opened. `vestedAmount` is monotone and rounds down; `FIXED` equals the sum of the four fixed shares.
- Static analysis on the six: `incorrect-equality` on `ProjectVesting.release`/`vestedAmount` (`balanceOf != 0`,
  `start == 0`) and `NftGate.consume` (`sealedAt == 0`) are flag tests, not balance equalities a transfer could nudge
  past; left as they are.

## What the analyser still reports, reviewed and left

- `arbitrary-send-eth` (high/medium) in `TaskVault._collectImd` (refund of unbooked ETH to the payer, the desk's
  caller) and `BuybackBurner.forward` (sends to the buyback wallet set by the dev wallet): both recipients are fixed
  by the design, not by the caller.
- `reentrancy-eth` / `reentrancy-balance` (high/medium) in `TaskVault.createTask`, `ask` and `_collectImd`: the
  user-facing vault entries (`createTask`, `topUp`, the withdrawals) and the fallback that forwards to the desks run
  under the vault's `nonReentrant` lock; the bank functions (`ask`, `collectImd`, `collectBondPart`) are desk-only and
  the desks are only entered through that locked forwarding.
- Medium and lower (`incorrect-equality`, `divide-before-multiply` in `YoloLockHub.lock` with whole weeks,
  `reentrancy-no-eth`, `timestamp`, `uninitialized-local`, `unused-return`, informational): behaviour the project
  documents and tests; outside this launch's scope and not changed.

## Checks

- `forge build` (the project's own `foundry.toml`, via-IR, solc 0.8.28): passes with the pre-existing warnings only.
- `forge test` with `FOUNDRY_FUZZ_SEED=0xebb20c7666917c18098d2defb548fb273d404b3626b3ab13773fb07a05f7da2b`: 691 passed,
  0 failed, 3 skipped (the three fork tests, which need `FORK_URL`; not run here, no archive RPC on this machine).
- Slither 0.11.6 over the repository: no high/high findings remain (two before); no new finding of any level.
- `python3 script/check-launch-task.py`: the launch texts still fit and the doc arguments still match the plan.
