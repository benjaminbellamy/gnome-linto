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
        // Emitted (on the main thread) when voice is detected again after the
        // monitor was armed for auto-resume. The session appsrc has already been
        // attached, so the tap is retaining the speech onset by the time this
        // fires.
        public signal void voice_returned ();

        public GenericArray<Gst.Device> devices { get; private set; }

        // The raw audio format the capture tap delivers and the stream consumes:
        // 16 kHz mono, the rate the ASR expects.
        private const string TAP_CAPS =
            "audio/x-raw,format=S16LE,rate=16000,channels=1,layout=interleaved";

        private Gst.DeviceMonitor monitor;
        private uint monitor_watch_id = 0;
        private Gst.Pipeline? pipeline = null;
        private uint bus_watch_id = 0;
        private uint current_index = 0;
        private uint retry_id = 0;

        // The always-on capture tap: an appsink pulls each captured buffer and
        // pushes it into the streamer's appsrc. A fresh appsrc is handed out per
        // stream (create_stream_source), which is what makes restart, switch and
        // reconnect work; a reused proxysink does not replay its start/segment
        // events to a second consumer, so nothing would flow the second time.
        private Gst.App.Sink? app_sink = null;
        private Gst.App.Src? stream_src = null;
        private Mutex stream_src_lock;
        // Set when an appsrc was attached at a speech onset (auto-resume), so
        // the next take_stream_source hands that same buffering source to the
        // new session instead of a fresh one. Guarded by stream_src_lock.
        private bool onset_pending = false;

        // Voice activity detection on the capture tap, so the window can pause
        // on silence and resume on speech. Written on the streaming thread (the
        // tap callback) and read on the main thread, so the shared state is
        // guarded.
        private Vad vad = new Vad ();
        private Mutex voice_lock;
        private int64 last_voice_mono_us = 0;
        private bool resume_armed = false;
        // The latest voice-detected state, mirrored for the main thread so the
        // input level readout can show whether voice is present right now.
        private bool voice_state = false;
        // The voice level gate: an automatic (envelope-derived) threshold, or
        // the manual one as a linear mean-square value (converted from dBFS).
        // Set from the main thread, read on the tap thread.
        private bool voice_threshold_auto = true;
        private double voice_energy_threshold = 0.0;

        construct {
            this.last_voice_mono_us = GLib.get_monotonic_time ();
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
        // node is created once and is not torn down on start or pause. A silent
        // live source is mixed under the mic so the capture output (and the
        // stream tap that bridges from it) never stops, even if the device
        // stalls or suspends, so the stream keeps sending 100% of the time:
        //   pipewiresrc(LinTO) ! channels=1 ! audioconvert ! audioresample
        //     ! 16 kHz mono ! audiomixer ! tee
        //   audiotestsrc(silent, live) ! 16 kHz mono ! audiomixer
        //     tee. ! queue ! level ! fakesink   (VU meter, always on)
        //     tee. ! queue ! appsink            (tap: pushes to the stream appsrc)
        // The mixer runs entirely inside this one pipeline (both sources share
        // its clock), which is the safe configuration. The appsink hands each
        // buffer to the current stream appsrc; a fresh appsrc per stream is what
        // lets restart, switch and reconnect work. Out-of-range index stops it.
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
            var resample = Gst.ElementFactory.make ("audioresample", null);
            var mix_caps = Gst.ElementFactory.make ("capsfilter", null);
            var silence = Gst.ElementFactory.make ("audiotestsrc", null);
            var silence_caps = Gst.ElementFactory.make ("capsfilter", null);
            var mixer = Gst.ElementFactory.make ("audiomixer", null);
            var tee = Gst.ElementFactory.make ("tee", null);
            var vqueue = Gst.ElementFactory.make ("queue", null);
            var level_element = Gst.ElementFactory.make ("level", null);
            var vsink = Gst.ElementFactory.make ("fakesink", null);
            var squeue = Gst.ElementFactory.make ("queue", null);
            var tap = Gst.ElementFactory.make ("appsink", null) as Gst.App.Sink;

            if (src == null || caps == null || convert == null ||
                resample == null || mix_caps == null || silence == null ||
                silence_caps == null || mixer == null || tee == null ||
                vqueue == null || level_element == null || vsink == null ||
                squeue == null || tap == null) {
                warning ("Could not create the audio capture elements.");
                return;
            }

            // Capture a single mono channel, so the PipeWire "LinTO" node is
            // mono and its format stays the same whether or not we are
            // streaming.
            ((dynamic Gst.Element) caps).caps =
                Gst.Caps.from_string ("audio/x-raw,channels=1");
            // Both mixer inputs must share one format: 16 kHz mono, the rate the
            // ASR expects.
            ((dynamic Gst.Element) mix_caps).caps =
                Gst.Caps.from_string (TAP_CAPS);
            ((dynamic Gst.Element) silence_caps).caps =
                Gst.Caps.from_string (TAP_CAPS);
            // A live, digitally silent floor (volume 0 leaves the real audio
            // untouched when it is present).
            ((dynamic Gst.Element) silence).is_live = true;
            ((dynamic Gst.Element) silence).volume = 0.0;
            LevelMeter.configure (level_element);
            ((dynamic Gst.Element) vsink).sync = false;

            // The tap never blocks the capture pipeline: it drops if the stream
            // side is not keeping up, so the VU meter and mixer keep running.
            tap.emit_signals = true;
            tap.sync = false;
            tap.max_buffers = 4;
            tap.drop = true;
            tap.new_sample.connect (this.on_tap_sample);

            var pipe = new Gst.Pipeline ("audio-capture");
            pipe.add_many (src, caps, convert, resample, mix_caps, silence,
                silence_caps, mixer, tee, vqueue, level_element, vsink, squeue,
                tap);
            if (!src.link_many (caps, convert, resample, mix_caps)
                || !mix_caps.link (mixer)) {
                warning ("Could not link the audio capture chain.");
                return;
            }
            if (!silence.link (silence_caps) || !silence_caps.link (mixer)) {
                warning ("Could not link the silence source.");
                return;
            }
            if (!mixer.link (tee)) {
                warning ("Could not link the audio mixer.");
                return;
            }
            if (!tee.link (vqueue) ||
                !vqueue.link_many (level_element, vsink)) {
                warning ("Could not link the level metering branch.");
                return;
            }
            if (!tee.link (squeue) || !squeue.link (tap)) {
                warning ("Could not link the stream tap.");
                return;
            }

            var bus = pipe.get_bus ();
            this.bus_watch_id = bus.add_watch (Priority.DEFAULT,
                this.on_bus_message);

            pipe.set_state (Gst.State.PLAYING);
            this.pipeline = pipe;
            this.app_sink = tap;
        }

        // Pulls each captured buffer and pushes it into the current stream
        // appsrc. Runs on the capture streaming thread, so access to stream_src
        // is guarded. A copy is pushed (the sample keeps ownership of the
        // original); the appsrc restamps it on its own clock.
        private Gst.FlowReturn on_tap_sample (Gst.App.Sink sink) {
            Gst.Sample? sample = sink.pull_sample ();
            if (sample == null) {
                return Gst.FlowReturn.OK;
            }
            unowned Gst.Buffer? buffer = sample.get_buffer ();
            if (buffer == null) {
                return Gst.FlowReturn.OK;
            }
            this.analyze_voice (buffer);
            this.stream_src_lock.lock ();
            Gst.App.Src? src = this.stream_src;
            this.stream_src_lock.unlock ();
            if (src != null) {
                src.push_buffer ((Gst.Buffer) buffer.copy ());
            }
            return Gst.FlowReturn.OK;
        }

        // Runs voice activity detection on a captured buffer (runs on the tap
        // thread, always, even when not streaming). Tracks the last-voice time
        // and, while armed for auto-resume, attaches the session appsrc at the
        // speech onset and signals the window to resume.
        private void analyze_voice (Gst.Buffer buffer) {
            Gst.MapInfo info;
            if (!buffer.map (out info, Gst.MapFlags.READ)) {
                return;
            }
            int n = (int) (info.size / 2);
            var samples = new int16[n];
            for (int i = 0; i < n; i++) {
                int lo = info.data[2 * i];
                int hi = info.data[2 * i + 1];
                samples[i] = (int16) ((hi << 8) | lo);
            }
            buffer.unmap (info);

            this.voice_lock.lock ();
            bool automatic = this.voice_threshold_auto;
            double threshold = this.voice_energy_threshold;
            this.voice_lock.unlock ();

            bool was = this.vad.speaking;
            bool now = this.vad.push (samples, threshold, automatic);

            this.voice_lock.lock ();
            this.voice_state = now;
            if (now) {
                this.last_voice_mono_us = GLib.get_monotonic_time ();
            }
            bool armed = this.resume_armed;
            this.voice_lock.unlock ();

            // Confirmed speech onset while waiting to auto-resume: attach the
            // session appsrc now so the tap retains the first words in its leaky
            // buffer while the pipeline comes up, and hand off to the main
            // thread to bring the stream back.
            if (armed && !was && now) {
                this.voice_lock.lock ();
                this.resume_armed = false;
                this.voice_lock.unlock ();
                this.create_stream_source ();
                this.stream_src_lock.lock ();
                this.onset_pending = true;
                this.stream_src_lock.unlock ();
                Idle.add (() => {
                    this.voice_returned ();
                    return Source.REMOVE;
                });
            }
        }

        // Whether the detector currently considers voice present, for the live
        // input level readout.
        public bool voice_active () {
            this.voice_lock.lock ();
            bool v = this.voice_state;
            this.voice_lock.unlock ();
            return v;
        }

        // Milliseconds since voice was last detected, for the silence timeout.
        public int64 idle_ms () {
            this.voice_lock.lock ();
            int64 last = this.last_voice_mono_us;
            this.voice_lock.unlock ();
            return (GLib.get_monotonic_time () - last) / 1000;
        }

        // Restarts the silence clock, so the timeout is measured from now (used
        // when a stream begins or resumes).
        public void reset_idle () {
            this.voice_lock.lock ();
            this.last_voice_mono_us = GLib.get_monotonic_time ();
            this.voice_lock.unlock ();
        }

        // Arms (or disarms) auto-resume: while armed and not streaming, the next
        // speech onset attaches the session appsrc and emits voice_returned.
        public void arm_resume (bool armed) {
            this.voice_lock.lock ();
            this.resume_armed = armed;
            this.voice_lock.unlock ();
        }

        // Sets the voice level gate below which audio is treated as silence,
        // either automatic (envelope-derived) or a manual dBFS value. The dBFS
        // is converted once to a linear mean-square threshold matching the VAD's
        // energy units, so the tap thread never has to compute a logarithm.
        public void set_voice_threshold (bool automatic, int dbfs) {
            double amplitude = 32767.0 * Math.pow (10.0, (double) dbfs / 20.0);
            this.voice_lock.lock ();
            this.voice_threshold_auto = automatic;
            this.voice_energy_threshold = amplitude * amplitude;
            this.voice_lock.unlock ();
        }

        // The appsrc for a new session's first build: the one already attached
        // and buffering a speech onset (auto-resume, so the first words are not
        // lost), or a fresh one. The onset source is handed out at most once.
        public Gst.Element? take_stream_source () {
            this.stream_src_lock.lock ();
            bool pending = this.onset_pending;
            this.onset_pending = false;
            Gst.App.Src? attached = this.stream_src;
            this.stream_src_lock.unlock ();
            if (pending && attached != null) {
                return attached;
            }
            return this.create_stream_source ();
        }

        // Hands the streamer a fresh appsrc for a new session. Each session gets
        // its own appsrc so stream-start/segment events flow correctly; the
        // capture appsink then feeds this source. Null when capture is not up.
        public Gst.Element? create_stream_source () {
            if (this.app_sink == null) {
                return null;
            }
            var src = Gst.ElementFactory.make ("appsrc", null) as Gst.App.Src;
            if (src == null) {
                return null;
            }
            src.is_live = true;
            src.format = Gst.Format.TIME;
            src.do_timestamp = true;
            src.caps = Gst.Caps.from_string (TAP_CAPS);
            // Bound the buffering and drop the oldest if the stream side stalls,
            // so a stuck connection cannot grow memory without limit.
            src.max_bytes = 320000;
            src.leaky_type = Gst.App.LeakyType.DOWNSTREAM;
            this.stream_src_lock.lock ();
            this.stream_src = src;
            this.stream_src_lock.unlock ();
            return src;
        }

        // Stops feeding the stream appsrc (the session has ended), so the
        // capture appsink pulls and discards until the next session.
        public void detach_stream_source () {
            this.stream_src_lock.lock ();
            this.stream_src = null;
            this.onset_pending = false;
            this.stream_src_lock.unlock ();
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
            this.app_sink = null;
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
