# Event transaction queue — independent integration stage

Original ExamGuard RTL, reusing `../event_request_fifo/`. No third-party RTL.
Not registered in the main XPR; the running bitstream remains examguard14.

`exam_fsm` now emits four registered request lanes: flow/auth, object, gaze,
video. Set `PARALLEL_EVENTS=1` to independently sample video even when a new
object arrives. The default `0` preserves the legacy panel behaviour.

`event_transaction_queue` snapshots each accepted lane into a 256-bit record:

| Bits | Value |
|---|---|
| 255:224 | device ID, supplied by caller |
| 223:192 | boot ID, supplied by caller |
| 191:160 | exam session ID, supplied by caller |
| 159:96 | 64-bit event ID, allocated on acceptance, starts at 1 |
| 95:32 | source timestamp in ms, supplied by caller |
| 31:24 | source index 0–3 |
| 23:16 | reserved zero |
| 15 | reserved zero (FSM producer contract) |
| 14:12 | stage snapshot |
| 11:10 | authorized identity snapshot |
| 9:8 | risk snapshot |
| 7:0 | event code |

This is an **internal draft layout**, not a UART/UDP wire protocol. It does not
yet carry frame/window IDs, AI bounding boxes, or health metadata. Reconcile
those fields with protocol v2 before main-project integration.

## Timing and admission contract

- Single clock, synchronous active-high reset. No CDC and no combinational bypass.
- `request` is a pulse-attempt mask, not a retrying ready/valid interface.
- All metadata must be aligned with the request. FSM outputs are registered;
  delay the source timestamp/session/config snapshot by the SAME cycle. The TB
  demonstrates this with `request_ms` and `request_session` registers.
- Control transitions carry the resulting stage (auth=VERIFIED, submit=SUBMITTED,
  ack=END). Concurrent detector events carry the sampled EXAM stage. A same-cycle
  submit does not retroactively erase detector requests.
- Low source index wins admission when capacity is insufficient. This is fixed
  priority, not fairness or severity sorting. Panel priority in parallel mode is
  flow > object > gaze > video; legacy `event_seq` counts panel updates only.
- `accepted`/`rejected` are combinational sampling-edge masks. Store/observe them
  at that edge. Each accepted request gets one contiguous ID; rejection consumes
  no ID. Output uses `event_valid && event_ready`, one record per cycle.
- A full queue can admit one request if the old head is delivered that cycle.
  Data stays immutable under backpressure even if live metadata changes.
- ID space never wraps. At exhaustion, requests are rejected and counted until
  reset. `ID_WIDTH=1..64` is for boundary verification; deployment default is 64.
- Reset discards pending records and resets IDs/counters. **The caller must supply
  a different boot ID before accepting new events after reset.** This module does
  not generate a persistent or random boot identity, detect config changes, or
  guarantee uniqueness across power cycles. Device/boot/session allocation is
  still C01 integration work; the tests use externally supplied values.
- Counters saturate at 32-bit all-ones. `rejected_count` includes both queue-full
  and ID-exhaustion rejection. `high_water` tracks peak occupancy.
- FSM episode latches advance on detection, regardless of queue acceptance.
  Rejected requests are **lost but counted**, not automatically retried. Connect
  rejection/health reporting before claiming no silent loss in the full system.

This small multi-write register queue is not a frame store. For image data use
the separately planned DDR/FIFO/DMA path.

## Verification

From `D:\fpga_race`, using Vivado 2018.3:

```powershell
& "D:\vivado\vivado2018.3\Vivado\2018.3\bin\vivado.bat" -mode batch -source sim_event_transaction_queue.tcl
& "D:\vivado\vivado2018.3\Vivado\2018.3\bin\vivado.bat" -mode batch -source check_event_transaction_queue.tcl
& "D:\vivado\vivado2018.3\Vivado\2018.3\bin\vivado.bat" -mode batch -source check_exam_fsm_parallel.tcl
```

See [verification report](../../../sim/test_matrix.tsv)
for coverage, resource usage, constraints and remaining work.
