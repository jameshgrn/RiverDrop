# StoreKit 2 Implementation Review — `com.riverdrop.pro`

Non-consumable, $14.99 one-time purchase.

Files reviewed: `StoreManager.swift`, `PaywallView.swift`, `TransferManager.swift`, `MainView.swift`, `LocalBrowserView.swift`, `RiverDrop.storekit`, `RiverDropApp.swift`.

---

## HIGH — Could lose revenue or break purchases

### H1. No `checkEntitlements()` on return from background

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-storekit/RiverDrop/RiverDropApp.swift` (entire file — no scene phase observer exists)
**Also:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-storekit/RiverDrop/StoreManager.swift:86`

`checkEntitlements()` is called exactly twice: at init (line 32) and after `restorePurchases()` (line 80). There is no `scenePhase` observer anywhere in the app.

**Impact:** If a user purchases on another device (Family Sharing, second Mac) or gets a refund while the app is in the background, `isPro` stays stale until a full restart. The user either can't access what they paid for, or continues using Pro features after a refund.

**Fix:** Add to `RiverDropApp.swift`:

```swift
@Environment(\.scenePhase) private var scenePhase

// Inside body, on the Group:
.onChange(of: scenePhase) { _, phase in
    if phase == .active {
        Task { await storeManager.checkEntitlements() }
    }
}
```

---

### H2. PaywallView doesn't auto-dismiss on successful purchase

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-storekit/RiverDrop/PaywallView.swift` (entire file — no dismiss-on-success logic)

After `purchase()` succeeds and `isPro` flips to `true`, the paywall stays open. User must manually close it.

**Fix:** Add to `PaywallView`:

```swift
.onChange(of: storeManager.isPro) { _, isPro in
    if isPro { dismiss() }
}
```

---

### H3. `errorMessage` never cleared before retry

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-storekit/RiverDrop/StoreManager.swift:49` (`purchase()`)
**Also:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-storekit/RiverDrop/StoreManager.swift:77` (`restorePurchases()`)

If `loadProducts()` fails, `errorMessage` is set. The user opens the paywall, sees the error. They fix their network and tap "Get RiverDrop Pro" — the old error stays visible throughout the new attempt and after a successful purchase.

**Fix:** Clear `errorMessage` at the start of each operation:

```swift
func purchase() async {
    errorMessage = nil  // ADD
    guard let product = proProduct else { ... }
    ...
}

func restorePurchases() async {
    errorMessage = nil  // ADD
    do { ... }
}

func loadProducts() async {
    errorMessage = nil  // ADD
    do { ... }
}
```

---

### H4. `loadProducts()` never retried — paywall stuck on loading spinner forever

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-storekit/RiverDrop/StoreManager.swift:40-47`
**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-storekit/RiverDrop/PaywallView.swift:160-162`

`loadProducts()` is called once at init. If it fails (network down at launch), `proProduct` stays `nil` permanently. PaywallView shows `ProgressView("Loading...")` forever — with the error message floating above it (line 125), which is a confusing UX: error text + loading spinner simultaneously.

**Fix, option A (recommended):** Retry `loadProducts()` when the paywall appears:

```swift
// PaywallView.swift — add to .onAppear:
.onAppear {
    withAnimation(.easeOut(duration: 0.18)) { appeared = true }
    if storeManager.proProduct == nil {
        Task { await storeManager.loadProducts() }
    }
}
```

**Fix, option B:** Show retry button instead of spinner when `errorMessage != nil && proProduct == nil`:

```swift
} else if storeManager.errorMessage != nil {
    Button("Retry") {
        Task { await storeManager.loadProducts() }
    }
    .buttonStyle(.borderless)
} else {
    ProgressView("Loading...")
        .controlSize(.small)
}
```

---

### H5. `.pending` purchase state silently swallowed — no user feedback

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-storekit/RiverDrop/StoreManager.swift:67-68`

```swift
case .pending:
    break
```

When a purchase enters `.pending` (Ask to Buy / parental approval required), `isPurchasing` flips back to `false` and nothing visible happens. The user thinks the purchase failed silently.

**Fix:**

```swift
case .pending:
    errorMessage = "Purchase pending approval. You'll get access once the purchase is approved."
```

Note: "errorMessage" is a poor property name for this — it's really a status message. Renaming to `statusMessage` or adding a separate `pendingMessage` would be cleaner, but at minimum the user needs feedback.

---

## MEDIUM — Poor UX but doesn't break purchases

