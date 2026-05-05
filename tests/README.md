# tests/

Characterization + smoke tests for the Nirvana engine and shared helpers.

These exist primarily to **lock in current behavior** before the
"templatize Nirvana" refactor (Phases 5 onwards). They snapshot the visible
contracts (signature wording, runner-email subject prefix, migration-mode
gate) so that an accidental regression during config extraction shows up as
a red bar instead of a silently-broken email going to your team.

## How to run

From the repo root:

```powershell
# Full suite
.\tests\run-all.ps1

# A single file
powershell -NoProfile -File .\tests\signature.tests.ps1
```

Exit code is `0` on green, `1` on red. Suitable for the upcoming
`smoke-test.ps1` onboarding step.

## What each file covers

| File                          | Covers                                                            |
|-------------------------------|-------------------------------------------------------------------|
| `_test-runner.ps1`            | Tiny self-contained Describe / It / Assert framework. Dot-sourced by every test file. |
| `signature.tests.ps1`         | All HTML and text variants of `Get-NirvanaSignature` / `Get-NirvanaSignatureText`. Locks in `Default`, `InboxAuto`, `RunnerHeartbeat` (with and without `-RunnerName`), `WhatsAppGroupHe`, `-NoSig`, `-NoNotice`, and the megaphone-notice path. |
| `runner-email.tests.ps1`      | Source-inspection of `_runner-email.ps1`: subject prefix, recipient default, signature variant, COM lifecycle, migration-mode gate ordering. |
| `migration-mode.tests.ps1`    | `_shared/migration-mode.ps1`: env var, flag-file, both, neither, and the explicit "0" override. |
| `run-all.ps1`                 | Discovery + reporting harness. Each `*.tests.ps1` runs in its own child PowerShell to isolate exit calls. |

## Why a custom runner instead of Pester

Windows ships Pester 3.4.0, whose API is incompatible with Pester 5.x. We
don't want to require a global Pester install (or auto-install) just to run
the template's smoke tests on a fresh manager's machine. ~80 lines of
hand-rolled `Describe` / `It` / `Assert-*` keeps onboarding zero-friction.
If the template's needs ever outgrow this, swap in Pester 5 and update the
test files; the assertions translate one-to-one.

## Adding a test

```powershell
# tests\my-thing.tests.ps1
. (Join-Path $PSScriptRoot '_test-runner.ps1')

Describe 'MyThing' {
    It 'does the right thing' {
        Assert-Equal 'expected' (My-Thing)
    }
}

Exit-WithTestResults
```

That's it. `run-all.ps1` discovers it on the next run.
