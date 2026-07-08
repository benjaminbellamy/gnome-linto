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
        // Emitted at the level element interval with a peak in the range 0..1
        // (for the VU meter) and the same peak in dBFS (for the numeric
        // readout); the dBFS value is a large negative number for silence.
        public signal void level (double peak, double db);
        // Emitted when inputs are plugged in or removed.
        public signal void devices_changed ();

        public GenericArray<Gst.Device> devices { get; private set; }
        // The capture tap the streamer bridges to (proxysink), so streaming
        // never opens its own input and the PipeWire node stays put.
        public Gst.Element? proxy_sink { get; private set; default = null; }

        private Gst.DeviceMonitor monitor;
        private uint monitor_watch_id = 0;
        private Gst.Pipeline? pipeline = null;
        private uint bus_watch_id = 0;
        private uint current_index = 0;
        private uint retry_id = 0;

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
            if (this.retry_id != 0) {
                Source.remove (this.retry_id);
                this.retry_id = 0;
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

        // Creates the source element for a device and names its PipeWire node
        // "LinTO" so it is recognizable in a patchbay such as qpwgraph.
        public static Gst.Element? create_source (Gst.Device device) {
            var src = device.create_element (null);
            if (src == null) {
                return null;
            }
            unowned Gst.ElementFactory? factory = src.get_factory ();
            if (factory != null && factory.get_name () == "pipewiresrc") {
                dynamic Gst.Element pw = src;
                unowned string end;
                var stream_props = new Gst.Structure.from_string (
                    "props, node.name=(string)LinTO, " +
                    "node.description=(string)LinTO, media.name=(string)LinTO",
                    out end);
                if (stream_props != null) {
                    pw.stream_properties = stream_props;
                }
                // Leave the client application name empty so a patchbay shows
                // just the node title "LinTO", not "LinTO [LinTO]".
                var client_props = new Gst.Structure.from_string (
                    "props, application.name=(string)\"\"", out end);
                if (client_props != null) {
                    pw.client_properties = client_props;
                }
            }
            return src;
        }

        // Builds and starts the persistent capture pipeline for the device at
        // the given index. It stays running while streaming, so the PipeWire
        // node is created once and is not torn down on start or pause:
        //   pipewiresrc(LinTO) ! channels=1 ! audioconvert ! tee
        //     tee. ! queue ! level ! fakesink   (VU meter, always on)
        //     tee. ! queue ! proxysink          (tap the streamer bridges to)
        // Passing an out-of-range index simply stops capturing.
        public void select (uint index) {
            this.stop_pipeline ();
            this.current_index = index;

            if (index >= this.devices.length) {
                this.level (0.0, -1000.0);
                return;
            }

            var device = this.devices.get ((int) index);
            var src = create_source (device);
            var caps = Gst.ElementFactory.make ("capsfilter", null);
            var convert = Gst.ElementFactory.make ("audioconvert", null);
            var tee = Gst.ElementFactory.make ("tee", null);
            var vqueue = Gst.ElementFactory.make ("queue", null);
            var level_element = Gst.ElementFactory.make ("level", null);
            var vsink = Gst.ElementFactory.make ("fakesink", null);
            var squeue = Gst.ElementFactory.make ("queue", null);
            var proxy = Gst.ElementFactory.make ("proxysink", null);

            if (src == null || caps == null || convert == null || tee == null ||
                vqueue == null || level_element == null || vsink == null ||
                squeue == null || proxy == null) {
                warning ("Could not create the audio capture elements.");
                return;
            }

            // Capture a single mono channel, so the PipeWire "LinTO" node is
            // mono and its format stays the same whether or not we are
            // streaming.
            ((dynamic Gst.Element) caps).caps =
                Gst.Caps.from_string ("audio/x-raw,channels=1");
            LevelMeter.configure (level_element);
            ((dynamic Gst.Element) vsink).sync = false;

            var pipe = new Gst.Pipeline ("audio-capture");
            pipe.add_many (src, caps, convert, tee, vqueue, level_element,
                vsink, squeue, proxy);
            if (!src.link_many (caps, convert, tee)) {
                warning ("Could not link the audio capture chain.");
                return;
            }
            if (!tee.link (vqueue) ||
                !vqueue.link_many (level_element, vsink)) {
                warning ("Could not link the level metering branch.");
                return;
            }
            if (!tee.link (squeue) || !squeue.link (proxy)) {
                warning ("Could not link the stream tap.");
                return;
            }

            var bus = pipe.get_bus ();
            this.bus_watch_id = bus.add_watch (Priority.DEFAULT,
                this.on_bus_message);

            pipe.set_state (Gst.State.PLAYING);
            this.pipeline = pipe;
            this.proxy_sink = proxy;
        }

        // Creates a proxysrc bridged to the capture's proxysink, so the
        // streamer consumes the already-open mono input without opening (and
        // recreating) the PipeWire node itself. Null when capture is not up.
        public Gst.Element? create_stream_source () {
            if (this.proxy_sink == null) {
                return null;
            }
            var src = Gst.ElementFactory.make ("proxysrc", null);
            if (src == null) {
                return null;
            }
            ((dynamic Gst.Element) src).proxysink = this.proxy_sink;
            return src;
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
            this.proxy_sink = null;
            this.level (0.0, -1000.0);
        }

        // Rebuilds capture for the current device after a transient error, for
        // example an input being unplugged and replugged.
        private void schedule_retry () {
            this.stop_pipeline ();
            if (this.retry_id != 0) {
                return;
            }
            this.retry_id = Timeout.add_seconds (2, () => {
                this.retry_id = 0;
                this.reload_devices ();
                this.select (this.current_index);
                return Source.REMOVE;
            });
        }

        private bool on_bus_message (Gst.Bus bus, Gst.Message message) {
            double peak = LevelMeter.peak_from_message (message);
            if (peak >= 0.0) {
                this.level (peak, LevelMeter.peak_db_from_message (message));
            } else if (message.type == Gst.MessageType.ERROR) {
                Error err;
                string debug;
                message.parse_error (out err, out debug);
                warning ("Audio capture error: %s", err.message);
                this.schedule_retry ();
            }
            return Source.CONTINUE;
        }
    }
}
