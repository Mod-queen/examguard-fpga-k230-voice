# Event request FIFO

Standalone ExamGuard event-control building block; not yet in the main XPR.
Original implementation, no third-party RTL dependency.

One clock, pulse inputs, multiple inserts per cycle, one ready/valid output.
Payload is opaque; source time/frame must be captured before enqueue.
Lower source index wins when space is insufficient. Rejections are explicit.
Reset flushes everything; counters saturate. No deduplication or CDC.

Specification and verified configurations:
[`docs/verification_2026-10-11_event_request_fifo.md`](../../../sim/test_matrix.tsv).

Run from the workspace with Vivado 2018.3:

```powershell
& "D:\vivado\vivado2018.3\Vivado\2018.3\bin\vivado.bat" -mode batch -source sim_event_request_fifo.tcl
& "D:\vivado\vivado2018.3\Vivado\2018.3\bin\vivado.bat" -mode batch -source check_event_request_fifo.tcl
```

This is a small register-based multi-insert queue. For image data use a separately
verified stream FIFO/DMA; do not scale this into a frame store.
