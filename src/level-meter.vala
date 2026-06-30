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
    // Shared helpers for the GStreamer "level" element used by both the
    // preview monitor and the streamer to drive the VU meter.
    namespace LevelMeter {
        // Metering cadence: 10 Hz is visually indistinguishable from faster
        // rates for a VU meter while halving the bus traffic and redraws.
        private const uint64 INTERVAL_NS = 100000000; // 100 ms

        // Turns on peak/rms posting at the metering cadence.
        public void configure (Gst.Element level_element) {
            dynamic Gst.Element level_dyn = level_element;
            level_dyn.post_messages = true;
            level_dyn.interval = INTERVAL_NS;
        }

        // Returns the clamped 0..1 peak carried by a "level" element message,
        // or a negative value when the message is not a level message.
        public double peak_from_message (Gst.Message message) {
            if (message.type != Gst.MessageType.ELEMENT) {
                return -1.0;
            }
            unowned Gst.Structure? s = message.get_structure ();
            if (s == null || s.get_name () != "level") {
                return -1.0;
            }
            return linear_from_db (extract_peak (s));
        }

        // Converts a dBFS peak to a clamped 0..1 linear value for the VU meter.
        public double linear_from_db (double db) {
            if (db <= -90.0) {
                return 0.0;
            }
            double linear = Math.pow (10.0, db / 20.0);
            return (linear > 1.0) ? 1.0 : linear;
        }

        // Reads the highest per-channel peak (in dBFS) from a level message.
        private double extract_peak (Gst.Structure s) {
            unowned GLib.Value? v = s.get_value ("peak");
            if (v == null) {
                return -1000.0;
            }
            unowned GLib.ValueArray arr = (GLib.ValueArray) v.get_boxed ();
            if (arr == null) {
                return -1000.0;
            }
            double max = -1000.0;
            for (uint i = 0; i < arr.n_values; i++) {
                unowned GLib.Value? element = arr.get_nth (i);
                if (element != null) {
                    double db = element.get_double ();
                    if (db > max) {
                        max = db;
                    }
                }
            }
            return max;
        }
    }
}
