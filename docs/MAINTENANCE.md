# Maintenance playbook — the annual SDK bump and the upkeep around it

The factory's priority order is: keep the app working, fix daily annoyances,
then add features. This runbook covers the first priority — the scheduled
work that catches breakage before Peter does, and the once-a-year ritual
when Apple moves the ground under the toolchain.

## What runs, and when

| Cadence | What | Where | What a failure means |
|---|---|---|---|
| Every push / PR | CI test lanes | `.github/workflows/ci.yml` | A change broke the build; merges stop. Normal factory work. |
| Mondays 06:23 UTC | CI's weekly build of `develop` | `ci.yml` schedule | Toolchain drift between merges — same response as a red canary. |
| Thursdays 09:17 UTC | **Maintenance canary** — re-runs the CI lanes on `develop` | `.github/workflows/maintenance.yml` | Same, as a second probe of the week. |
| Monthly | Dependabot PRs, one batch per ecosystem | `.github/dependabot.yml` | Review-and-merge hygiene, not breakage. |
| Annually, September | The SDK bump PR | This document | Planned work with its own task (pre-shaped below). |

## Reading a red canary

The canary re-runs the CI lanes on `develop` **even when nothing merged**.
A red canary run with no recent merge means the *environment* moved — not
the code:

- the GitHub runner image was refreshed,
- an Xcode point release changed the image's default toolchain,
- the SwiftPM cache or a dependency resolved differently.

Diagnosis: open the run linked in the canary's failure message, compare
against the last green run of the same lanes, and the first failing step
usually names the moved part. Fixes are typically one-line pins
(`DEVELOPER_DIR`, `SIMULATOR_DESTINATION`, runner label) and start the same
day — this is priority-1 factory work. Manual canary runs: `gh workflow
run maintenance.yml`.

Note: the WebDAV sync lane runs non-blocking (`continue-on-error`) while
the regression-harness task owns its stabilization, so a WebDAV-only
failure will not redden the canary until that lane is re-gated. The
canary bar is the merge-gate bar.

## Monthly dependency PRs (Dependabot)

One batched PR per ecosystem per month: minor and patch updates grouped;
major updates arrive as individual PRs and get a close look — majors are
where supply-chain surprises and breaking changes live.

- **github-actions** — check each bump against the runner image; an action
  major usually means a node-version change (harmless here, but look).
- **swift** (SPM) — the pins currently live in the Xcode project
  (`XCRemoteSwiftPackageReference`: SwiftyDropbox → Alamofire 4.8.2
  transitive) and there is no root `Package.swift`, so this ecosystem stays
  quiet. The standing plan from the fork audit is to **remove**
  SwiftyDropbox rather than bump it — the smallest dependency surface is
  the cheapest maintenance. Do not add SPM majors casually.
- **bundler** — fastlane and its gems for the TestFlight delivery lane;
  quiet until that lane's `Gemfile` lands at the repo root.

## The annual SDK bump — the September runbook

Apple's calendar is stable: **WWDC in June** (announcements, betas) and
**GM releases in September**. The bump PR is due within the first week of
the September GM — the same week everyone's toolchains start warning.

### June: watch, don't merge

- Note the announced Xcode version, any new minimum deployment target
  (the Xcode 26 revival commit asserts iOS 15+), and the new simulator
  device names.
- Watch the [runner-images] repo for the next `macos-*` image and the
  deprecation schedule for the current one (macos-14 support ended
  November 2, 2026; the same pattern will eventually apply to macos-26).

[runner-images]: https://github.com/actions/runner-images

### August: dry run (recommended)

Cut a branch, point `DEVELOPER_DIR` at the beta Xcode, and run the lanes on
a beta-capable runner. Everything that breaks gets filed into September's
PR. Skip if the beta image isn't practically available — the GM week
absorbs it.

### September: the bump PR

One PR, `feat/<year>-sdk-bump`, off `develop`, touching:

1. `.github/workflows/ci.yml` — `DEVELOPER_DIR` (pinned Xcode.app path),
   `SIMULATOR_DESTINATION` (the new image's iPhone/OS pair), `runs-on`
   labels if the image changes, and the comment quoting the Xcode build.
2. SwiftPM — resolve fresh, let `Package.resolved` migrate format, and
   review the majors that arrived over the year.
3. Fastlane — the yearly major-version review in the `Gemfile` (minors
   arrive monthly via Dependabot; majors get this one deliberate look).
4. **Deployment-target yearly review** — the floor is **iOS 15** (fork
   audit policy: the lowest target that keeps the App Store door open,
   raised only when a feature requires it). Keep or raise, and record the
   decision in the PR body even when unchanged.
5. This document's baseline table.

### Acceptance bar

A bump PR is done when **both** hold:

1. **Green CI lanes** on the PR — the unit lane green (the required gate)
   and the WebDAV lane per its current gating policy.
2. **A successful TestFlight build** delivered the same day the PR merges —
   the factory's same-day promise — installed and confirmed working on
   Peter's phone.

A green PR with no TestFlight build is not done. A TestFlight build from a
red tree is not done.

## Who does what

| Role | Does |
|---|---|
| **Factory** (this thread / autobuild) | Opens the September bump PR in GM week, keeps the lanes green, delivers the TestFlight build, responds to red canaries the same day, updates this runbook with what changed. |
| **Peter** (Managing Principal) | Approves the bump window and any deployment-target raise, installs the TestFlight build and confirms it works, provides App Store Connect credentials via the secrets store when rotation is due. Escalation point when the same-day promise is at risk. |

## Current baselines (October 2026)

| Thing | Value |
|---|---|
| Xcode pin | `DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer` (build 17F113) |
| Runners | `macos-26` |
| Simulator | `platform=iOS Simulator,name=iPhone 17,OS=26.5` |
| Deployment target | iOS 15.0 (yearly review in each bump PR) |
| Weekly CI cron | `23 6 * * 1` (Mondays 06:23 UTC) |
| Maintenance canary | `17 9 * * 4` (Thursdays 09:17 UTC) |
| SPM | SwiftyDropbox 6.0.3 → Alamofire 4.8.2 (standing plan: remove SwiftyDropbox) |
| Fastlane | 2.238.0 preinstalled on the macos-26 image; `Gemfile` owned by the delivery lane |
| WebDAV fixture | `Tools/tinydav` (vendored Go), runner-native |

## Pre-shaped task: September 2027 SDK bump

Paste into the factory queue in late August 2027 and fill in the blanks:

> **Task:** Annual SDK bump — Xcode 27 GM (`feat/2027-sdk-bump`, off `develop`)
>
> 1. Confirm this year's versions: the Xcode 27 GM path and build number,
>    the `macos-27` runner image label (or the latest supported image), and
>    the new image's iPhone/OS simulator pair. Sources: Apple's release
>    notes and the runner-images README.
> 2. Update `ci.yml`: `DEVELOPER_DIR`, `SIMULATOR_DESTINATION`, `runs-on`
>    labels, and the Xcode-build comment.
> 3. Resolve SwiftPM fresh; let `Package.resolved` migrate; fix one-line
>    deprecations, file the rest.
> 4. Deployment-target yearly review: keep iOS 15 or raise; record the
>    decision in the PR body either way.
> 5. Fastlane major review in the `Gemfile`; Actions/SPM majors via their
>    Dependabot PRs.
> 6. Acceptance bar: green lanes plus a same-day TestFlight build,
>    confirmed on Peter's phone.
> 7. Update this document's baseline table.
