---
name: finish-before-next
description: Work one task fully to done (commit→push→deploy) before starting the next
metadata: 
  node_type: memory
  type: feedback
  originSessionId: a28d9126-d517-4423-90d2-26d2f9088c49
---

Finish each task completely before starting the next: implement → commit → push → deploy/activate → verify, then move on. "Always clean your plate." Do not fan out to the next item in a program while the current one is only partially landed.

**Why:** During the NAS-leverage program (#1 doc RAG … #6 read-replica) I was building foundations and moving on with pieces left un-activated (migration not pushed, indexer not run, search UX undecided). Boss wants each item shippable and live before the next starts.

**How to apply:** For multi-item programs, treat each item as done only when it's committed, pushed, deployed, and verified working in prod. Where a step is gated for me (e.g. `supabase db push` is classifier-blocked), surface it immediately and get it unblocked rather than deferring and continuing. See [[project-truxon]].
