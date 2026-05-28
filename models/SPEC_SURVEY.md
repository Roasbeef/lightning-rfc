# Splicing Spec Survey

This document catalogs every spec clause relevant to the splicing protocol
across the BOLTs, with `file:line` citations. It is the input to the P model —
every machine and every spec monitor in `src/` cites back here, and `FINDINGS.md`
cites back here too.

The survey is organized by sub-protocol (quiescence, interactive-tx, splice
proper, channel multi-commitment, reconnection, gossip, taproot) so it mirrors
the model decomposition in [ARCHITECTURE.md](./ARCHITECTURE.md).

## 1. Quiescence (`stfu`) — BOLT 2 §"Channel Quiescence"

**Spec range:** `02-peer-protocol.md:1490–1556`.

**Feature bit:** `option_quiesce` (34/35), `09-features.md:49`.

### Message

`stfu` (type 2), `02-peer-protocol.md:1497–1502`:

```
type: 2 (`stfu`)
data:
  channel_id : channel_id
  initiator  : u8
```

### Sender requirements (`02-peer-protocol.md:1506–1517`)

- MUST NOT send `stfu` unless `option_quiesce` is negotiated.
- MUST NOT send `stfu` if any of the sender's HTLC additions, HTLC removals,
  or fee updates are pending for either peer.
- MUST NOT send `stfu` twice.
- If replying to an `stfu`: MUST set `initiator = 0`.
- Otherwise: MUST set `initiator = 1`.
- MUST set `channel_id`.
- MUST now consider the channel to be quiescing.
- MUST NOT send an `update_*` message after `stfu`.

### Receiver requirements (`02-peer-protocol.md:1519–1524`)

- If it has already sent `stfu`: MUST now consider the channel to be quiescent.
- Otherwise: SHOULD NOT send further `update_*` messages; MUST reply with
  `stfu` once it can do so.

### Both nodes (`02-peer-protocol.md:1526–1530`)

- MUST disconnect after 60 seconds of quiescence if HTLCs are pending.
- Upon disconnection: the channel is no longer considered quiescent.

### Tied initiator (`02-peer-protocol.md:1544–1548`)

If both sides send `stfu` simultaneously, both set `initiator = 1`. The
"initiator" is then arbitrarily considered to be the channel funder (sender of
`open_channel`).

### Dependent-protocol contract (`02-peer-protocol.md:1532–1535`)

Dependent protocols MUST specify all states that terminate quiescence. No
explicit `resume` message exists — termination is implicit and protocol-specific.

---

## 2. Interactive Transaction Construction — BOLT 2 §"Interactive Transaction Construction"

**Spec range:** `02-peer-protocol.md:100–627`.

Reusable sub-protocol used by both dual-funded v2 channel open and by splicing.

### Messages

| Type | Name              | Spec line              |
|------|-------------------|------------------------|
| 66   | `tx_add_input`    | `02-peer-protocol.md:197`  |
| 67   | `tx_add_output`   | `02-peer-protocol.md:289`  |
| 68   | `tx_remove_input` | `02-peer-protocol.md:338`  |
| 69   | `tx_remove_output`| `02-peer-protocol.md:347`  |
| 70   | `tx_complete`     | `02-peer-protocol.md:367`  |
| 71   | `tx_signatures`   | `02-peer-protocol.md:408`  |
| 72   | `tx_init_rbf`     | `02-peer-protocol.md:466`  |
| 73   | `tx_ack_rbf`      | `02-peer-protocol.md:537`  |
| 74   | `tx_abort`        | `02-peer-protocol.md:583`  |

### Protocol invariants (model these as `Spec_InteractiveTx`)

- Turn-based exchange (`02:138–143`). The initiator starts with `tx_add_input`.
- Initiator uses even `serial_id`s, non-initiator uses odd `serial_id`s
  (`02:225–228`, `02:308–311`).
- Per-input non-duplication and validity (`02:230–246`).
- Per-output validity: ≥ dust_limit, ≤ MAX_MONEY, accepts P2WSH/P2WPKH/P2TR
  (`02:313–322`).
- Removal only of inputs/outputs the sender previously added (`02:356–365`).
- Termination on two consecutive `tx_complete` (`02:378–379`).
- At `tx_complete`: ≤252 inputs, ≤252 outputs, tx weight ≤ MAX_STANDARD_TX_WEIGHT,
  per-side input ≥ outputs, paid fee meets `feerate` (`02:383–393`).

### `tx_signatures` ordering (`02:429–451`)

