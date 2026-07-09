# DRAFT — upstream MoltenVK issue: attachment-less render pass hard-aborts Apple AGX GPU

> **Status: DRAFT, not filed.** File at <https://github.com/KhronosGroup/MoltenVK/issues> after a
> quick re-verify that the repro still holds on the then-current MoltenVK (v1.4.1 as of 2026-07-09 —
> the same version we patch, so the findings apply to upstream unmodified). Written 2026-07-09 from
> the 2026-06-04 `0x010c` investigation (see `docs/03-known-issues.md` #2 and
> `moltenvk-build/session-patches/moltenvk-all-edits-latest.patch`).
>
> **Related upstream context (link these in the issue):**
> - [#1650 — FFXIV fails to run on Mac with >100GB RAM](https://github.com/KhronosGroup/MoltenVK/issues/1650)
>   — same root class (attachment-less pass → huge `renderTarget{Width,Height}` → tile-memory
>   preallocation), manifesting as a memory explosion.
> - [PR #1802 — WIP: Fix missing render area when rendering without attachments](https://github.com/KhronosGroup/MoltenVK/pull/1802)
>   — the maintainer's fix attempt (defer encoder creation to first draw, derive area from viewport);
>   **closed unmerged 2024** as complex/fragile. Our data below is a new, harder failure mode for the
>   same class: a deterministic **GPU abort**, not just memory growth.

---

## Proposed issue title

`Render pass with zero attachments and large framebuffer extent hard-aborts Apple Silicon GPU (Internal Error / IOGPUCommandQueueErrorDomain 268)`

## Environment

- MoltenVK **1.4.1** (also reproduced with the in-tree instrumentation build; stock behavior confirmed)
- macOS 26.x, Apple **M4 Pro** (AGX), 18 GB unified memory
- x86_64 process under **Rosetta 2** (Wine 11 / Whisky), Vulkan producer: **DXVK 1.10.3** (D3D9→Vulkan)
- App: Left 4 Dead 2 (32-bit D3D9, HDR rendering path)

## Symptom

On the first full-scene HDR frame, DXVK records a render pass with **zero attachments** (color,
depth, and stencil all absent) whose framebuffer extent is **16384×16384** (Metal max). When
MoltenVK creates the `MTLRenderCommandEncoder` for that pass, the AGX GPU **aborts the command
buffer**: `MTLCommandBufferErrorInternal` (`IOGPUCommandQueueErrorDomain` code **268**, logged as
GPU fault `0x0000010c`), surfaced to the app as `VK_ERROR_DEVICE_LOST`.

This is **not** an out-of-memory condition in the ordinary sense: process footprint at fault time is
~1.8 GB of 18 GB. It presents as a hard device fault, and the app freezes/loses the device.

## Isolation evidence (why we believe it's the encoder itself)

Using a command-buffer splitter (1 render pass per `MTLCommandBuffer`) plus synchronous submission
to attribute the fault precisely:

1. The faulting command buffer contains **only** the attachment-less pass.
2. It faults **even with every draw call AND every MSAA resolve skipped** — an *empty*
   attachment-less encoder faults on its own. It is the **pass's existence**, not its contents.
3. Stock MoltenVK 1.4.1 sets only `defaultRasterSampleCount` when a pass has no attachments,
   leaving `renderTargetWidth`/`renderTargetHeight` at 0 (an invalid 0×0 render target per Metal's
   requirement that attachment-less passes define an explicit extent).
4. Setting `renderTarget{Width,Height}` from the framebuffer extent (16384×16384) still faults —
   consistent with tile-memory sizing `W × H × samples` exceeding what AGX will grant.
5. **Clamping** the attachment-less pass's `renderTarget{Width,Height}` to 2048 → no fault.
6. **Skipping** encoder creation for the attachment-less pass entirely → no fault, and the app is
   fully playable (13,000+ passes skipped over a session with no visual regression — in this app the
   passes appear to be dead weight emitted by DXVK's D3D9 occlusion-query/HDR path).

(5) and (6) are both app-level workarounds shipped in our launcher's patched dylib; (6) is not a
general fix — an attachment-less pass can have real side effects (occlusion queries, storage
writes) — but (5) suggests a principled upstream mitigation: derive the extent, then clamp to a
bound the tile allocator can satisfy (or the viewport/scissor union, as PR #1802 explored).

## Minimal repro sketch

Vulkan sequence (no MoltenVK internals needed):

1. `VkRenderPass` with `attachmentCount = 0`, one subpass, no attachments.
2. `VkFramebuffer` with `attachmentCount = 0`, `width = height = 16384`, `layers = 1`
   (what DXVK 1.10.3 emits for D3D9 occlusion-query-only passes).
3. `vkCmdBeginRenderPass` / `vkCmdEndRenderPass` (no draws needed), submit, wait.
4. Observe `VK_ERROR_DEVICE_LOST` on M4-class hardware
   (`IOGPUCommandQueueErrorDomain` 268 in the unified log).

A standalone triangle-app repro has **not** been built yet (the isolation above was done in-app with
the splitter); offer it in the issue if the maintainers want one.

## Why upstream should care

- Vulkan explicitly permits attachment-less render passes (framebuffer dims are app-defined);
  D3D9-era translators (DXVK ≤ 1.10.x) emit them at max extent routinely, so any D3D9 game run
  through DXVK+MoltenVK on Apple Silicon can hit this as a hard freeze.
- #1650/#1802 framed the cost as *memory*; on AGX (M4 Pro, macOS 26) it is a **deterministic device
  loss** with no validation-layer warning. Even a documented clamp (or an `MVKConfiguration` knob)
  would turn a hard abort into correct behavior.

## Attachments to include when filing

- The two patch hunks from `moltenvk-build/session-patches/moltenvk-all-edits-latest.patch`
  (`MVKRenderPass.mm` extent-derivation + clamp; `MVKCommandEncoder` skip-no-attachment guard).
- A unified-log excerpt of the `0x0000010c` fault (regenerate via `./play-l4d2.sh --diag-gfx` with
  `L4D2_MVK_SKIP_NOATT=0`).
