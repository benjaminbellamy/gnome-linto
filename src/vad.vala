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

namespace Linto {
    // A small classic voice activity detector for 16 kHz mono S16LE audio, with
    // no external dependency. It combines short-term energy and zero-crossing
    // rate with an adaptive noise floor: steady background noise (which the
    // floor tracks) does not read as speech, while intermittent voice does. So
    // a long stretch of constant noise stays "not speaking".
    public class Vad : Object {
        // 16 kHz mono, so a 30 ms analysis frame is 480 samples.
        private const int FRAME_SIZE = 480;
        // Voice needs energy several times above the tracked noise floor.
        private const double MARGIN = 4.0;
        // The floor never drops below this, so near-digital-silence does not
        // make the ratio explode on the first real sample.
        private const double MIN_FLOOR = 300.0;
        // Slow upward tracking of the noise floor (per non-speech frame); the
        // floor drops at once to follow a quieter level.
        private const double FLOOR_RISE = 0.05;
        // Zero-crossing rate band for speech (crossings per sample). Rejects a
        // near-DC rumble (too low) and broadband hiss (too high).
        private const double ZCR_MIN = 0.02;
        private const double ZCR_MAX = 0.30;
        // Consecutive voice frames to latch "speaking" on (about 60 ms), and how
        // long to hold it after the last voice frame (about 750 ms) so short
        // gaps between words do not read as silence.
        private const int ATTACK_FRAMES = 2;
        private const int HANGOVER_FRAMES = 25;

        // The latched speech state. The onset is confirmed after ATTACK_FRAMES,
        // so up to about 60 ms at the very start of speech precedes it.
        public bool speaking { get; private set; default = false; }

        private double noise_floor = MIN_FLOOR;
        private bool seeded = false;
        private int voice_run = 0;
        private int hangover = 0;
        // Samples left over from the last push that did not fill a whole frame.
        private int16[] pending = new int16[0];

        // Feeds more samples (16 kHz mono S16LE) and returns the current latched
        // speaking state. Any partial trailing frame is kept for the next call.
        public bool push (int16[] samples) {
            int old = this.pending.length;
            this.pending.resize (old + samples.length);
            for (int i = 0; i < samples.length; i++) {
                this.pending[old + i] = samples[i];
            }

            int off = 0;
            while (off + FRAME_SIZE <= this.pending.length) {
                this.process_frame (this.pending, off);
                off += FRAME_SIZE;
            }

            // Keep only the trailing partial frame for the next call.
            this.pending = this.pending[off : this.pending.length];
            return this.speaking;
        }

        private void process_frame (int16[] buf, int off) {
            double energy = 0.0;
            int crossings = 0;
            int16 prev = buf[off];
            for (int i = 0; i < FRAME_SIZE; i++) {
                int16 s = buf[off + i];
                energy += (double) s * (double) s;
                if ((s >= 0) != (prev >= 0)) {
                    crossings++;
                }
                prev = s;
            }
            energy /= FRAME_SIZE;
            double zcr = (double) crossings / FRAME_SIZE;

            // Seed the floor from the first frame so ambient noise present at
            // startup does not read as speech while the floor catches up.
            if (!this.seeded) {
                this.noise_floor = double.max (energy, MIN_FLOOR);
                this.seeded = true;
            }

            bool frame_voice = energy > this.noise_floor * MARGIN
                && zcr >= ZCR_MIN && zcr <= ZCR_MAX;

            if (frame_voice) {
                this.voice_run++;
                if (this.voice_run >= ATTACK_FRAMES) {
                    this.speaking = true;
                    this.hangover = HANGOVER_FRAMES;
                } else if (this.speaking) {
                    this.hangover = HANGOVER_FRAMES;
                }
            } else {
                this.voice_run = 0;
                if (this.speaking) {
                    if (this.hangover > 0) {
                        this.hangover--;
                    }
                    if (this.hangover == 0) {
                        this.speaking = false;
                    }
                }
            }

            // Track the noise floor only outside speech (never let speech or its
            // hangover inflate it): drop at once to a quieter level, rise slowly
            // toward a louder steady level.
            if (!this.speaking && !frame_voice) {
                if (energy < this.noise_floor) {
                    this.noise_floor = energy;
                } else {
                    this.noise_floor = this.noise_floor * (1.0 - FLOOR_RISE)
                        + energy * FLOOR_RISE;
                }
                if (this.noise_floor < MIN_FLOOR) {
                    this.noise_floor = MIN_FLOOR;
                }
            }
        }
    }
}