Whichever peer has the lowest total `tx_add_input` value signs first; ties
broken by lowest `node_id`. Note for splicing: the splice initiator owns the
shared input, so 100% of the previous channel capacity is attributed to the
initiator (`02:1856–1859`).

### RBF (`02:466–582`)

`tx_init_rbf` / `tx_ack_rbf` reuse the same per-message structure. New `feerate`
must be ≥ `max(prev * 25/24, prev + 25)` sat/kw (`02:488–491`, rationale
`02:516–526`). Must double-spend prior attempts (`02:497–500`).

### `tx_abort` (`02:583–627`)

Cancels in-progress negotiation. MUST NOT have already sent `tx_signatures`.
On receive: MUST echo back if not already sent; if `tx_signatures` was already
sent, MUST NOT forget the channel until any input has been spent.

---

## 3. Channel Splicing — BOLT 2 §"Channel Splicing"

**Spec range:** `02-peer-protocol.md:1558–2043`.

**Feature bit:** `option_splice` (62/63), `09-features.md:59`.

### Messages

| Type | Name             | Spec line                  |
|------|------------------|----------------------------|
| 80   | `splice_init`    | `02-peer-protocol.md:1646` |
| 81   | `splice_ack`     | `02-peer-protocol.md:1713` |
| 77   | `splice_locked`  | `02-peer-protocol.md:2004` |

### `splice_init` sender requirements (`02:1666–1684`)

- Channel MUST be quiescent.
- Sender MUST be the quiescence initiator.
- `channel_ready` MUST have been sent and received.
- No other splice currently being negotiated.
- No other splice negotiated but not yet `splice_locked`.
- Sender MUST NOT have previously sent `shutdown`.
- `funding_feerate_perkw` is the splice tx feerate.
- `funding_contribution_satoshis`: negative for splice-out
  (|x| ≤ current balance), positive for splice-in.
- `require_confirmed_inputs` TLV may be set.
- SHOULD use a different `funding_pubkey`.

### `splice_init` receiver requirements (`02:1686–1711`)

For each violation below: MUST send `warning` and close, or `error` and fail:
- Channel not quiescent.
- Sending node not quiescence initiator.
- Another splice already being negotiated.
- Another splice negotiated but not yet locked.
- It has received `shutdown`.
- |negative contribution| > sender's current balance.

Otherwise:
- If `funding_feerate_perkw` unacceptable: MUST respond with `tx_abort`.
- If accepting: MUST respond with `splice_ack`.
- If rejecting: MUST respond with `tx_abort`.

### `splice_ack` semantics (`02:1726–1748`)

- Sender MAY set contribution to 0 (no liquidity added).
- SHOULD use a different `funding_pubkey`.
- Receiver: if it did not send `splice_init` → warning/error.
- Receiver: if accepting, MUST start `interactive-tx` session; else MUST
  send `tx_abort`.

### Splice-specific `interactive-tx` overlays

**`tx_add_input`** (`02:1756–1785`):
- Initiator MUST add the previous channel input via the `shared_input_txid`
  TLV (no `prevtx`, `prevtx_vout` is the previous funding output index).
- If `require_confirmed_inputs` was set: MUST NOT send unconfirmed inputs.
- Receiver MUST check `shared_input_txid` matches previous funding txid and
  `prevtx_vout` matches the previous funding output index; else `tx_abort`.

**`tx_add_output`** (`02:1787–1803`):
- Initiator MUST send at least one `tx_add_output` for the new channel funding
  output, with funding amount = previous capacity + Σ contributions.

**`tx_complete`** (`02:1805–1828`):
- Compute each side's new balance = old balance + their contribution.
- Fail negotiation if:
  - Not exactly one input spending the previous funding tx.
  - Not exactly one channel funding output matching the new pubkeys/contributions.
  - This is an RBF attempt and total fees < last successful splice tx's fees.
  - Either side added an extra output and their resulting balance < channel
    reserve for the new capacity.

**`commitment_signed`** (`02:1830–1869`):
- Sender creates a commitment tx spending the splice funding output, with
  contributions applied, same `feerate` and same `commitment_number`.
- MUST send signatures for pending HTLCs.
- MUST remember the splice tx details.
- Receiver MUST NOT respond with `revoke_and_ack`.
- If it should sign first per the `tx_signatures` ordering rule (with the
  full prior capacity attributed to the initiator), MUST send `tx_signatures`.
- On reconnection: if `next_funding` matches splice tx, MUST retransmit
  `commitment_signed`.

**`tx_signatures`** (`02:1871–1901`):
- MUST set `shared_input_signature` to a valid ECDSA sig of the prev funding
  output using the matching `funding_pubkey`.
