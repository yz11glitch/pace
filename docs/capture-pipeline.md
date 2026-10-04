# Capture pipeline

Capture starts with an explicit iOS integration or user action.
Pace keeps uncertain values visible for review.
The native app has no voice input.
This document describes the native snapshot, not the separate Mac engine.

## Entry points

`LogWalletPaymentIntent` accepts fields exposed by a Wallet transaction automation.
The automation is configured in Apple's Shortcuts application.
iOS may omit fields; an absent parameter is not treated as evidence.
The Wallet adapter normalizes the amount text and merchant input.

`LogScreenshotIntent` accepts an image supplied by a user-built Shortcut.
Back Tap can trigger that Shortcut; Pace implements the App Intent.
Pace does not implement or configure Back Tap itself.
The screenshot service reads the image into memory for OCR.
It does not create an additional screenshot file.

## OCR and deterministic extraction

`ScreenshotOCRService` uses Vision `RecognizeTextRequest`.
Recognition is accurate with English and Malay language hints.
Recognized strings and their geometry become core layout values.

The pure core analyzes several kinds of evidence:

1. Layout groups related lines and columns.
2. Typed spans identify money, dates and identifiers.
3. Labels distinguish payment amounts from balances and limits.
4. Relations associate a label with its nearby value.
5. Field resolution selects grounded amount, merchant, time and reference.

Competing values remain ambiguous rather than being silently guessed.
A failed-payment indication is carried into the review decision.
Non-payment screenshots can be rejected without adding a transaction.
Reference text is used for duplicate evidence where available.
The app does not infer a transaction from a bank balance alone.

## Category suggestion

Merchant memory is consulted before a language model.
Remembered corrections and aliases can supply the category.
Without a match, the on-device Foundation Models service suggests a category.
Its generated type uses `@Generable` and a fixed `@Guide(.anyOf:)` list.
Generation uses greedy sampling.
Unavailable or failed generation falls back to Other.

The language model never supplies amounts, merchants or dates.
Those come only from deterministic extraction over the OCR text.
`ScreenshotCategoryService` is the shipping model integration.
`ScreenshotSemanticSelectionService` is retained as a benchmark comparison baseline.
It is not wired into capture.
The stored `intentional_fm` parser label is a legacy diagnostics value.
It does not mean the model extracts the financial fields.

## Trust stages

`PaceCore/Capture.swift` defines the policy independently of persistence.
Field trust is represented as trusted, usable or unresolved.
The capture path has an observe, assisted or automatic stage.

| Stage | Meaning |
|---|---|
| Observe | Require review while collecting correction evidence |
| Assisted | Allow qualified grounded inputs while retaining safeguards |
| Automatic | Permit reliable paths subject to field and anomaly checks |

Promotion uses reviewed capture counts and measured field errors.
An automatically saved amount error can lower the stage.
Recent soft errors can also lower trust.
Stage is a policy input, not a model confidence score.

## Draft and attention states

The decision checks unresolved amount, merchant, date and payment status.
Ambiguous extraction adds an anomaly signal.
Unusual amounts are compared with available local history.
Cold-start limits apply when that history is insufficient.
Potential duplicates remain reviewable drafts.
Missing or ambiguous values never become confirmed ledger entries silently.

Review can ask for an amount, merchant, date or category.
It can ask the user to check a large amount or a possible failed payment.
Qualified complete captures may save according to the current trust policy.
Some saved captures can still need a category.
Needs you combines pending drafts and saved entries awaiting categorization.
Draft values do not count as confirmed spending.

## Corrections and merchant memory

Review confirms explicit final values through the store layer.
The user can keep a draft for later or discard it.
Discard has an undo action.
Remembered merchant corrections can be reused by subsequent captures.
A suggestion alone does not teach merchant memory.
Correction evidence remains linked to the capture path.

## Evaluation method

The test names G0–G3 refer to staged extraction milestones.
G0 measures the legacy parser as a frozen comparison baseline.
G1 measures typed span primitives and their invariants.
G2 measures labels and semantic relations.
G3 measures independent field extraction over the selected layouts.

Generated cases vary formatting and layout while retaining explicit truth.
Blind fixtures exercise cases outside the generated families.
Metamorphic tests alter presentation while preserving financial meaning.
Scoreboards separate missing fields from incorrect trusted fields.
The public held-out fixtures use fictional merchant and payment identifiers.
Derived FM benchmark text and embedded app data are generated from those fixtures.

DEBUG-only Capture Lab and model benchmark screens support local measurement.
Their presence is engineering evidence, not a shipping feature claim.
Synthetic showcase drafts use the production adapters and processor.
They were seeded for screenshots, not produced by a live OCR/model run.
