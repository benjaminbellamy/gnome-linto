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
    // Enumerates PipeWire audio inputs and runs a lightweight pipeline that
    // measures the signal level of the selected device, so the user can see
    // whether there is signal and whether it is saturating.
    public class AudioMonitor : Object {
        // Emitted at the level element interval with a peak in the range 0..1.
        public signal void level (double peak);
        // Emitted when inputs are plugged in or removed.
        public signal void devices_changed ();

        public GenericArray<Gst.Device> devices { get; private set; }

        private Gst.DeviceMonitor monitor;
        private uint monitor_watch_id = 0;
        private Gst.Pipeline? pipeline = null;
        private uint bus_watch_id = 0;

        construct {
            this.devices = new GenericArray<Gst.Device> ();
            this.monitor = new Gst.DeviceMonitor ();
            var caps = new Gst.Caps.empty_simple ("audio/x-raw");
            this.monitor.add_filter ("Audio/Source", caps);
            this.monitor.start ();

            var bus = this.monitor.get_bus ();
            this.monitor_watch_id = bus.add_watch (Priority.DEFAULT,
                this.on_monitor_message);

            this.reload_devices ();
        }

        ~AudioMonitor () {
            if (this.monitor_watch_id != 0) {
                Source.remove (this.monitor_watch_id);
                this.monitor_watch_id = 0;
            }
            this.stop_pipeline ();
            this.monitor.stop ();
        }

        public void reload_devices () {
            this.devices = new GenericArray<Gst.Device> ();
            foreach (var device in this.monitor.get_devices ()) {
                this.devices.add (device);
            }
        }

        private bool on_monitor_message (Gst.Bus bus, Gst.Message message) {
            if (message.type == Gst.MessageType.DEVICE_ADDED ||
                message.type == Gst.MessageType.DEVICE_REMOVED) {
                this.reload_devices ();
                this.devices_changed ();
            }
            return Source.CONTINUE;
        }

        // A stable identifier so a device can be re-resolved after a replug.
        public static string device_id (Gst.Device device) {
            Gst.Structure? props = device.get_properties ();
            if (props != null) {
                unowned string? node_name = props.get_string ("node.name");
                if (node_name != null && node_name != "") {
                    return node_name;
                }
            }
            return device.get_display_name ();
        }

        public Gst.Device? find_device (string id) {
            foreach (var device in this.devices.data) {
                if (device_id (device) == id) {
                    return device;
                }
            }
            return null;
        }

        // Builds and starts a monitoring pipeline for the device at the given
        // index. Passing an out-of-range index simply stops monitoring.
        public void select (uint index) {
            this.stop_pipeline ();

            if (index >= this.devices.length) {
                this.level (0.0);
                return;
            }

            var device = this.devices.get ((int) index);
            var src = device.create_element (null);
            var convert = Gst.ElementFactory.make ("audioconvert", null);
            var level_element = Gst.ElementFactory.make ("level", null);
            var sink = Gst.ElementFactory.make ("fakesink", null);

            if (src == null || convert == null ||
                level_element == null || sink == null) {
                warning ("Could not create the audio monitoring elements.");
                return;
            }

            LevelMeter.configure (level_element);

            dynamic Gst.Element sink_dyn = sink;
            sink_dyn.sync = false;

            var pipe = new Gst.Pipeline ("audio-monitor");
            pipe.add_many (src, convert, level_element, sink);
            if (!src.link_many (convert, level_element, sink)) {
                warning ("Could not link the audio monitoring pipeline.");
                return;
            }

            var bus = pipe.get_bus ();
            this.bus_watch_id = bus.add_watch (Priority.DEFAULT,
                this.on_bus_message);

            pipe.set_state (Gst.State.PLAYING);
            this.pipeline = pipe;
        }

        public void stop () {
            this.stop_pipeline ();
        }

        private void stop_pipeline () {
            if (this.bus_watch_id != 0) {
                Source.remove (this.bus_watch_id);
                this.bus_watch_id = 0;
            }
            if (this.pipeline != null) {
                this.pipeline.set_state (Gst.State.NULL);
                this.pipeline = null;
            }
            this.level (0.0);
        }

        private bool on_bus_message (Gst.Bus bus, Gst.Message message) {
            double peak = LevelMeter.peak_from_message (message);
            if (peak >= 0.0) {
                this.level (peak);
            } else if (message.type == Gst.MessageType.ERROR) {
                Error err;
                string debug;
                message.parse_error (out err, out debug);
                warning ("Audio monitor error: %s", err.message);
                this.stop_pipeline ();
            }
            return Source.CONTINUE;
        }
    }
}
