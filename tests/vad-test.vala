/* gnome-linto
 *
 * Copyright (C) 2026 Benjamin Bellamy
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

const int FRAME = 480;

// A square wave: +amp for half_period samples then -amp, repeated. half_period
// controls the zero-crossing rate; 0 makes silence. Energy is amp*amp.
int16[] make (int frames, int half_period, int amp) {
    int n = frames * FRAME;
    var a = new int16[n];
    for (int i = 0; i < n; i++) {
        if (half_period <= 0) {
            a[i] = 0;
        } else {
            bool high = ((i / half_period) % 2) == 0;
            a[i] = (int16) (high ? amp : -amp);
        }
    }
    return a;
}

int16[] silence (int frames) {
    return make (frames, 0, 0);
}

// ~0.025 crossings/sample (period 80): inside the speech band, "voice-like".
int16[] voiced (int frames, int amp) {
    return make (frames, 40, amp);
}

// ~1.0 crossings/sample: broadband, above the speech ZCR band.
int16[] broadband (int frames, int amp) {
    return make (frames, 1, amp);
}

// A peaky, low-ZCR signal: near-zero most of the time with a sharp +/- spike at
// a low fundamental (period 80). Its PEAK is amp but its mean-square energy is
// far lower (~1/40), like speech vs steady noise.
int16[] peaky (int frames, int amp) {
    int n = frames * FRAME;
    var a = new int16[n];
    for (int i = 0; i < n; i++) {
        int p = i % 80;
        if (p == 20) {
            a[i] = (int16) amp;
        } else if (p == 60) {
            a[i] = (int16) (-amp);
        } else {
            a[i] = 0;
        }
    }
    return a;
}

void test_silence () {
    var v = new Linto.Vad ();
    v.push (silence (30), 0.0, false);
    assert (!v.speaking);
}

void test_voice_latch_and_release () {
    var v = new Linto.Vad ();
    v.push (silence (3), 0.0, false);          // seed the floor low
    v.push (voiced (5, 10000), 0.0, false);
    assert (v.speaking);                        // loud voice latches
    v.push (silence (30), 0.0, false);
    assert (!v.speaking);                       // releases after the hangover
}

void test_below_manual_threshold () {
    var v = new Linto.Vad ();
    // Voice-like but quiet (energy 250000), held below a manual gate of 1e7.
    v.push (silence (3), 1.0e7, false);
    v.push (voiced (40, 500), 1.0e7, false);
    assert (!v.speaking);                       // the gate blocks it
}

void test_broadband_noise_never_latches () {
    var v = new Linto.Vad ();
    v.push (silence (3), 0.0, false);
    // Persistent broadband noise with the gate off: rejected by ZCR, so it
    // never latches (this is the reported "never pauses" case).
    v.push (broadband (60, 3000), 0.0, false);
    assert (!v.speaking);
}

void test_automatic_detects_quiet_voice () {
    var v = new Linto.Vad ();
    v.push (silence (3), 0.0, true);
    // Quiet voice (~-32 dBFS) with nothing loud before it: must be detected;
    // the automatic gate is a few times the low ambient floor, not a fraction
    // of some peak.
    v.push (voiced (5, 800), 0.0, true);
    assert (v.speaking);
    v.push (silence (30), 0.0, true);
    assert (!v.speaking);
}

void test_automatic_transient_does_not_poison_gate () {
    var v = new Linto.Vad ();
    v.push (silence (3), 0.0, true);
    v.push (voiced (2, 30000), 0.0, true);      // a loud near-clip transient
    v.push (silence (30), 0.0, true);           // it passes and releases
    // Quiet speech afterwards must still be detected. The old peak-hold gate
    // would stay ~20 dB below the transient for many seconds and reject it.
    v.push (voiced (5, 800), 0.0, true);
    assert (v.speaking);
}

void test_peaky_speech_over_ambient () {
    var v = new Linto.Vad ();
    // Flat ambient (crest factor ~1) sets the floor and is not voice.
    v.push (voiced (20, 1000), 0.0, true);
    assert (!v.speaking);
    // A peaky signal with the same low ZCR: its peak clears the gate even
    // though its mean-square energy would not. Keyed on peak, it is detected;
    // an RMS-based detector would miss it (the reported real-world failure).
    v.push (peaky (10, 2500), 0.0, true);
    assert (v.speaking);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/vad/silence", test_silence);
    Test.add_func ("/vad/peaky-speech-over-ambient",
        test_peaky_speech_over_ambient);
    Test.add_func ("/vad/voice-latch-and-release", test_voice_latch_and_release);
    Test.add_func ("/vad/below-manual-threshold", test_below_manual_threshold);
    Test.add_func ("/vad/broadband-never-latches",
        test_broadband_noise_never_latches);
    Test.add_func ("/vad/automatic-detects-quiet-voice",
        test_automatic_detects_quiet_voice);
    Test.add_func ("/vad/automatic-transient-does-not-poison-gate",
        test_automatic_transient_does_not_poison_gate);
    return Test.run ();
}
