# Mesh Rebalancing Scenarios

How PartyMesh automatically balances its K=5 topology when new nodes join a full cluster, and what happens in every edge case.

---

## Background: How the topology works

Each device maintains exactly **K=5 simultaneous connections**:
- **4 proximity slots** — filled by the physically closest peers (distance-based eviction applies)
- **1 random long-range slot** — exempt from distance eviction; preserves graph connectivity across the network

**Key numbers**

| Parameter | Value | Purpose |
|---|---|---|
| `maxNeighbors` | 5 | Hard cap on MCSession connections per device |
| `evictDistanceThreshold` | 4.0 m | Evict a proximity-slot peer if they drift beyond this |
| `reconnectDistanceThreshold` | 2.0 m | Hysteresis guard (evicted peer must return within this before re-queuing) |
| `evictionCooldown` | 30 s | How long an evicted peer is blocked from re-entering the candidate queue |
| `rebalanceInterval` | 15 s | How often the periodic rebalance timer fires |

**Architecture that makes selective eviction possible:** One `MCSession` per neighbour (not one shared session). Calling `sessions[peerID]?.disconnect()` drops exactly one edge without affecting anyone else.

---

## The two balancing paths

### Reactive path (event-driven, immediate)

Triggered inside `NISession.didUpdate` on every UWB measurement:

```
NI reports peer distance > 4.0m
  AND candidates are waiting
  AND peer is not the random-slot peer
  AND peer is the farthest proximity-slot peer
  AND no eviction already in flight for this peer
→ evict(peer:) → sessions[peerID]?.disconnect()
→ .notConnected fires → connectNextCandidate()
→ most recently seen candidate gets promoted
```

### Proactive path (timer-based, every 15 seconds)

`periodicRebalance()` runs three checks in priority order:

