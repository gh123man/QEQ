# Performance profiling

## 2026-11-03 open-popup rendering

Live telemetry previously invalidated the whole controls model at 30 Hz. SwiftUI also interpolated spectrum shapes every display frame, and native meter animation repainted slider tracks, knobs and shadows. Sampling pointed to rendering, layout/accessibility updates and control drawing rather than audio DSP.

Changes:

- Separate telemetry publication from settings/discovery; only the visualizer and status subscribers consume it.
- Feed native meters and spectrum surfaces directly, without a SwiftUI view update for every reading.
- Interpolate the same spectrum paths with Core Animation over the same 33 ms duration. Keep all 192 bins and the 30 Hz analysis cadence.
- Retain slider track, knob, shadow and unity-marker layers. The existing 50/80 ms meter transition updates only the fill geometry at up to 60 fps; native slider input and accessibility stay in place.
- Publish status text only when its displayed value changes. There is no throttle or delay.

Matched three-app synthetic UI workload on this Mac, Release builds; median of four two-second samples per state, excluding transition warm-ups (100% = one CPU core):

| View | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| Overview with three spectrum overlays | 38.4% | 9.4% | 75% |
| One app EQ expanded, three live meters | 47.9% | 17.6% | 63% |
| Popup closed, synthetic input paused | 0.39% | 0.36% | effectively unchanged |

These are whole-QEQ-process UI-only measurements, not end-to-end playback or total system/WindowServer CPU. The final pass ran without sampling or builds. The earlier baseline included sampling near the end of the overview interval, producing one 54.7% outlier; its other overview samples were 38.1–38.4%, so medians are reported. A preceding optimized pass measured 7.9% / 16.2%; expect variation with display and system load. No resolution, update-rate, smoothing, audio-buffer or DSP changes were used to obtain these savings.

The final live integration pass also received actual audio from one RuneLite route during the reopened overview (peaks 0.029–0.052). Those four samples measured 14.5–16.5% CPU, with continuously increasing callback frames. Startup/source activity changed earlier in that pass, so it is not a controlled playback before/after comparison or an acoustic dropout test.

Validation: 67 Swift tests, eight release-tooling tests, strict formatting and universal Release build pass. Native screenshot checks exercise empty/populated, app/global EQ and height limits, plus immediate spectrum layer targets, unchanged controls-model notification count, retained graph identity, stable volume position and panel geometry during audio-only updates. The full screenshot fixtures were rendered and visually compared with the previous UI.

## 2026-11-03 popup/audio isolation

Opening the popup used to acquire muted process taps for flat apps, and closing it released those routes. That changed the playback topology merely to show a meter. While enabled, QEQ now keeps routes for non-excluded apps playing on the selected output, independent of popup visibility or EQ selection. Flat/bypassed settings update coefficients without removing a route. Paused apps still release routes; global bypass and quit restore system audio.

The realtime callback continuously fills its existing preallocated snapshot while a route is running. UI subscriptions only read snapshots and start/stop the 30 Hz FFT timer. They cannot invoke discovery, health checks, DSP configuration, or route lifecycle operations. FFT plans stay cached with live routes. This trades some background work during flat playback for eliminating popup-driven audio handoffs; there is still no callback or FFT work when no apps are playing.

Validation on this Mac:

- 100 popup open/select/close cycles left discovery count and route lifecycle unchanged.
- 10,000 synthetic 64-frame stereo callbacks remained bit-for-bit correct while another thread repeatedly read snapshots and stalled between reads.
- The native 30-second popup profiler kept one hardware route active across visibility changes with monotonically increasing callback frames and no counter resets. That source was silent, so this verifies route continuity, not an acoustic dropout measurement.
- Isolated Release benchmarks measured 0.005 ms per 256-frame stereo DSP block both with and without snapshot capture, and 0.076 ms for the stereo FFT plus 192 display bins. These are rounded component wall times, not end-to-end latency or whole-process CPU.

The callback's atomic types are compile-time checked to be lock-free. It has no UI/runtime calls, allocation, blocking locks, logging, or retry loops. This removes QEQ's popup-driven interruption path; OS scheduling, device changes, and driver faults remain outside that guarantee.

## 2026-11-02 findings

A sample of the running RC.6-era Release app showed repeated LaunchServices metadata queries, IconServices lookups and SwiftUI rendering. An audio callback was active during that capture, so it is **not a verified idle baseline**. Stack samples include blocked threads and are not a CPU percentage breakdown.

Release microbenchmarks on this Mac (48 kHz stereo; warm-up excluded):

