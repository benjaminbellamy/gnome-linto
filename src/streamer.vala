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

    // Supplies a fresh source element on each (re)build, or null when the
    // input is currently unavailable. It returns a proxysrc bridged to the
    // always-on capture pipeline, so a reconnect never reopens the device.
    public delegate Gst.Element? SourceProvider ();

    // Streams the captured audio to a LinTO endpoint and keeps the session
    // alive across transient failures by reconnecting with backoff:
    //   proxysrc ! queue ! audioconvert ! audioresample
    //     ! rate=16000,channels=1 ! opusenc ! mpegtsmux ! rtpmp2tpay ! srtsink
    // The mono input comes from the persistent capture pipeline through a
    // proxysink/proxysrc bridge, so streaming never opens the device itself
    // and the PipeWire node is untouched on start and pause.
    public class Streamer : Object {
        public signal void stats (int64 elapsed_seconds, uint64 bytes_sent,
            uint64 packets_sent, double bitrate_kbps);
        public signal void state_changed (StreamState state, string? detail);
        // Emitted once per session when the initial connection cannot be
        // established (typically a wrong or expired address). The streamer
        // keeps retrying, but success is unlikely without a fix.
        public signal void connection_error (string message);

        public StreamState state { get; private set; default = StreamState.IDLE; }
        public bool is_active { get { return this.state != StreamState.IDLE; } }

        // Seconds without data flow before a connected stream is treated as
        // stalled, and before a pending connection is retried.
        private const int STALL_SECONDS = 8;
        private const int CONNECT_SECONDS = 12;
        // Never reconnect sooner than this after a drop: a new session that
        // races the old one on the server tends to fail, so give the server
        // time to release the previous session before handshaking again.
        private const int MIN_BACKOFF_MS = 5000;
        private const int MAX_BACKOFF_MS = 15000;

        private SourceProvider? source_provider = null;
        private string target_uri = "";

        // The raw audio format fed into the mixer and encoder: 16 kHz mono, the
        // rate the ASR expects. Both the live input and the silence source are
        // forced to this so the mixer's inputs match.
        private const string MIX_CAPS =
            "audio/x-raw,format=S16LE,rate=16000,channels=1,layout=interleaved";

        private Gst.Pipeline? pipeline = null;
        private Gst.Element? source_element = null;
        // A continuous, silent, live source mixed under the real input, so the
        // encoder and the network sink are never starved when the real input
        // stalls (device suspend, replug, capture rebuild). A gap on the wire
        // tends to break the server session, so the stream must never stop.
        private Gst.Element? silence_element = null;
        // Held only for SRT sessions, so debug logging can read its transport
        // stats (packets/bytes sent, ACKs, loss, RTT) each tick.
        private Gst.Element? srt_sink = null;
        private uint bus_watch_id = 0;
        private ulong probe_id = 0;
        private Gst.Pad? probe_pad = null;

        private uint stats_timer_id = 0;
        private uint reconnect_timer_id = 0;
        private uint eos_timer_id = 0;
        private int reconnect_attempt = 0;
        // Set while a user-requested EOS shutdown is in flight, so the EOS bus
        // message ends the session cleanly instead of triggering a reconnect.
        private bool finishing = false;
        // True once data has flowed at least once this session. Distinguishes a
        // never-connected session (likely a bad address) from a transient drop
        // of an established stream.
        private bool ever_streamed = false;
        // Set once the connection_error signal has been emitted this session,
        // so the reconnect loop does not repeat the message on every attempt.
        private bool reported_connect_error = false;

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
            this.ever_streamed = false;
            this.reported_connect_error = false;
            this.session_timer = new Timer ();

            var dbg = DebugLog.get_default ();
            dbg.log ("session", "start uri=" + uri);
            dbg.log ("format", format_description (uri));
            this.change_state (StreamState.CONNECTING, null);
            this.stats_timer_id = Timeout.add_seconds (1, this.on_tick);
            this.try_build ();
        }

        // Cumulative bytes handed to the network sink this session. Read from
        // the main thread for the live sent-rate meter; the counter is written
        // on the streaming thread, so access is guarded.
        public uint64 bytes_sent () {
            this.counter_lock.lock ();
            uint64 value = this.byte_count;
            this.counter_lock.unlock ();
            return value;
        }

        public void stop () {
            bool was_active = this.state != StreamState.IDLE;
            this.cancel_reconnect ();
            this.cancel_eos ();
            this.finishing = false;
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
        }

        // Ends the session gracefully: injects EOS so the muxer flushes and the
        // SRT sink signals end of stream, then stops once EOS reaches the sink.
        public void finish () {
            if (this.state == StreamState.IDLE || this.finishing) {
                return;
            }
            // No live pipeline to drain (waiting on a reconnect): stop now.
            if (this.pipeline == null) {
                this.stop ();
                return;
            }
            this.finishing = true;
            DebugLog.get_default ().log ("session", "finish: sending EOS");
            this.cancel_reconnect ();
            // Force a clean stop if EOS does not reach the sink in time.
            this.eos_timer_id = Timeout.add_seconds (3, () => {
                this.eos_timer_id = 0;
                this.stop ();
                return Source.REMOVE;
            });
            // Sending EOS to the live sources is more reliable than to the
            // pipeline. The mixer only forwards EOS once every input pad has
            // seen it, so both the real input and the silence source must get
            // it for the muxer to flush and the connection to close cleanly.
            if (this.source_element != null) {
                this.source_element.send_event (new Gst.Event.eos ());
                if (this.silence_element != null) {
                    this.silence_element.send_event (new Gst.Event.eos ());
                }
            } else {
                this.pipeline.send_event (new Gst.Event.eos ());
            }
        }

        private void cancel_eos () {
            if (this.eos_timer_id != 0) {
                Source.remove (this.eos_timer_id);
                this.eos_timer_id = 0;
            }
        }

        private void change_state (StreamState s, string? detail) {
            if (s == StreamState.STREAMING) {
                this.ever_streamed = true;
            }
            this.state = s;
            DebugLog.get_default ().log ("state",
                state_name (s) + (detail != null ? " (" + detail + ")" : ""));
            this.state_changed (s, detail);
        }

        // The audio format sent for the target protocol, for the debug log
        // header. The encoder settings are the constants used in build_output.
        private static string format_description (string uri) {
            switch (StreamUrl.protocol (uri)) {
                case StreamProtocol.SRT:
                    return "Opus audio 24 kbit/s, 16000 Hz, mono, "
                        + "16 bit/sample PCM input; MPEG-TS over RTP overhead "
                        + "raises the wire rate to about 100 kbit/s";
                case StreamProtocol.RTMP:
                    return "AAC audio, 16000 Hz, mono, 16 bit/sample PCM input, "
                        + "FLV";
                default:
                    return "unknown protocol";
            }
        }

        private static string state_name (StreamState s) {
            switch (s) {
                case StreamState.IDLE: return "IDLE";
                case StreamState.CONNECTING: return "CONNECTING";
                case StreamState.STREAMING: return "STREAMING";
                case StreamState.RECONNECTING: return "RECONNECTING";
                default: return "?";
            }
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

            var pipe = new Gst.Pipeline (null);

            // Real input branch, normalized to 16 kHz mono.
            var squeue = make_element ("queue");
            var in_convert = make_element ("audioconvert");
            var in_resample = make_element ("audioresample");
            var in_caps = make_element ("capsfilter");
            ((dynamic Gst.Element) in_caps).caps = Gst.Caps.from_string (MIX_CAPS);

            // Silence branch: a live source that keeps the mixer, encoder and
            // sink fed continuously. Volume 0 makes it digital silence, so it
            // never colours the real audio; when the real input drops out the
            // stream keeps sending silence instead of stalling the session.
            var silence = make_element ("audiotestsrc");
            ((dynamic Gst.Element) silence).is_live = true;
            ((dynamic Gst.Element) silence).volume = 0.0;
            var silence_caps = make_element ("capsfilter");
            ((dynamic Gst.Element) silence_caps).caps =
                Gst.Caps.from_string (MIX_CAPS);

            var mixer = make_element ("audiomixer");

            pipe.add_many (src, squeue, in_convert, in_resample, in_caps,
                silence, silence_caps, mixer);

            if (!src.link (squeue)
                || !squeue.link_many (in_convert, in_resample, in_caps)
                || !in_caps.link (mixer)) {
                throw new IOError.FAILED (
                    _("Could not link the streaming branch."));
            }
            if (!silence.link (silence_caps) || !silence_caps.link (mixer)) {
                throw new IOError.FAILED (
                    _("Could not link the silence branch."));
            }

            this.source_element = src;
            this.silence_element = silence;
            // The encoder and sink depend on the protocol; both consume the
            // mixed 16 kHz mono audio.
            Gst.Element sink = this.build_output (pipe, mixer);

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
            DebugLog.get_default ().log ("pipeline", "state=PLAYING");
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

        // Builds the encoder and sink for the target protocol, links them after
        // the mixer (whose output is already 16 kHz mono), and returns the sink.
        private Gst.Element build_output (Gst.Pipeline pipe,
            Gst.Element mixer) throws Error {
            switch (StreamUrl.protocol (this.target_uri)) {
                case StreamProtocol.SRT:
                    // Opus in MPEG-TS over RTP. Opus is built for 16 kHz mono
                    // speech: low CPU and low bitrate, and it decodes to the
                    // 16 kHz mono the ASR expects.
                    var srt_convert = make_element ("audioconvert");
                    var encoder = make_element ("opusenc");
                    var muxer = make_element ("mpegtsmux");
                    var payloader = make_element ("rtpmp2tpay");
                    var sink = make_element ("srtsink");
                    ((dynamic Gst.Element) encoder).bitrate = 24000;
                    // 7 TS packets per buffer (1316 bytes) is the standard
                    // MPEG-TS-over-UDP/SRT payload, so the receiver locks onto
                    // the stream reliably on connect.
                    ((dynamic Gst.Element) muxer).alignment = 7;
                    ((dynamic Gst.Element) sink).uri = this.target_uri;
                    pipe.add_many (srt_convert, encoder, muxer, payloader, sink);
                    if (!mixer.link_many (srt_convert, encoder, muxer,
                            payloader, sink)) {
                        throw new IOError.FAILED (
                            _("Could not link the SRT output."));
                    }
                    this.srt_sink = sink;
                    return sink;

                case StreamProtocol.RTMP:
                    // AAC in FLV at 16 kHz mono, the format ASR expects.
                    var rtmp_convert = make_element ("audioconvert");
                    var encoder = make_element ("avenc_aac");
                    var parser = make_element ("aacparse");
                    var muxer = make_element ("flvmux");
                    var sink = make_element ("rtmp2sink");
                    ((dynamic Gst.Element) muxer).streamable = true;
                    ((dynamic Gst.Element) sink).location = this.target_uri;
                    pipe.add_many (rtmp_convert, encoder, parser, muxer, sink);
                    if (!mixer.link_many (rtmp_convert, encoder, parser, muxer,
                            sink)) {
                        throw new IOError.FAILED (
                            _("Could not link the RTMP output."));
                    }
                    return sink;

                default:
                    throw new IOError.FAILED (
                        _("Unsupported streaming protocol."));
            }
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
            this.source_element = null;
            this.silence_element = null;
            this.srt_sink = null;
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
            this.schedule_reconnect (detail);
        }

        private void schedule_reconnect (string? detail) {
            if (this.state == StreamState.IDLE) {
                return;
            }
            this.cancel_reconnect ();
            this.change_state (StreamState.RECONNECTING, detail);

            // A session that has never carried data is almost certainly a bad
            // or expired address. Tell the user once; keep retrying regardless.
            if (!this.ever_streamed && !this.reported_connect_error) {
                this.reported_connect_error = true;
                this.connection_error (
                    _("Could not connect to the server. The stream address may "
                    + "be wrong or expired. Still retrying, but it is unlikely "
                    + "to succeed until the address is fixed."));
            }

            int shift = int.min (this.reconnect_attempt, 16);
            int backoff = int.min (1000 << shift, MAX_BACKOFF_MS);
            // Enforce the minimum reconnect delay (the early attempts would
            // otherwise be 1 to 4 s), so a drop is never retried too soon.
            backoff = int.max (backoff, MIN_BACKOFF_MS);
            DebugLog.get_default ().log ("reconnect",
                "attempt=" + this.reconnect_attempt.to_string () +
                " backoff_ms=" + backoff.to_string () +
                (detail != null ? " reason=" + detail : ""));
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

            // The SRT transport stats are the key clue for the intermittent
            // start: on a failed start the socket connects and packets are sent
            // and ACKed just like a working one, which points at the server.
            var dbg = DebugLog.get_default ();
            if (dbg.enabled && this.srt_sink != null) {
                Gst.Structure? st = ((dynamic Gst.Element) this.srt_sink).stats;
                if (st != null) {
                    dbg.log ("srt", "t=" + elapsed.to_string () +
                        "s app_bytes=" + total.to_string () +
                        " " + st.to_string ());
                }
            }

            this.stats (elapsed, total, packets, bitrate_kbps);
            return Source.CONTINUE;
        }

        private bool on_bus_message (Gst.Bus bus, Gst.Message message) {
            switch (message.type) {
                case Gst.MessageType.ERROR:
                    Error err;
                    string debug;
                    message.parse_error (out err, out debug);
                    DebugLog.get_default ().log ("bus",
                        "ERROR: " + err.message + " | " + debug);
                    this.recover (err.message);
                    break;
                case Gst.MessageType.EOS:
                    DebugLog.get_default ().log ("bus",
                        "EOS finishing=" + this.finishing.to_string ());
                    if (this.finishing) {
                        this.stop ();
                    } else {
                        this.recover (_("The stream ended."));
                    }
                    break;
                default:
                    break;
            }
            return Source.CONTINUE;
        }
    }
}