1. **Open slot + candidates waiting** → fill it immediately (catches cases where the reactive path missed a promotion)
2. **Farthest proximity peer still > 4m + candidates waiting** → evict (catches UWB going quiet between ticks)
3. **Random slot peer has a known NI distance (i.e. they're close) + candidates waiting** → rotate them out so a genuinely far peer fills the long-range slot

---

## Starting state

A, B, C, D, E — all close together (< 4m), all connected to each other. Every device has K=5 slots full, no candidates waiting.

```
     A
    /|\
   / | \
  B  |  E
  |\ | /|
  | \|/ |
  C──D──+
```

F, G, H now walk up to the cluster. What happens?

---

## How new nodes enter: the UUID tiebreaker

Both sides run Bonjour simultaneously. To prevent a double-invite race (both sides invite each other at the same time and immediately disconnect), only the device with the **lexicographically higher `sessionUUID`** sends the invitation.

When cluster device X discovers new node F:

| X's UUID vs F's UUID | What X does | What F does |
|---|---|---|
| `UUID_X > UUID_F` | X is the inviter → checks capacity → **F queued in X's `candidatePeers`** | F waits for X to invite |
| `UUID_X < UUID_F` | X returns early ("waiting for F to invite me") — **F NOT queued by X's browser** | F's browser finds X → F tries to invite X → X rejects (at capacity) |

The second row created a hidden bug: if F has the highest UUID of all 8 devices, every cluster device returns early in `browser(_:foundPeer:)` and nobody ever queues F. F's invitations all get rejected. **F is invisible to the system forever.**

### The fix (advertiser rejection → candidate queue)

When a cluster device receives an invitation and rejects it due to capacity, it now adds the peer to `candidatePeers`:

```swift
// In advertiser(_:didReceiveInvitationFromPeer:)
if atCapacity && !alreadyConnected && candidatePeers[peerID] == nil {
    candidatePeers[peerID] = CandidateInfo(sessionUUID: "", lastSeen: Date())
}
```

Now when F (high UUID) invites A and gets rejected, A adds F to candidates. The 15s timer will promote F when a slot opens.

---

## All cases traced

### Case 1 — Normal mixed UUIDs (most common)

Some cluster devices have UUID > F, some have UUID < F.

```
Step 1: Bonjour discovery
  Devices with UUID > F:  F queued via browser path           ✅
  Devices with UUID < F:  F invites them → rejected → queued via advertiser fix ✅

Step 2: 15s timer fires
  Check 1: totalActive == 5 → skip
  Check 2: farthest peer < 4m (tight cluster) → skip
  Check 3: randomSlotPeer has NI distance (they're close) → EVICT

  A evicts E (its random-slot peer)
  A: connectNextCandidate() → promotes F → F connects to A

Step 3: Cascade
  E loses the A edge only (per-peer MCSession — E still has B, C, D)
  E: connectNextCandidate() → promotes G or H from E's candidates

After ~15s: F is in, G or H may be in via E's freed slot.
```

**Topology after:**
```
A──F   (F connected to A, 4 more open slots on F)
A──B──C──D──E   (original cluster minus the A↔E edge)
E──G            (E promoted G from its candidates)
```

---

### Case 2 — F arrives first, G and H arrive 20s later

**Best case — F becomes the entry bridge.**

```
T=0s:  F approaches → queued as candidate on cluster devices
T=15s: Timer → random slot rotated → F connects to A
       F: 1 connection (A), 4 open slots remaining

T=20s: G and H approach
       F's browser discovers G and H immediately
       F has 4 open slots → F invites G and H directly

Result: F is the bridge. G and H connect to F without stressing the cluster.
```

New nodes entering after the first one don't need to fight for cluster slots at all — the first entrant absorbs them.

---

### Case 3 — All 3 arrive simultaneously

```
All 5 cluster devices queue F, G, H as candidates.
15s timer fires on all 5 devices (roughly simultaneously).

A: randomSlot=E → evicts E → promotes F
B: randomSlot=A → evicts A → promotes G
C: randomSlot=D → evicts D → promotes H

Cascade:
  E: lost A edge → E has [B, C, D] + 2 open slots → promotes next candidates
  A: lost B edge → A has [C, D, E] + 2 open slots
  D: lost C edge → D has [A, B, E] + 2 open slots

F, G, H each land on a different entry device.
F, G, H's browsers discover each other → they start connecting to each other.

Convergence: ~1–2 timer cycles (15–30s)
```

Note: simultaneous evictions don't cascade badly because each eviction only removes **one edge** (per-peer MCSession). No device loses all its connections.

---

### Case 4 — F has the highest UUID of all 8 devices

**Before the fix:** F invites all 5 → all reject. No cluster device queues F (they all returned early in `browser(_:foundPeer:)` waiting for F to invite them). F is stuck forever.

**After the fix:**
```
F invites A → rejected (at capacity) → A adds F to candidatePeers ✅
F invites B → rejected → B adds F to candidatePeers              ✅
F invites C, D, E → same                                         ✅

15s timer → check 3 → A evicts its random slot → connectNextCandidate() → F connects
```

---

### Case 5 — NI never reports distance (UWB obstruction)

`periodicRebalance` check 3 requires `connectedPeers[randomSlotPeer]?.distance != nil`. If UWB is obstructed (bodies blocking line of sight, metal surfaces), distance is `nil` → check 3 skips. If check 2 also skips (nobody exceeded 4m recently), the cluster stays locked.

**This is the one remaining gap.** No current mechanism forces a slot open when UWB is completely dark. A future fix would be a "stale NI slot" eviction: if a connected peer has had no NI update in > 60s AND candidates are waiting → treat them as a stale proximity peer and evict.

---

### Case 6 — Hysteresis: evicted peer immediately tries to re-enter

Without hysteresis, a peer hovering at exactly 4.1m would be evicted, see a slot open, re-connect, get evicted again — oscillating every few seconds.

```
Current protection:
  evict(peer:) → recentlyEvicted[peerID] = Date()
  browser(_:foundPeer:) → if Date() - evictedAt < 30s → skip (don't re-queue)
  After 30s → recentlyEvicted entry cleared → peer eligible again
```

The evicted peer can only re-enter the candidate queue 30 seconds after eviction, giving them time to physically move before they're reconsidered.

---

## Full rebalance decision tree

```
periodicRebalance() fires every 15s
         │
         ▼
  totalActive < K AND candidates waiting?
         │ YES → connectNextCandidate() → DONE
         │ NO
         ▼
  farthest proximity peer > 4m AND candidates waiting?
         │ YES → evict(farthestPeer) → DONE
         │ NO
         ▼
  at K=5 AND candidates waiting
  AND randomSlotPeer has NI distance (is actually nearby)?
         │ YES → randomSlotPeer = nil → evict(randomSlotPeer) → DONE
         │ NO
         ▼
       (no action — topology is optimal or UWB is dark)
```

---

## Summary: which mechanism handles which scenario

| Scenario | Entry mechanism | Time to integrate |
|---|---|---|
| Mixed UUIDs, new node approaches | `candidatePeers` via browser path | ~15s |
| New node has highest UUID (all cluster devices lower) | `candidatePeers` via advertiser rejection (fixed) | ~15s |
| Second+ new nodes after first one connected | First new node's own open slots (direct connection) | Immediate |
| All 3 new nodes arrive simultaneously | Parallel random slot evictions on cluster devices | ~15–30s |
| Connected peer drifts far (> 4m) | Reactive NI-triggered eviction | Seconds (next NI tick) |
| NI goes quiet (UWB obstruction) | 15s timer check 2 (catches stale far peers) | ~15s |
| Random slot peer is actually nearby | 15s timer check 3 (rotates for diversity) | ~15s |
| NI completely dark on all peers | **No mechanism — stuck** | Until natural disconnect |
| Evicted peer immediately re-appears | 30s cooldown blocks re-queue | 30s wait |

---

## What "balanced" means in this system

The system does **not** guarantee minimum-distance spanning trees or globally optimal topology. It guarantees:

1. Every device maintains at most K=5 connections (MCSession limit respected)
2. The farthest connected peer is evicted first when a closer candidate is available
3. At least one non-proximity edge per device (random slot) to prevent island formation
4. New nodes can always enter a full cluster within 1–2 timer cycles (~15–30s)
5. No oscillation at eviction boundaries (30s hysteresis cooldown)

The limitation: NI only measures **connected** peers. We don't know how far away a candidate is — `lastSeen` recency is the proxy. The most recently seen Bonjour peer is assumed to be physically closest, which holds in practice (Bonjour range ≈ WiFi range ≈ 30–50m) but is not guaranteed.