- If `shared_input_signature` missing or invalid or non-LOW-S: error + fail.
- MUST consider the channel no longer quiescent.
- On reconnection: if `next_funding` matches splice tx, MUST retransmit
  `tx_signatures`.

### RBF for splices

**`tx_init_rbf`** for a splice (`02:1903–1941`):
- Channel MUST be quiescent.
- Sender MUST be the quiescence initiator.
- MAY send even if not the splice initiator.
- ≤ 10 pending RBF attempts (else MUST use a high enough feerate).
- MUST NOT send if previously sent `splice_locked`.
- MUST NOT send under `option_zeroconf`.
- MAY change `funding_output_contribution`.

Receiver: warning/error in symmetric cases; SHOULD `tx_abort` if "another RBF
attempt has been created recently" (window unspecified).

**`tx_ack_rbf`** for a splice (`02:1961–1974`):
- MAY change `funding_output_contribution`.
- If |negative contribution| > sender's balance: warning/error.

### `splice_locked` (`02:2004–2043`)

```
type: 77 (`splice_locked`)
data:
  channel_id : channel_id
  splice_txid: sha256
```

- When any splice tx reaches acceptable depth: MUST send with that txid.
- Under `option_zeroconf`: SHOULD send immediately after `tx_signatures`.
- If receiver's pending splice txs don't include `splice_txid`: warning or error.

Once both sent and received:
- If txids match: MUST stop sending `commitment_signed` for RBF attempts and
  ancestor tx; MAY discard them. If `announce_channel`: MUST send
  `announcement_signatures` with the splice's `short_channel_id`.
- If txids are for different RBF candidates: SHOULD ignore; MAY error+fail.

### Splice Completion semantics (`02:1976–2002`)

- After `tx_signatures` but before lock: channel operations resume; HTLCs must
  be valid against ALL active commitments.
- Track multiple commitment txs (one per pending funding); exchange signatures
  for each.

---

## 4. Channel multi-commitment & batched signing — BOLT 2 + splicing-test.md

- HTLC update validity must hold across every active commitment
  (`bolt02/splicing-test.md:23–24, 49`).
- `start_batch` precedes a sequence of `commit_sig` messages; `batch_size`
  equals the number of active commitments (`splicing-test.md:115–128`).
- On `splice_locked`, late `commit_sig` for the now-discarded RBF / ancestor
  funding txids MAY be ignored by the receiver
  (`splicing-test.md:170–172, 291–297`).

---

## 5. Reconnection / `channel_reestablish` — BOLT 2 §"Message Retransmission"

**Spec range:** `02-peer-protocol.md:3360–3560`.

### Message TLVs

- Type 1: `next_funding` = (`next_funding_txid`, `retransmit_flags`)
  - bit 0 = `commitment_signed`
- Type 5: `my_current_funding_locked` = (`txid`, `retransmit_flags`)
  - bit 0 = `announcement_signatures`

### Sender rules (`02:3435–3467`)

- If sent `commitment_signed` for an interactive tx but not yet received
  `tx_signatures`: MUST include `next_funding` TLV with txid; bit 0 set iff
  `commitment_signed` not yet received from peer.
- Otherwise: MUST NOT include `next_funding`.
- If `option_splice` negotiated and at least one splice has acceptable depth
  while disconnected: include `my_current_funding_locked` with the latest such
  txid.
- Otherwise, if already sent `splice_locked` for any tx: include with that
  txid.
- Otherwise, if already sent `channel_ready`: include with the channel funding
  txid.
- Else: MUST NOT include `my_current_funding_locked`.
- If `announce_channel` set and no `announcement_signatures` received for that
  txid: set announcement bit in retransmit_flags.

### Receiver rules (`02:3516–3543`)

- If `next_funding_txid` matches latest interactive tx and `tx_signatures` not
  received: retransmit `commitment_signed` if bit set; send own
  `tx_signatures` if it should sign first.
- If `next_funding` set on both sides but txids differ: error + fail.
- If `next_funding` set on our side but ours doesn't match received: send
  `tx_abort` so peer can forget.
- If `my_current_funding_locked` matches a pending splice tx for which we
  haven't received `splice_locked` yet: MUST process as receiving
  `splice_locked`.
- If announcement_signatures bit set in remote's flags and we're ready to send
  announcement_signatures: MUST retransmit.

### Disconnect-time invariant

`02:3419–3425`: On disconnection, reverse any uncommitted `update_*` messages
that have not been committed. The exception is `update_fulfill_htlc` whose
preimage may have been used.