| Work | Before | After |
| --- | ---: | ---: |
| Audio-app discovery | 7.90 ms | 4.73 ms with warm metadata cache |
| 16,384-frame stereo FFT + 96 spectrum bins | 0.127 ms | 0.069–0.073 ms |
| 241-point EQ response curve | 0.024 ms | unchanged |
| 10-band DSP, 256 stereo frames | 0.004 ms | unchanged |
| Same DSP with analysis capture | 0.005 ms | unchanged |

These are component wall times, not whole-app CPU or acoustic latency. Discovery depends on the apps/processes running. The DSP benchmark includes six non-flat bands in the ten-band chain. At 48 kHz, each 256-frame block represents 5.33 ms of audio; the filter callback was not the main optimization target.

Changes:

- Stop the 15 Hz analysis timer when the popup has no route to visualize. Discovery restarts it when playback begins; bypass and closing the popup stop it.
- Skip identical spectrum and UI publications, including steady silence.
- Read running-app bundle IDs once per discovery pass instead of querying LaunchServices for every helper/parent pairing.
- Cache app icons while their rows are present. Cache resolved process display metadata for up to 30 seconds; invalidate on process/PID/bundle changes and retry unresolved helpers immediately. Playback state and device routing are never cached.
- Reuse FFT work buffers, vectorize window multiplication, and compute the Hann window and normalization once. Frequency bins, stereo power, and displayed dB values retain their existing semantics.

One-second discovery, route recovery, DSP coefficients, smoothing, limiter, audio buffers and permissions are unchanged. More invasive DSP changes are not justified by these measurements. Full local correctness/hardware tests and the universal app build pass, including pause/resume, bypass and reopen regression coverage for the analysis timer.

## Running-app idle result

The first optimized build (`7fa2127`, before the final bundle-ID lookup improvement) completed its native 30-second profiling pass on this Mac, with zero playing apps, zero active routes and zero output peak in every sample. Excluding the two-second warm-up after each popup transition:

| Popup | Mean CPU, one core = 100% | Range | Samples |
| --- | ---: | ---: | ---: |
| Closed | 1.11% | 1.09–1.12% | 4 × 2 seconds |
| Open | 1.48% | 0.90–3.97% | 8 × 2 seconds |

This is a short **post-change** idle measurement, not an idle before/after comparison. The initial sample had an active route and is not comparable. Playback measurements are synthetic by user preference; actual source/device playback CPU has not been remeasured. The remaining once-per-second hardware discovery is a future candidate for event-driven notifications, with the current polling kept for route/device recovery reliability.

## Reproduce

Run component benchmarks alone in Release mode (they do not play or capture audio):

```sh
QEQ_PROFILE=1 swift test -c release --package-path QEQ --filter profileComponents
```

For actual process CPU and route state:

```sh
mkdir -p QEQ/.dist/profiles
./run.sh --no-build --profile "$PWD/QEQ/.dist/profiles/live.jsonl"
```

This restarts QEQ and records 30 seconds of numeric counters: 10 seconds with its own popup open, 10 closed, then 10 open. It leaves the popup open. It does not change EQ, playback, or saved settings, and does not record audio or the desktop. The parent output directory must exist. Profiling is opt-in and dormant on normal launches.

Run once with playback paused, and again with the same source playing at the same volume/output. Each JSON line contains process CPU (100% = one core), actual popup visibility, route count, per-app cumulative callback frames, Core Audio's playing-app count and the latest output peak. Discard `warmup` samples. A playing app can keep a silent stream open, so distinguish `activeRoutes == 0` from an active route with `latestPeak == 0`. Peak is the most recent discovery reading, not the maximum over the entire two-second interval. Compare the same conditions; don't mix open-popup CPU with background CPU.

For a repeatable UI-only animation workload:

```sh
./run.sh --no-build --profile-ui /tmp/qeq-ui.jsonl
```

This replaces the running local app with an isolated preview model: three simulated apps with 192-bin spectra and live meter targets at 30 Hz. It shows the overview for 10 seconds, closes for 10 seconds, then expands one app EQ for 10 seconds. The recorder stops the signal after 30 seconds. It neither starts the audio engine nor reads/writes mixer settings or registers a login item. Restart normally with `./run.sh --no-build` afterward. Synthetic route counts are fixture data, not hardware measurements. Compare `editor` and `panelVisible` groups after excluding `warmup` rows; keep other benchmarks/builds and sampling out of the measurement interval.

For call stacks, use `sample <QEQ-pid> 8 1 -file /tmp/qeq.sample.txt` in a separate pass. Keep local logs and samples out of git.
