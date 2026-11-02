# Recommended Sunshine configurations

Two configurations for a 4K60 LAN stream, one per encoder backend, plus the reasoning that
makes them survive contact with real hardware.

| file | use when |
|---|---|
| `sunshine-vulkan-4k60.conf` | Vulkan Video encoding: RADV/ANV (AMD/Intel) or NVIDIA with Vulkan video. This is what the `vulkan` release build uses. |
| `sunshine-vaapi-4k60.conf` | VA-API encoding: Intel (iHD) or AMD (radeonsi), i.e. a build with `SUNSHINE_ENABLE_VAAPI`. |

Copy the one you need to `~/.config/sunshine/sunshine.conf` and add the machine-specific paths
(`apps_file`, `file_state`, `log_path`) if they do not live in the default location.

## What the two configs have in common

* `hevc_mode = 3` — 4K60 needs HEVC (or AV1). H.264 at 4K60 is starved at any bitrate a LAN
  will tolerate.
* `av1_mode = 1` — AV1 is off by default: better quality per bit, but it costs GPU time, and at
  4K60 the frame budget (16.7 ms) is the scarce resource. Raise to 3 if your GPU has headroom
  and your client supports it.
* `packetsize = 1024`, `fec_percentage = 20` — Moonlight's defaults. See the FEC ceiling below
  before changing them.
* `capture = wlr` — wlroots screencopy; `kms` is lower latency if your compositor allows it.
* `max_bitrate = 0` — always honour the bitrate Moonlight asks for. Set a Kbps cap to protect a
  shared link.

## The FEC ceiling (why frame size matters more than FEC settings)

`stream.cpp` packs one encoded frame into at most **4 FEC blocks** (the protocol gives 2 bits to
the block count). A frame bigger than that is sent with **no FEC at all**, and a single lost
packet then destroys the whole frame — that is the stutter you see exactly on scene changes.
The ceiling is

```
4 * floor(255*100 / (100 + fec_percentage)) * (packetsize + 12) bytes
```

| packetsize | fec_percentage | ceiling |
|---|---|---|
| 1024 | 20 | ~878 KB |
| 1024 | 10 | ~957 KB |
| 1456 | 20 | ~1.24 MB |
| 1456 | 10 | ~1.35 MB |

If the log says `Skipping FEC for abnormally large encoded frame`, the frames are crossing that
ceiling. Attack the frame size first (rate control below), then `packetsize`.

## Encoder-specific choices

**Vulkan** — `vk_tune = 2` (low latency), `vk_rc_mode = 2` (CBR), `vk_quality = balanced`.
`quality` does not fit a 16.7 ms budget on a consumer GPU at 4K60 (measured: 12.9 ms average,
22.9 ms worst with `balanced` on an RX 7600M XT, i.e. already close), and `vk_rc_mode = 4` (VBR)
trades pacing for scene-change quality.

**VA-API** — `vaapi_quality = balanced`, `vaapi_rc = vbr`, `vaapi_strict_rc_buffer = enabled`.
The strict single-frame VBV is the VA-API counterpart of the frame-size limit above: it stops
keyframes from ballooning. Sunshine applies VBR + single-frame VBV automatically on Intel and for
AV1; naming both explicitly makes it deterministic on AMD too.

## Verify on the machine, do not assume

```bash
just diagnose-stream-quality                      # 4K60 sample, FEC blocks, latency, UDP rate
just diagnose-stream-quality --bitrate 150000     # at the bitrate your client really uses
just diagnose-serverinfo                          # health: does 47984 answer /serverinfo
```

Read the report as follows:

* `frames sent without FEC (over the 4-block limit)` must be 0. If not, lower the bitrate, tighten
  rate control, or raise `packetsize`.
* the per-frame FEC block histogram shows how much headroom is left: a consistent `2` is
  comfortable, `4` means the next spike will be skipped.
* `Frame processing latency` max should stay under the frame interval (16.7 ms at 60 fps). An
  average near it means the GPU is the bottleneck, not the network.

## Verified

Both files were loaded into a real Sunshine build and exercised with a 4K60 session on an
AMD Radeon RX 7600M XT (RADV for Vulkan, radeonsi for VA-API), 50 Mbps, microphone on:

| config | encoder chosen | settings in effect | FEC blocks/frame | frames without FEC | capture+encode min/max/avg |
|---|---|---|---|---|---|
| vulkan | `hevc_vulkan` | `[vulkan] Encoder quality set to 2 (balanced), driver range: 0-4` | 1 | 0 | 11.40 / 26.20 / 12.48 ms |
| vaapi | `hevc_vaapi` | `[VAAPI] Quality level set to 16 (fastest level: 32)`, `[VAAPI] Using VBR rate control with single frame VBV size` | 1 | 0 | 6.70 / 22.40 / 7.44 ms |

On this GPU the VA-API path is the cheaper of the two at 4K60 (7.44 ms average against 12.48 ms),
and both leave the 16.7 ms frame budget room — but the max column shows a single late frame in
each run (session start), which is why the harness reports it.

Reproduce with:

```bash
just diagnose-stream-quality --conf configs/sunshine-vulkan-4k60.conf
just diagnose-stream-quality --conf configs/sunshine-vaapi-4k60.conf
```
