# Prior art and attribution

QEQ's private aggregate-device topology and hardware-input stream isolation are adapted from **CoreAudioTapKit** by Cole Stanfield, revision `aab395f1e8e5dd1bd369c3bbfcf5c6bdca85e099`:

- https://github.com/CJStanfield/CoreAudioTapKit
- Reference: `Sources/CoreAudioTapKit/SystemTapCapture.swift`
- QEQ adaptation: `QEQ/Sources/QEQAppSupport/AppAudioRoute.swift`

The library itself is not linked. QEQ adds app-scoped taps, muted-when-tapped teardown behavior, strict input isolation, a C callback, and independent three-band DSP.

MIT License

Copyright (c) 2026 Cole Stanfield

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Filter equations

Parametric biquad equations follow the Robert Bristow-Johnson [Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/), published by the W3C Audio Working Group. The response graph and playback use the same coefficient implementation.
