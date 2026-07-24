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
    // A small voice activity detector for 16 kHz mono S16LE audio, with no
    // external dependency. It works off the frame PEAK level in dBFS (the same
    // measure the input level meter shows). In automatic mode it tracks two
    // references: the ground-noise minimum (the actual recent minimum level) and
    // a voice maximum (a long, about 5 minute, running average of the voice-level
    // frames, so several speakers at different levels settle to a stable typical
    // level rather than the single loudest peak, and a brief transient barely
    // moves it). The current level is normalized between the two to 0..1, and a
    // Schmitt trigger decides speech: above 0.6 is voice, below 0.4 is silence,
    // in between holds (hysteresis). This self-scales to the actual
    // signal-to-noise range and needs no absolute tuning. A zero-crossing band
    // and a short hangover keep the decision clean. A manual dBFS gate is
    // available as an override.
    public class Vad : Object {
        // 16 kHz mono, so a 30 ms analysis frame is 480 samples.
        private const int FRAME_SIZE = 480;
        // Level assigned to a frame with no signal (digital silence).
        private const double SILENCE_DB = -90.0;
        // A frame this many dB above the minimum counts as voice (feeds the max
        // average), and at least this much min-to-max range must exist for the
        // normalization to be trusted; below it everything is ambient (silence).
        private const double MIN_RANGE_DB = 3.0;
        // The voice maximum is only seeded once voice has been sustained this
        // many frames (about 90 ms), so a one or two frame transient (a click or
        // pop) never sets it.
        private const int VOICE_ONSET_FRAMES = 3;
        // Averaging rate of the voice maximum once seeded: about a 5 minute
        // window at 33 frames/s, so it is the typical voice level, not a peak.
        private const double MAX_AVG_RATE = 0.0001;
        // The minimum rises this slowly (only while not speaking) so it follows a
        // rising noise floor without being pulled up by speech; it drops at once
        // to any quieter frame, so it is the actual recent minimum.
        private const double MIN_RISE_DB = 0.01;
        // Schmitt trigger on the 0..1 normalized level between min and max.
        private const double NORM_HIGH = 0.60;
        private const double NORM_LOW = 0.40;
        // Zero-crossing rate band (crossings per sample) admitting both voiced
        // sounds (low rate) and unvoiced ones (high rate: s, f, sh, t), while
        // rejecting near-DC rumble and near-alternating broadband hiss.
        private const double ZCR_MIN = 0.01;
        private const double ZCR_MAX = 0.40;
        // Consecutive frames to latch on in manual mode, and how long to hold
        // "speaking" after voice stops (about 750 ms) so short gaps between words
        // do not read as silence.
        private const int ATTACK_FRAMES = 2;
        private const int HANGOVER_FRAMES = 25;

        // The latched speech state.
        public bool speaking { get; private set; default = false; }

        private double min_db = SILENCE_DB;   // actual recent ground-noise level
        private double max_db = SILENCE_DB;   // averaged voice level
        private bool seeded = false;
        private bool max_seeded = false;
        private int above_floor_run = 0;
        private int voice_run = 0;
        private int hangover = 0;
        // Samples left over from the last push that did not fill a whole frame.
        private int16[] pending = new int16[0];

        // Feeds more samples (16 kHz mono S16LE) and returns the current latched
        // speaking state. Any partial trailing frame is kept for the next call.
        // manual_threshold is the peak-squared gate to use when automatic is
        // false; in automatic mode the min/max normalization decides.
        public bool push (int16[] samples, double manual_threshold,
            bool automatic) {
            int old = this.pending.length;
            this.pending.resize (old + samples.length);
            for (int i = 0; i < samples.length; i++) {
                this.pending[old + i] = samples[i];
            }

            int off = 0;
            while (off + FRAME_SIZE <= this.pending.length) {
                this.process_frame (this.pending, off, manual_threshold,
                    automatic);
                off += FRAME_SIZE;
            }

            // Keep only the trailing partial frame for the next call.
            this.pending = this.pending[off : this.pending.length];
            return this.speaking;
        }

        private void process_frame (int16[] buf, int off,
            double manual_threshold, bool automatic) {
            int peak = 0;
            int crossings = 0;
            int16 prev = buf[off];
            for (int i = 0; i < FRAME_SIZE; i++) {
                int16 s = buf[off + i];
                int a = (s < 0) ? -s : s;
                if (a > peak) {
                    peak = a;
                }
                if ((s >= 0) != (prev >= 0)) {
                    crossings++;
                }
                prev = s;
            }
            double level = (double) peak * (double) peak;
            double zcr = (double) crossings / FRAME_SIZE;
            double level_db = (peak <= 0)
                ? SILENCE_DB
                : 20.0 * Math.log10 ((double) peak / 32767.0);
            if (level_db < SILENCE_DB) {
                level_db = SILENCE_DB;
            }

            bool voice_like = zcr >= ZCR_MIN && zcr <= ZCR_MAX;

            if (automatic) {
                this.update_range (level_db);
                double range = this.max_db - this.min_db;
                bool has_range = range >= MIN_RANGE_DB;
                double norm = has_range
                    ? (level_db - this.min_db) / range
                    : 0.0;
                if (norm < 0.0) {
                    norm = 0.0;
                } else if (norm > 1.0) {
                    norm = 1.0;
                }
                if (has_range && voice_like && norm >= NORM_HIGH) {
                    this.speaking = true;
                    this.hangover = HANGOVER_FRAMES;
                } else if (this.speaking && (!has_range || norm <= NORM_LOW)) {
                    this.hangover--;
                    if (this.hangover <= 0) {
                        this.speaking = false;
                    }
                }
            } else {
                // Manual mode: a fixed absolute peak-level gate.
                bool frame_voice = level >= manual_threshold && voice_like;
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
                        this.hangover--;
                        if (this.hangover <= 0) {
                            this.speaking = false;
                        }
                    }
                }
            }
        }

        // Tracks the ground-noise minimum (actual recent minimum) and the voice
        // maximum (a long running average of the voice-level frames). The max is
        // seeded only once voice is sustained, so brief transients never set it,
        // and then averaged, so several speakers at different levels settle to a
        // stable typical level. Neither is pulled down by silence.
        private void update_range (double level_db) {
            if (!this.seeded) {
                this.min_db = level_db;
                this.max_db = level_db;
                this.seeded = true;
                return;
            }

            // Actual minimum: drop at once, rise slowly only while not speaking.
            if (level_db < this.min_db) {
                this.min_db = level_db;
            } else if (!this.speaking) {
                this.min_db += MIN_RISE_DB;
            }

            // Voice maximum from frames clearly above the floor. Require a short
            // sustain before the first seed so a click cannot set it, then keep a
            // long average.
            if (level_db > this.min_db + MIN_RANGE_DB) {
                this.above_floor_run++;
                if (!this.max_seeded) {
                    if (this.above_floor_run >= VOICE_ONSET_FRAMES) {
                        this.max_db = level_db;
                        this.max_seeded = true;
                    }
                } else {
                    this.max_db += (level_db - this.max_db) * MAX_AVG_RATE;
                }
            } else {
                this.above_floor_run = 0;
            }

            if (this.max_db < this.min_db) {
                this.max_db = this.min_db;
            }
        }
    }
}