### Test-vector scenarios (`bolt02/splicing-test.md`)

| §                                                       | Scenario                                                    |
|---------------------------------------------------------|-------------------------------------------------------------|
| Successful single splice                                | Happy path (`splicing-test.md:64`)                          |
| Multiple splices with concurrent `splice_locked`        | RBF + late commit_sig drop (`splicing-test.md:167`)         |
| Disconnect with one side sending commit_sig             | One-side abort path (`splicing-test.md:313`)                |
| Disconnect with both sides sending commit_sig           | Resume signatures (`splicing-test.md:377`)                  |
| Disconnect with one side sending tx_signatures          | Resume tx_sigs (`splicing-test.md:441`)                     |
| Disconnect with both sides sending tx_signatures        | Resume tx_sigs both-ways (`splicing-test.md:502`)           |
| Disconnect + channel updates                            | Updates after tx_sigs survive reconnect (`splicing-test.md:563`)|
| Disconnect with concurrent splice_locked                | `my_current_funding_locked` as splice_locked (`splicing-test.md:651`)|
| Disconnect after tx_sigs + one-side commit_sig          | Resume channel update (`splicing-test.md:731`)              |
| Disconnect after tx_sigs + both-side commit_sig (no R&A)| Resume with R&A retransmit (`splicing-test.md:817`)         |
| Disconnect after tx_sigs + both-side commit_sig         | Resume with second-side R&A (`splicing-test.md:904`)        |

---

## 6. Channel close interaction with splice — BOLT 2 §"Channel Close"

- `MUST NOT send shutdown if there is a splice transaction that isn't locked
  yet` (`02:2155`).
- `MUST NOT send splice_init if it has previously sent shutdown`
  (`02:1673`).
- Receiver of `splice_init` after `shutdown` received: warning/error
  (`02:1699–1701`).

---

## 7. Gossip after splice — BOLT 7 §"announcement_signatures"

**Spec range:** `07-routing-gossip.md:85–285`.

- After both peers exchanged `splice_locked` AND acceptable depth: MUST send
  `announcement_signatures` for the matching splice tx (`07:89–90`).
- On reconnect: if announcement_signatures bit set in
  `my_current_funding_locked.retransmit_flags`: MUST retransmit
  `announcement_signatures` (`07:98–101`).
- Recipient: SHOULD defer handling until after own `splice_locked` sent
  (`07:113–114`).
- When announcing a splice: MUST set `short_channel_id` to the confirmed splice
  tx (`07:180–183`); SHOULD keep relaying via prior `short_channel_id`s
  (`07:184–185`); SHOULD send new `channel_update` using the latest SCID
  (`07:186–187`).
- 72-block delay before forgetting spent channel funding (`07:281–285`).

---

## 8. Taproot nonce coordination — `bolt-simple-taproot.md`

**Spec range:** `bolt-simple-taproot.md:1135–1172`.

- Each splice tx MUST have a distinct TXID and fresh nonce in `next_local_nonces`.
- Both parties MUST include nonces for all active commitments in their
  `next_local_nonces` map.
- Nonces MUST NOT be reused across splice transactions.
- Nonces MUST be communicated in the next `revoke_and_ack` or
  `channel_reestablish` after splice initiation.

---

## Cross-component constraints

These cannot live in a single sub-protocol's section — they bind multiple
machines together. They become whole-system spec monitors.

1. **Quiescence ⇒ Splice trigger**: splice/RBF init events are gated by
   `Quiescent ∧ sender == quiescence_initiator`.
2. **Splice exit ⇒ Quiescence release**: receipt of `tx_signatures` lifts
   quiescence (`02:1886`, `02:1899–1900`).
3. **Active commitments agreement**: at every observable boundary (after each
   message exchange completes), the set of active funding txids on each peer
   is equal.
4. **Capacity conservation**: for every splice, the new capacity equals the
   sum of previous balances plus contributions from `splice_init` (and
   `splice_ack`), modulo agreed fees.
5. **Reserve preservation**: any party that adds an extra (non-funding) output
   MUST end up at or above the reserve for the new capacity.
6. **Lock monotonicity**: once both peers have exchanged `splice_locked` for
   the same `splice_txid`, RBF candidates and ancestors are no longer signed
   for; their commitment messages MAY be ignored.
7. **Gossip post-lock**: `announcement_signatures` only emitted after both
   sides have `splice_locked` AND the tx has acceptable depth.
8. **Shutdown vs unlocked splice exclusion**: cannot send `shutdown` while any
   splice is pending and unlocked.
