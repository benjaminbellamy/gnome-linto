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
    public enum StreamState {
        IDLE,
        CONNECTING,
        STREAMING,
        RECONNECTING
    }

    // Supplies a fresh source element for the target device on each (re)build,
    // or null when the device is currently unavailable. Re-resolving the device
    // each time lets streaming survive an unplug/replug.
    public delegate Gst.Element? SourceProvider ();

    // Streams a selected audio input to a LinTO SRT endpoint and keeps the
    // session alive across transient failures by reconnecting with backoff:
    //   <source> ! audioconvert ! audioresample ! rate=48000 ! tee
    //     tee. ! queue ! level ! fakesink            (VU meter tap)
    //     tee. ! queue ! avenc_ac3 ! mpegtsmux ! rtpmp2tpay ! srtsink
    public class Streamer : Object {
        public signal void level (double peak);
        public signal void stats (int64 elapsed_seconds, uint64 bytes_sent,
            uint64 packets_sent, double bitrate_kbps);
        public signal void state_changed (StreamState state, string? detail);

        public StreamState state { get; private set; default = StreamState.IDLE; }
        public bool is_active { get { return this.state != StreamState.IDLE; } }

        // Seconds without data flow before a connected stream is treated as
        // stalled, and before a pending connection is retried.
        private const int STALL_SECONDS = 8;
        private const int CONNECT_SECONDS = 12;
        private const int MAX_BACKOFF_MS = 15000;

        private SourceProvider? source_provider = null;
        private string target_uri = "";

        private Gst.Pipeline? pipeline = null;
        private uint bus_watch_id = 0;
        private ulong probe_id = 0;
        private Gst.Pad? probe_pad = null;

        private uint stats_timer_id = 0;
        private uint reconnect_timer_id = 0;
        private int reconnect_attempt = 0;

        // Elapsed time of the current run (start to stop, spanning reconnects).
        private Timer? session_timer = null;

        // Counters are written on the streaming thread and read on the main
        // thread, so all access is guarded. They count the current run; the
        // window adds the per-URL saved totals on top.
        private Mutex counter_lock;
        private uint64 byte_count = 0;
        private uint64 packet_count = 0;

        private uint64 last_tick_bytes = 0;
        private uint64 last_progress_bytes = 0;
        private int idle_ticks = 0;

        ~Streamer () {
            this.stop ();
        }

        public void start (owned SourceProvider provider, string uri) {
            this.stop ();

            this.source_provider = (owned) provider;
            this.target_uri = uri;
            this.byte_count = 0;
            this.packet_count = 0;
            this.last_tick_bytes = 0;
            this.last_progress_bytes = 0;
            this.idle_ticks = 0;
            this.reconnect_attempt = 0;
            this.session_timer = new Timer ();

            this.change_state (StreamState.CONNECTING, null);
            this.stats_timer_id = Timeout.add_seconds (1, this.on_tick);
            this.try_build ();
        }

        public void stop () {
            bool was_active = this.state != StreamState.IDLE;
            this.cancel_reconnect ();
            if (this.stats_timer_id != 0) {
                Source.remove (this.stats_timer_id);
                this.stats_timer_id = 0;
            }
            this.teardown_pipeline ();
            this.session_timer = null;
            this.source_provider = null;
            if (was_active) {
                this.change_state (StreamState.IDLE, null);
            }
            this.level (0.0);
        }

        private void change_state (StreamState s, string? detail) {
            this.state = s;
            this.state_changed (s, detail);
        }

        // Attempts to (re)build the pipeline; any failure schedules a retry
        // rather than propagating, so a session never dies on a transient fault.
        private void try_build () {
            this.idle_ticks = 0;
            try {
                this.build_pipeline ();
            } catch (Error e) {
                this.schedule_reconnect (e.message);
            }
        }

        private void build_pipeline () throws Error {
            this.teardown_pipeline ();

            Gst.Element? src = (this.source_provider != null)
                ? this.source_provider ()
                : null;
            if (src == null) {
                throw new IOError.FAILED (
                    _("The audio input device is unavailable."));
            }

            var convert = make_element ("audioconvert");
            var resample = make_element ("audioresample");
            var capsfilter = make_element ("capsfilter");
            var tee = make_element ("tee");
            var vqueue = make_element ("queue");
            var level_element = make_element ("level");
            var vsink = make_element ("fakesink");
            var squeue = make_element ("queue");
            var encoder = make_element ("avenc_ac3");
            var muxer = make_element ("mpegtsmux");
            var payloader = make_element ("rtpmp2tpay");
            var sink = make_element ("srtsink");

            dynamic Gst.Element caps_dyn = capsfilter;
            caps_dyn.caps = Gst.Caps.from_string ("audio/x-raw,rate=48000");
            LevelMeter.configure (level_element);
            dynamic Gst.Element vsink_dyn = vsink;
            vsink_dyn.sync = false;
            dynamic Gst.Element sink_dyn = sink;
            sink_dyn.uri = this.target_uri;

            var pipe = new Gst.Pipeline (null);
            pipe.add_many (src, convert, resample, capsfilter, tee,
                vqueue, level_element, vsink,
                squeue, encoder, muxer, payloader, sink);

            if (!src.link_many (convert, resample, capsfilter, tee)) {
                throw new IOError.FAILED (
                    _("Could not link the audio capture chain."));
            }
            if (!tee.link (vqueue) || !vqueue.link_many (level_element, vsink)) {
                throw new IOError.FAILED (
                    _("Could not link the level metering branch."));
            }
            if (!tee.link (squeue) ||
                !squeue.link_many (encoder, muxer, payloader, sink)) {
                throw new IOError.FAILED (
                    _("Could not link the streaming branch."));
            }

            this.probe_pad = sink.get_static_pad ("sink");
            if (this.probe_pad != null) {
                this.probe_id = this.probe_pad.add_probe (
                    Gst.PadProbeType.BUFFER, this.on_buffer);
            }

            var bus = pipe.get_bus ();
            this.bus_watch_id = bus.add_watch (Priority.DEFAULT,
                this.on_bus_message);

            if (pipe.set_state (Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE) {
                this.teardown_pipeline ();
                throw new IOError.FAILED (
                    _("The streaming pipeline failed to start."));
            }
            this.pipeline = pipe;
        }

        private static Gst.Element make_element (string factory) throws Error {
            var element = Gst.ElementFactory.make (factory, null);
            if (element == null) {
                throw new IOError.FAILED (
                    _("The \"%s\" GStreamer element is missing.").printf (factory));
            }
            return element;
        }

        private void teardown_pipeline () {
            if (this.bus_watch_id != 0) {
                Source.remove (this.bus_watch_id);
                this.bus_watch_id = 0;
            }
            if (this.probe_pad != null && this.probe_id != 0) {
                this.probe_pad.remove_probe (this.probe_id);
            }
            this.probe_id = 0;
            this.probe_pad = null;
            if (this.pipeline != null) {
                this.pipeline.set_state (Gst.State.NULL);
                this.pipeline = null;
            }
        }

        // A recoverable failure during an active session: drop the pipeline and
        // schedule a reconnect.
        private void recover (string detail) {
            if (this.state == StreamState.IDLE) {
                return;
            }
            this.teardown_pipeline ();
            this.level (0.0);
            this.schedule_reconnect (detail);
        }

        private void schedule_reconnect (string? detail) {
            if (this.state == StreamState.IDLE) {
                return;
            }
            this.cancel_reconnect ();
            this.change_state (StreamState.RECONNECTING, detail);

            int shift = int.min (this.reconnect_attempt, 16);
            int backoff = int.min (1000 << shift, MAX_BACKOFF_MS);
            this.reconnect_attempt++;

            this.reconnect_timer_id = Timeout.add (backoff, () => {
                this.reconnect_timer_id = 0;
                if (this.state == StreamState.IDLE) {
                    return Source.REMOVE;
                }
                this.try_build ();
                return Source.REMOVE;
            });
        }

        private void cancel_reconnect () {
            if (this.reconnect_timer_id != 0) {
                Source.remove (this.reconnect_timer_id);
                this.reconnect_timer_id = 0;
            }
        }

        private Gst.PadProbeReturn on_buffer (Gst.Pad pad, Gst.PadProbeInfo info) {
            unowned Gst.Buffer? buffer = info.get_buffer ();
            if (buffer != null) {
                this.counter_lock.lock ();
                this.byte_count += buffer.get_size ();
                this.packet_count += 1;
                this.counter_lock.unlock ();
            }
            return Gst.PadProbeReturn.OK;
        }

        private bool on_tick () {
            if (this.state == StreamState.IDLE) {
                return Source.REMOVE;
            }

            this.counter_lock.lock ();
            uint64 total = this.byte_count;
            uint64 packets = this.packet_count;
            this.counter_lock.unlock ();

            // Watchdog only runs while a pipeline exists (not during backoff).
            if (this.pipeline != null) {
                if (total > this.last_progress_bytes) {
                    this.last_progress_bytes = total;
                    this.idle_ticks = 0;
                    if (this.state != StreamState.STREAMING) {
                        this.reconnect_attempt = 0;
                        this.change_state (StreamState.STREAMING, null);
                    }
                } else {
                    this.idle_ticks++;
                    int limit = (this.state == StreamState.STREAMING)
                        ? STALL_SECONDS
                        : CONNECT_SECONDS;
                    if (this.idle_ticks >= limit) {
                        this.recover (this.state == StreamState.STREAMING
                            ? _("The connection stalled.")
                            : _("Could not reach the server."));
                    }
                }
            }

            int64 elapsed = (this.session_timer != null)
                ? (int64) this.session_timer.elapsed ()
                : 0;
            uint64 delta = total - this.last_tick_bytes;
            this.last_tick_bytes = total;
            double bitrate_kbps = (double) delta * 8.0 / 1000.0;
            this.stats (elapsed, total, packets, bitrate_kbps);
            return Source.CONTINUE;
        }

        private bool on_bus_message (Gst.Bus bus, Gst.Message message) {
            double peak = LevelMeter.peak_from_message (message);
            if (peak >= 0.0) {
                this.level (peak);
                return Source.CONTINUE;
            }
            switch (message.type) {
                case Gst.MessageType.ERROR:
                    Error err;
                    string debug;
                    message.parse_error (out err, out debug);
                    this.recover (err.message);
                    break;
                case Gst.MessageType.EOS:
                    this.recover (_("The stream ended."));
                    break;
                default:
                    break;
            }
            return Source.CONTINUE;
        }
    }
}