### M1. No feedback when restore finds no prior purchases

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-storekit/RiverDrop/StoreManager.swift:77-84`

`restorePurchases()` calls `AppStore.sync()` then `checkEntitlements()`. If there are no purchases, `isPro` stays `false` and `errorMessage` stays `nil`. The user sees nothing happen — indistinguishable from a broken restore.

**Fix:**

```swift
func restorePurchases() async {
    errorMessage = nil
    do {
        try await AppStore.sync()
        await checkEntitlements()
        if !isPro {
            errorMessage = "No previous purchase found for this Apple ID."
        }
    } catch {
        errorMessage = "Restore purchases failed: \(error.localizedDescription). ..."
    }
}
```

---

### M2. Restore button has no loading/disabled state

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-storekit/RiverDrop/PaywallView.swift:166-172`

The "Restore Purchases" button can be tapped repeatedly with no visual feedback. `AppStore.sync()` is idempotent so this won't break anything, but it's confusing.

**Fix:** Either add an `isRestoring` published property to `StoreManager`, or at minimum disable the button while `isPurchasing` is true (since both operations are mutually exclusive from the user's perspective).

---

## LOW — Defense in depth / minor

### L1. Unverified transactions silently ignored in `listenForTransactions()`

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-storekit/RiverDrop/StoreManager.swift:101-108`

```swift
for await result in Transaction.updates {
    if case .verified(let transaction) = result {
        ...
    }
    // .unverified silently dropped
}
```

If `Transaction.updates` delivers an `.unverified` result, it's silently ignored — no `finish()`, no logging. For a non-consumable this is the correct security posture (don't grant entitlement for unverifiable transactions), but logging the failure would help diagnose issues.

**Fix (optional):**

```swift
for await result in Transaction.updates {
    switch result {
    case .verified(let transaction):
        await transaction.finish()
        if transaction.productID == Self.proProductID {
            isPro = transaction.revocationDate == nil
        }
    case .unverified(let transaction, let error):
        // Log but don't grant entitlement
        print("Unverified transaction \(transaction.productID): \(error)")
    }
}
```

---

### L2. `checkEntitlements()` also ignores `.unverified` in `currentEntitlements`

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-storekit/RiverDrop/StoreManager.swift:88-89`

Same pattern as L1. `Transaction.currentEntitlements` can yield `.unverified` results; they're silently skipped. Correct security posture, but worth logging.

---

## PRO GATING AUDIT — All paths accounted for

| Feature | Gate location | Type |
|---------|-------------|------|
| Rsync transfers (upload) | `TransferManager.swift:84,122,270` | Backend — `useRsync` requires `isPro` |
| Rsync transfers (download) | `TransferManager.swift:500` | Backend — same pattern |
| Directory uploads | `TransferManager.swift:86-89` | Backend — rejects when `!useRsync` |
| Dry-run download | `TransferManager.swift:650` + `MainView.swift:405` | Backend guard + UI paywall |
| Dry-run upload | `TransferManager.swift:690` + `LocalBrowserView.swift:234` | Backend guard + UI paywall |
| Apply sync download | `TransferManager.swift:732` + `MainView.swift:309` | Backend guard + UI re-check |
| Apply sync upload | `TransferManager.swift:817` + `MainView.swift:309` | Backend guard + UI re-check |
| Directory sync (download) | `TransferManager.swift:924` | Backend guard |
| Directory sync (upload) | `TransferManager.swift:1015` | Backend guard |
| Ripgrep search (remote) | `MainView.swift:440` | UI-only paywall |
| Ripgrep search (local) | `LocalBrowserView.swift:269` | UI-only paywall |
| Bookmarks (> 5) | `LocalBrowserView.swift:720` | UI-only paywall |

**No bypass found.** All rsync/dry-run/sync paths have backend `guard storeManager.isPro` checks in `TransferManager`. Ripgrep and bookmarks are UI-gated only but not exploitable since there's no alternative code path to invoke them.

---

## StoreKit Configuration File

**File:** `/Users/jakegearon/projects/RiverDrop/.dmux/worktrees/review-storekit/RiverDrop/RiverDrop.storekit`

- Product ID: `com.riverdrop.pro` — matches `StoreManager.proProductID`
- Type: `NonConsumable` — correct
- Price: `14.99` — matches intent
- `familyShareable: false` — intentional decision; worth confirming this is desired
- `_failTransactionsEnabled: false` — good for normal testing
- No subscription groups — correct for non-consumable

---

## Summary of required changes (priority order)

1. **H1** — Add `scenePhase` observer to re-check entitlements on foreground
2. **H2** — Auto-dismiss paywall on successful purchase
3. **H3** — Clear `errorMessage` before each StoreKit operation
4. **H4** — Retry `loadProducts()` on paywall appearance
5. **H5** — Show feedback for `.pending` purchase state
6. **M1** — Show "no purchases found" after empty restore
7. **M2** — Add loading state to restore button
