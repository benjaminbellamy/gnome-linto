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
    private enum CheckStatus {
        CHECKING,
        OK,
        BAD,
        // Not applicable / not configured (for example no IPv6 on the host).
        // Shown to the user but not counted as a failure, since the LinTO
        // server is IPv4 only and IPv6 being absent does not block streaming.
        NEUTRAL
    }

    [GtkTemplate (ui = "/ai/linto/gnomelinto/ui/window.ui")]
    public class Window : Adw.ApplicationWindow {
        [GtkChild] private unowned Adw.ActionRow adapter_row;
        [GtkChild] private unowned Gtk.Image adapter_icon;
        [GtkChild] private unowned Adw.ActionRow local_ipv4_row;
        [GtkChild] private unowned Gtk.Image local_ipv4_icon;
        [GtkChild] private unowned Adw.ActionRow local_ipv6_row;
        [GtkChild] private unowned Gtk.Image local_ipv6_icon;
        [GtkChild] private unowned Adw.ActionRow public_ipv4_row;
        [GtkChild] private unowned Gtk.Image public_ipv4_icon;
        [GtkChild] private unowned Adw.ActionRow public_ipv6_row;
        [GtkChild] private unowned Gtk.Image public_ipv6_icon;
        [GtkChild] private unowned Adw.ActionRow internet_row;
        [GtkChild] private unowned Gtk.Image internet_icon;
        [GtkChild] private unowned Adw.ActionRow website_row;
        [GtkChild] private unowned Gtk.Image website_icon;
        [GtkChild] private unowned Adw.ActionRow latency_row;
        [GtkChild] private unowned Gtk.Image latency_icon;
        [GtkChild] private unowned Adw.ActionRow bandwidth_row;
        [GtkChild] private unowned Gtk.Image bandwidth_icon;
        [GtkChild] private unowned Adw.ExpanderRow network_expander;
        [GtkChild] private unowned Adw.ExpanderRow streaming_expander;
        [GtkChild] private unowned Adw.PreferencesGroup control_group;
        [GtkChild] private unowned Adw.ActionRow control_status_row;
        [GtkChild] private unowned Gtk.Button refresh_button;

        private const int CHECK_ADAPTER = 0;
        private const int CHECK_LOCAL_IPV4 = 1;
        private const int CHECK_LOCAL_IPV6 = 2;
        private const int CHECK_PUBLIC_IPV4 = 3;
        private const int CHECK_PUBLIC_IPV6 = 4;
        private const int CHECK_INTERNET = 5;
        private const int CHECK_WEBSITE = 6;
        private const int CHECK_LATENCY = 7;
        private const int CHECK_BANDWIDTH = 8;
        // Minimum upload the check treats as sufficient to stream (Mbit/s).
        private const double MIN_UPLOAD_MBPS = 1.0;
        private CheckStatus[] check_statuses = new CheckStatus[9];
        [GtkChild] private unowned Adw.ActionRow address_row;
        [GtkChild] private unowned Adw.ComboRow device_row;
        [GtkChild] private unowned Adw.ActionRow level_row;
        [GtkChild] private unowned Gtk.LevelBar level_bar;
        [GtkChild] private unowned Adw.ActionRow sent_row;
        [GtkChild] private unowned Gtk.LevelBar sent_bar;
        [GtkChild] private unowned Adw.ActionRow cpu_row;
        [GtkChild] private unowned Gtk.LevelBar cpu_bar;
        [GtkChild] private unowned Gtk.Button stream_button;
        [GtkChild] private unowned Adw.ToastOverlay toast_overlay;
        [GtkChild] private unowned Adw.ActionRow elapsed_row;
        [GtkChild] private unowned Adw.ActionRow data_row;
        [GtkChild] private unowned Adw.ActionRow packets_row;
        [GtkChild] private unowned Adw.ActionRow bitrate_row;
        [GtkChild] private unowned Adw.ActionRow first_streamed_row;
        [GtkChild] private unowned Adw.ActionRow latest_streamed_row;

        private AudioMonitor audio_monitor;
        private Streamer streamer;
        private GLib.Settings settings;
        private StatsStore stats_store;
        // Saved totals for the URL of the current run, added on top of the
        // streamer's per-run counts.
        private StatsStore.Entry baseline;
        private string active_url = "";
        // True when the current session never connected (likely a bad address),
        // so the streaming summary keeps showing the error while it retries.
        private bool connect_failed = false;

        // Global cool-down after stopping any stream, so nothing can start for
        // a few seconds (a new session that races the one the server is still
        // releasing tends to fail). It applies to every stream, including a
        // switch to a different address.
        private const int COOLDOWN_SECONDS = 5;
        private int64 cooldown_deadline_us = 0;
        private uint cooldown_timer_id = 0;
        // The address a switch is waiting to start once the cool-down elapses,
        // or "" when none is pending. Holding the confirmed URL (rather than a
        // flag that re-reads the selection later) keeps the switch on the target
        // the user actually confirmed.
        private string pending_start_url = "";

        // Live "sent data rate" meter, sampled a few times a second straight
        // from the streamer's byte counter, so the user can confirm audio is
        // actually leaving the app (the server has been seen receiving SRT with
        // no audio inside). Full scale is about 160 kbit/s, above the SRT wire
        // rate, so a healthy stream sits high and a stall drops it to zero.
        private const double SENT_BAR_FULL_BYTES_PER_SEC = 20000.0;
        private uint sent_meter_timer_id = 0;
        private uint64 sent_meter_last_bytes = 0;
        private int64 sent_meter_last_us = 0;

        // System-wide CPU usage, sampled once a second from /proc/stat, so the
        // user can tell whether the machine is saturated (for example when
        // another encoder such as OBS is running at the same time).
        private uint cpu_timer_id = 0;
        private uint64 cpu_last_total = 0;
        private uint64 cpu_last_idle = 0;
        // Last text shown in the two live readouts, so the 10 Hz level callback
        // and the 4 Hz sent-rate tick skip the string formatting and the widget
        // relayout when the displayed value has not changed.
        private string last_level_text = "";
        private string last_sent_text = "";

        public ControlServer control_server;
        // Latest totals, mirrored to the control server status.
        private int64 status_elapsed = 0;
        private int64 status_bytes = 0;
        private int status_bitrate = 0;

        public Window (Adw.Application app) {
            Object (application: app);
        }

        construct {
            this.settings = new GLib.Settings (Config.APP_ID);
            this.stats_store = new StatsStore ();
            this.show_stored_stats (this.settings.get_string ("srt-url").strip ());
            this.update_address_row ();
            this.settings.changed["srt-url"].connect (() => {
                if (!this.streamer.is_active) {
                    this.show_stored_stats (
                        this.settings.get_string ("srt-url").strip ());
                }
            });
            this.settings.changed["srt-url"].connect (this.update_address_row);
            this.settings.changed["addresses"].connect (this.update_address_row);

            this.audio_monitor = new AudioMonitor ();
            this.audio_monitor.level.connect ((peak, db) => {
                this.level_bar.value = peak;
                // Peak in dBFS: 0 is full scale (clipping), negative is
                // headroom; below the noise floor it just reads as silent.
                string text = (db <= -90.0)
                    ? _("Silent")
                    : _("%.1f dBFS").printf (db);
                if (text != this.last_level_text) {
                    this.last_level_text = text;
                    this.level_row.subtitle = text;
                }
            });

            // The sent-rate meter is a plain throughput bar, not a saturation
            // gauge: drop the default low/high colour thresholds so it fills in
            // one colour and does not read as "too loud" near the top.
            this.sent_bar.remove_offset_value ("low");
            this.sent_bar.remove_offset_value ("high");
            this.reset_sent_meter ();

            // The CPU bar keeps its default thresholds, so it colours toward the
            // top as the machine saturates (high CPU is a warning, unlike a high
            // data rate). Sample it once a second, whether streaming or not.
            this.read_cpu (out this.cpu_last_total, out this.cpu_last_idle);
            this.cpu_timer_id = Timeout.add_seconds (1, this.on_cpu_tick);

            this.streamer = new Streamer ();
            this.streamer.state_changed.connect (this.on_stream_state_changed);
            this.streamer.stats.connect (this.on_stream_stats);
            this.streamer.connection_error.connect (this.on_connection_error);

            this.populate_devices ();
            this.device_row.notify["selected"].connect (() => {
                if (!this.streamer.is_active) {
                    this.audio_monitor.select (this.device_row.selected);
                }
            });
            this.audio_monitor.devices_changed.connect (this.on_devices_changed);
            // Start monitoring the first available input.
            this.audio_monitor.select (this.device_row.selected);

            this.close_request.connect (this.on_close_request);

            // Control server (Stream Controller). Generate a password on first
            // use, then start it if enabled.
            if (this.settings.get_string ("control-password") == "") {
                this.settings.set_string ("control-password",
                    ControlServer.generate_password ());
            }
            this.control_server = new ControlServer ();
            this.control_server.command.connect (this.on_control_command);
            // Show the control-server connection status on the main window,
            // visible only while the server is enabled.
            this.control_status_row.subtitle = this.control_server.status_message;
            this.control_server.connection_changed.connect ((message) => {
                this.control_status_row.subtitle = message;
            });
            this.settings.bind ("control-enabled", this.control_group, "visible",
                SettingsBindFlags.GET);
            this.settings.changed["control-enabled"].connect (() => {
                this.control_server.apply_settings ();
            });
            this.settings.changed["control-port"].connect (() => {
                this.control_server.apply_settings ();
            });
            this.settings.changed["srt-url"].connect (this.push_status);
            this.control_server.apply_settings ();
            this.push_status ();

            this.run_checks.begin ();
            // Measured once at startup; the refresh button re-runs the others.
            this.measure_bandwidth.begin ();
        }

        private void on_control_command (string action) {
            if (action == "toggle") {
                this.toggle_stream ();
            } else if (action == "start") {
                if (!this.streamer.is_active) {
                    this.toggle_stream ();
                }
            } else if (action == "pause") {
                if (this.streamer.is_active) {
                    this.toggle_stream ();
                }
            }
        }

        private void push_status () {
            this.control_server.broadcast_status (this.build_status_json ());
        }

        private bool network_all_ok () {
            foreach (var status in this.check_statuses) {
                // NEUTRAL (for example no IPv6) does not count as a failure.
                if (status != CheckStatus.OK && status != CheckStatus.NEUTRAL) {
                    return false;
                }
            }
            return true;
        }

        // Records the latest pre-flight check values in the debug log, so a
        // captured session shows the network state it started from.
        private void log_network_checks () {
            var dbg = DebugLog.get_default ();
            if (!dbg.enabled) {
                return;
            }
            log_check (dbg, "adapter", this.adapter_row.subtitle,
                this.check_statuses[CHECK_ADAPTER]);
            log_check (dbg, "local IPv4", this.local_ipv4_row.subtitle,
                this.check_statuses[CHECK_LOCAL_IPV4]);
            log_check (dbg, "local IPv6", this.local_ipv6_row.subtitle,
                this.check_statuses[CHECK_LOCAL_IPV6]);
            log_check (dbg, "public IPv4", this.public_ipv4_row.subtitle,
                this.check_statuses[CHECK_PUBLIC_IPV4]);
            log_check (dbg, "public IPv6", this.public_ipv6_row.subtitle,
                this.check_statuses[CHECK_PUBLIC_IPV6]);
            log_check (dbg, "internet", this.internet_row.subtitle,
                this.check_statuses[CHECK_INTERNET]);
            log_check (dbg, "server", this.website_row.subtitle,
                this.check_statuses[CHECK_WEBSITE]);
            log_check (dbg, "latency", this.latency_row.subtitle,
                this.check_statuses[CHECK_LATENCY]);
            log_check (dbg, "upload", this.bandwidth_row.subtitle,
                this.check_statuses[CHECK_BANDWIDTH]);
        }

        private static void log_check (DebugLog dbg, string name,
            string? value, CheckStatus status) {
            string mark;
            switch (status) {
                case CheckStatus.OK: mark = "OK"; break;
                case CheckStatus.BAD: mark = "BAD"; break;
                case CheckStatus.NEUTRAL: mark = "n/a"; break;
                default: mark = "checking"; break;
            }
            dbg.log ("network",
                name + ": " + (value ?? "") + " [" + mark + "]");
        }

        private string build_status_json () {
            string state;
            switch (this.streamer.state) {
                case StreamState.CONNECTING: state = "connecting"; break;
                case StreamState.STREAMING: state = "streaming"; break;
                case StreamState.RECONNECTING: state = "reconnecting"; break;
                default: state = "idle"; break;
            }
            string url = this.settings.get_string ("srt-url").strip ();
            bool ready = StreamUrl.validate (url) == null
                && this.audio_monitor.devices.length > 0;
            string protocol;
            switch (StreamUrl.protocol (url)) {
                case StreamProtocol.SRT: protocol = "SRT"; break;
                case StreamProtocol.RTMP: protocol = "RTMP"; break;
                default: protocol = ""; break;
            }
            return "{\"type\":\"status\",\"state\":\"" + state + "\""
                + ",\"streaming\":" + (this.streamer.is_active ? "true" : "false")
                + ",\"ready\":" + (ready ? "true" : "false")
                + ",\"network_ok\":" + (this.network_all_ok () ? "true" : "false")
                + ",\"protocol\":\"" + protocol + "\""
                + ",\"elapsed\":" + this.status_elapsed.to_string ()
                + ",\"data_bytes\":" + this.status_bytes.to_string ()
                + ",\"bitrate_kbps\":" + this.status_bitrate.to_string ()
                + "}";
        }

        private async void measure_bandwidth () {
            this.apply_status (CHECK_BANDWIDTH, this.bandwidth_icon,
                CheckStatus.CHECKING);
            double mbps = yield Bandwidth.upload_mbps ();
            if (mbps < 0.0) {
                this.bandwidth_row.subtitle = _("Unavailable");
                this.apply_status (CHECK_BANDWIDTH, this.bandwidth_icon,
                    CheckStatus.BAD);
            } else if (mbps >= MIN_UPLOAD_MBPS) {
                this.bandwidth_row.subtitle = "%.1f Mbit/s".printf (mbps);
                this.apply_status (CHECK_BANDWIDTH, this.bandwidth_icon,
                    CheckStatus.OK);
            } else {
                this.bandwidth_row.subtitle =
                    _("%.1f Mbit/s (too low)").printf (mbps);
                this.apply_status (CHECK_BANDWIDTH, this.bandwidth_icon,
                    CheckStatus.BAD);
            }
        }

        private void populate_devices () {
            // A wrapping label factory so long device names show in full
            // instead of being ellipsized.
            var factory = new Gtk.SignalListItemFactory ();
            factory.setup.connect ((object) => {
                var item = (Gtk.ListItem) object;
                item.child = new Gtk.Label (null) {
                    xalign = 0,
                    wrap = true,
                    wrap_mode = Pango.WrapMode.WORD_CHAR
                };
            });
            factory.bind.connect ((object) => {
                var item = (Gtk.ListItem) object;
                var label = (Gtk.Label) item.child;
                var str = (Gtk.StringObject) item.item;
                label.label = str.string;
            });
            this.device_row.factory = factory;

            var names = new Gtk.StringList (null);
            if (this.audio_monitor.devices.length == 0) {
                names.append (_("No input device found"));
                this.device_row.sensitive = false;
            } else {
                foreach (var device in this.audio_monitor.devices.data) {
                    names.append (device.get_display_name ());
                }
                this.device_row.sensitive = true;
            }
            this.device_row.model = names;
        }

        private string? selected_device_id () {
            uint index = this.device_row.selected;
            if (index >= this.audio_monitor.devices.length) {
                return null;
            }
            return AudioMonitor.device_id (
                this.audio_monitor.devices.get ((int) index));
        }

        private void select_device_by_id (string? id) {
            if (id == null) {
                return;
            }
            for (uint i = 0; i < this.audio_monitor.devices.length; i++) {
                if (AudioMonitor.device_id (
                        this.audio_monitor.devices.get ((int) i)) == id) {
                    this.device_row.selected = i;
                    return;
                }
            }
        }

        // Inputs were plugged in or removed. Keep the picker in sync without
        // disturbing an active stream (the streamer re-resolves its device).
        private void on_devices_changed () {
            if (this.streamer.is_active) {
                return;
            }
            string? previous = this.selected_device_id ();
            this.populate_devices ();
            this.select_device_by_id (previous);
            this.audio_monitor.select (this.device_row.selected);
        }

        [GtkCallback]
        private void on_refresh_clicked () {
            this.run_checks.begin ();
            this.measure_bandwidth.begin ();
        }

        [GtkCallback]
        private void on_stream_clicked () {
            this.toggle_stream ();
        }

        [GtkCallback]
        private void on_address_activated () {
            // Opens the Stream Address manager. It stays available while
            // streaming, so the user can switch to another address (which
            // stops the current stream and starts the new one after a prompt).
            this.application.activate_action ("preferences", null);
        }

        // Shows the active address label (or its URL) on the main window.
        private void update_address_row () {
            string label = AddressBook.active_label (this.settings);
            // Escape it: the row subtitle is Pango markup and a URL fallback can
            // contain "&" (SRT), which would otherwise break rendering.
            this.address_row.subtitle = label != ""
                ? Markup.escape_text (label)
                : _("No address");
        }

        // Begins the global cool-down and refreshes the start button so it
        // shows the countdown right away.
        private void start_cooldown () {
            this.cooldown_deadline_us =
                GLib.get_monotonic_time () + COOLDOWN_SECONDS * 1000000;
            if (this.cooldown_timer_id == 0) {
                this.cooldown_timer_id =
                    Timeout.add (250, this.on_cooldown_tick);
            }
            this.update_stream_button ();
        }

        private bool on_cooldown_tick () {
            if (this.cooldown_remaining_seconds () <= 0) {
                this.cooldown_deadline_us = 0;
                this.cooldown_timer_id = 0;
                // A switch waits out the cool-down, then starts the address it
                // confirmed on its own so the switch still completes.
                if (this.pending_start_url != "") {
                    string url = this.pending_start_url;
                    this.pending_start_url = "";
                    if (StreamUrl.validate (url) == null
                        && this.selected_device_id () != null) {
                        this.begin_stream (url);
                    }
                }
                this.update_stream_button ();
                return Source.REMOVE;
            }
            this.update_stream_button ();
            return Source.CONTINUE;
        }

        // Whole seconds left in the cool-down, rounded up, or 0 when none.
        private int cooldown_remaining_seconds () {
            if (this.cooldown_deadline_us == 0) {
                return 0;
            }
            int64 diff = this.cooldown_deadline_us - GLib.get_monotonic_time ();
            if (diff <= 0) {
                return 0;
            }
            return (int) ((diff + 999999) / 1000000);
        }

        // Sets the start button label and sensitivity for the current
        // cool-down. Does nothing while a stream is active, where the button
        // shows Pause.
        private void update_stream_button () {
            if (this.streamer.is_active) {
                return;
            }
            int remaining = this.cooldown_remaining_seconds ();
            if (remaining > 0) {
                this.stream_button.sensitive = false;
                this.stream_button.label =
                    _("Start in %d s").printf (remaining);
            } else {
                this.stream_button.sensitive = true;
                this.stream_button.label = _("Start streaming");
            }
        }

        public void toggle_stream () {
            if (this.streamer.is_active) {
                // Pausing ends the stream gracefully with an end of stream.
                this.streamer.finish ();
                return;
            }

            string url = this.settings.get_string ("srt-url").strip ();
            string? url_error = StreamUrl.validate (url);
            if (url_error != null) {
                this.toast (url_error);
                return;
            }
            string? device_identifier = this.selected_device_id ();
            if (device_identifier == null) {
                this.toast (_("No audio input device is available."));
                return;
            }

            // No stream may start during the cool-down after a stop.
            int remaining = this.cooldown_remaining_seconds ();
            if (remaining > 0) {
                this.toast (
                    _("Please wait %d s before starting a stream.").printf (
                        remaining));
                return;
            }

            this.begin_stream (url);
        }

        // Starts streaming the given URL, replacing any current stream (the
        // streamer stops the old pipeline before building the new one). The
        // caller has already validated the URL and confirmed an input device.
        private void begin_stream (string url) {
            // Any stream starting now settles any pending switch start.
            this.pending_start_url = "";
            // Load (or start) the saved totals for this URL. A never-seen URL
            // begins at zero; an existing one continues from its saved totals.
            this.active_url = url;
            this.baseline = this.stats_store.get (url);
            int64 now = real_now ();
            if (this.baseline.first_unix == 0) {
                this.baseline.first_unix = now;
            }
            this.first_streamed_row.subtitle =
                format_datetime (this.baseline.first_unix);
            this.latest_streamed_row.subtitle = format_datetime (now);
            var seed = this.baseline;
            seed.latest_unix = now;
            this.stats_store.put (url, seed);
            this.stats_store.flush ();

            // Open a fresh debug log for this session and record the stream
            // label and the current network checks before streaming (no-op when
            // logging is disabled).
            DebugLog.get_default ().new_session ();
            DebugLog.get_default ().log ("session",
                "label=" + AddressBook.label_for (this.settings, url));
            this.log_network_checks ();

            // The capture pipeline keeps running and already holds the mono
            // input, so streaming just bridges to it; the PipeWire node is not
            // recreated on start or pause.
            this.connect_failed = false;
            this.streamer.start (() => {
                return this.audio_monitor.create_stream_source ();
            }, url);
        }

        // Whether a stream is currently running. The address manager reads this
        // to decide whether picking another address is a live switch.
        public bool is_streaming () {
            return this.streamer.is_active;
        }

        // Whether the given URL is the stream currently running, so the address
        // manager can prevent editing the address while it is being streamed.
        public bool is_active_stream (string url) {
            return this.streamer.is_active && url == this.active_url;
        }

        // Asks to switch to another address while streaming. Confirms first,
        // then stops the current stream and starts the new one. On cancel, the
        // address list rolls its selection back. Called by the address manager.
        public void request_switch (string new_url, Preferences prefs) {
            string? url_error = StreamUrl.validate (new_url);
            if (url_error != null) {
                this.toast (url_error);
                prefs.reset_selection ();
                return;
            }
            string label = AddressBook.label_for (this.settings, new_url);
            var dialog = new Adw.AlertDialog (
                _("Switch stream address?"),
                _("Do you want to switch to %s?").printf (label));
            dialog.add_response ("cancel", _("Cancel"));
            dialog.add_response ("switch", _("Switch"));
            dialog.set_response_appearance ("switch",
                Adw.ResponseAppearance.SUGGESTED);
            dialog.set_default_response ("switch");
            dialog.set_close_response ("cancel");
            dialog.choose.begin (this, null, (obj, res) => {
                string response = dialog.choose.end (res);
                if (response == "switch") {
                    this.do_switch (new_url);
                    prefs.close ();
                } else {
                    prefs.reset_selection ();
                }
            });
        }

        private void do_switch (string new_url) {
            // Commit the selection so the main window and the address list
            // agree, stop the current stream, then let the cool-down elapse
            // before the new address starts (the same delay as any stream).
            AddressBook.select (this.settings, new_url);
            if (!this.streamer.is_active) {
                return;
            }
            // Only queue the start when there is a live stream to stop, so the
            // pending URL is always consumed by the IDLE that finish () produces.
            this.pending_start_url = new_url;
            this.streamer.finish ();
        }

        private void on_stream_state_changed (StreamState state, string? detail) {
            switch (state) {
                case StreamState.CONNECTING:
                case StreamState.STREAMING:
                case StreamState.RECONNECTING:
                    this.stream_button.label = _("Pause");
                    this.stream_button.sensitive = true;
                    this.stream_button.remove_css_class ("suggested-action");
                    this.stream_button.add_css_class ("destructive-action");
                    this.device_row.sensitive = false;
                    this.start_sent_meter ();
                    string lead = protocol_lead (this.active_url);
                    if (state == StreamState.STREAMING) {
                        this.connect_failed = false;
                    }
                    if (state == StreamState.CONNECTING) {
                        this.streaming_expander.subtitle = lead + _("Connecting…");
                    } else if (state == StreamState.RECONNECTING) {
                        this.streaming_expander.subtitle = this.connect_failed
                            ? lead + _("Cannot connect, check the address")
                            : lead + _("Reconnecting…");
                    }
                    break;
                case StreamState.IDLE:
                    this.stream_button.remove_css_class ("destructive-action");
                    this.stream_button.add_css_class ("suggested-action");
                    this.device_row.sensitive =
                        this.audio_monitor.devices.length > 0;
                    this.connect_failed = false;
                    // Start the global cool-down for the stream that just
                    // stopped; it disables the start button and shows a
                    // countdown. It applies to any stream, so even a switch
                    // waits it out (then auto-starts the selected address).
                    this.start_cooldown ();
                    // Stop the live sent-rate meter and empty it; nothing is
                    // being sent while idle.
                    this.stop_sent_meter ();
                    // Stop feeding the (now torn-down) stream source.
                    this.audio_monitor.detach_stream_source ();
                    // Persist the final totals for this URL.
                    this.stats_store.flush ();
                    // Statistics stay on screen; they are never reset. The VU
                    // meter keeps running from the always-on capture pipeline.
                    break;
            }
            this.push_status ();
        }

        // Starts sampling the streamer's byte counter for the live sent-rate
        // meter. Safe to call on every active state change; it only arms once.
        private void start_sent_meter () {
            if (this.sent_meter_timer_id != 0) {
                return;
            }
            this.sent_meter_last_bytes = this.streamer.bytes_sent ();
            this.sent_meter_last_us = GLib.get_monotonic_time ();
            this.sent_meter_timer_id =
                Timeout.add (250, this.on_sent_meter_tick);
        }

        private void stop_sent_meter () {
            if (this.sent_meter_timer_id != 0) {
                Source.remove (this.sent_meter_timer_id);
                this.sent_meter_timer_id = 0;
            }
            this.reset_sent_meter ();
        }

        private void reset_sent_meter () {
            this.sent_bar.value = 0;
            this.last_sent_text = _("0 B/s");
            this.sent_row.subtitle = this.last_sent_text;
        }

        // Reads how many bytes have been handed to the network sink since the
        // last tick and turns it into a bytes-per-second reading, so a stalled
        // send (audio not leaving) shows as an empty bar and 0 B/s.
        private bool on_sent_meter_tick () {
            uint64 now_bytes = this.streamer.bytes_sent ();
            int64 now_us = GLib.get_monotonic_time ();
            int64 delta_us = now_us - this.sent_meter_last_us;
            uint64 delta_bytes = (now_bytes >= this.sent_meter_last_bytes)
                ? now_bytes - this.sent_meter_last_bytes
                : 0;
            this.sent_meter_last_bytes = now_bytes;
            this.sent_meter_last_us = now_us;

            double rate = (delta_us > 0)
                ? (double) delta_bytes * 1000000.0 / (double) delta_us
                : 0.0;
            this.sent_bar.value =
                double.min (rate, SENT_BAR_FULL_BYTES_PER_SEC);
            string text = _("%s B/s").printf (((uint64) rate).to_string ());
            if (text != this.last_sent_text) {
                this.last_sent_text = text;
                this.sent_row.subtitle = text;
            }
            return Source.CONTINUE;
        }

        // Refreshes the system CPU usage readout from the delta since the last
        // sample. Runs every second for the whole session.
        private bool on_cpu_tick () {
            uint64 total, idle;
            if (!this.read_cpu (out total, out idle)) {
                this.cpu_row.subtitle = _("Unavailable");
                return Source.CONTINUE;
            }
            uint64 total_delta = total - this.cpu_last_total;
            uint64 idle_delta = idle - this.cpu_last_idle;
            this.cpu_last_total = total;
            this.cpu_last_idle = idle;

            double usage = (total_delta > 0)
                ? (double) (total_delta - idle_delta) / (double) total_delta
                : 0.0;
            usage = usage.clamp (0.0, 1.0);
            this.cpu_bar.value = usage;
            this.cpu_row.subtitle = _("%d%%").printf ((int) (usage * 100.0 + 0.5));
            return Source.CONTINUE;
        }

        // Reads the aggregate CPU counters from /proc/stat (system-wide, so it
        // includes every process). "total" is all jiffies, "idle" is idle plus
        // iowait; the caller turns two samples into a busy fraction.
        private bool read_cpu (out uint64 total, out uint64 idle) {
            total = 0;
            idle = 0;
            string contents;
            try {
                FileUtils.get_contents ("/proc/stat", out contents);
            } catch (Error e) {
                return false;
            }
            int nl = contents.index_of_char ('\n');
            string line = (nl >= 0) ? contents.substring (0, nl) : contents;
            uint64[] fields = {};
            foreach (string part in line.split (" ")) {
                if (part == "" || part == "cpu") {
                    continue;
                }
                fields += uint64.parse (part);
            }
            // Need at least user, nice, system, idle, iowait.
            if (fields.length < 5) {
                return false;
            }
            idle = fields[3] + fields[4];
            uint64 sum = 0;
            // Sum user..steal (guest time is already counted inside user/nice).
            int count = int.min (fields.length, 8);
            for (int i = 0; i < count; i++) {
                sum += fields[i];
            }
            total = sum;
            return true;
        }

        // The initial connection could not be established (typically a wrong or
        // expired address). Warn the user; the streamer keeps retrying.
        private void on_connection_error (string message) {
            this.connect_failed = true;
            this.toast (message);
            this.streaming_expander.subtitle =
                protocol_lead (this.active_url)
                + _("Cannot connect, check the address");
        }

        private void on_stream_stats (int64 elapsed, uint64 bytes,
            uint64 packets, double bitrate_kbps) {
            int64 total_bytes = this.baseline.bytes + (int64) bytes;
            int64 total_packets = this.baseline.packets + (int64) packets;
            int64 total_seconds = this.baseline.seconds + elapsed;
            int64 now = real_now ();

            this.status_elapsed = total_seconds;
            this.status_bytes = total_bytes;
            this.status_bitrate = (int) bitrate_kbps;

            string elapsed_text = format_duration (total_seconds);
            this.elapsed_row.subtitle = elapsed_text;
            this.data_row.subtitle =
                GLib.format_size (total_bytes, FormatSizeFlags.IEC_UNITS);
            this.packets_row.subtitle = total_packets.to_string ();
            this.bitrate_row.subtitle = "%.0f kbit/s".printf (bitrate_kbps);
            this.latest_streamed_row.subtitle = format_datetime (now);
            // Keep the collapsed summary as the connection state unless the
            // stream is actually flowing.
            if (this.streamer.state == StreamState.STREAMING) {
                this.streaming_expander.subtitle =
                    protocol_lead (this.active_url) +
                    "%s · %.0f kbit/s".printf (elapsed_text, bitrate_kbps);
            }

            var entry = this.baseline;
            entry.latest_unix = now;
            entry.bytes = total_bytes;
            entry.packets = total_packets;
            entry.seconds = total_seconds;
            this.stats_store.put (this.active_url, entry);
            this.stats_store.flush_throttled ();

            this.push_status ();
        }

        private void show_stored_stats (string url) {
            string idle_summary = protocol_lead (url) + _("Not streaming");
            var entry = this.stats_store.get (url);
            if (entry.first_unix == 0) {
                this.elapsed_row.subtitle = "0:00:00";
                this.data_row.subtitle = "0 B";
                this.packets_row.subtitle = "0";
                this.bitrate_row.subtitle = "0 kbit/s";
                this.first_streamed_row.subtitle = _("Never");
                this.latest_streamed_row.subtitle = _("Never");
                this.streaming_expander.subtitle = idle_summary;
            } else {
                this.elapsed_row.subtitle = format_duration (entry.seconds);
                this.data_row.subtitle =
                    GLib.format_size (entry.bytes, FormatSizeFlags.IEC_UNITS);
                this.packets_row.subtitle = entry.packets.to_string ();
                this.bitrate_row.subtitle = "0 kbit/s";
                this.first_streamed_row.subtitle =
                    format_datetime (entry.first_unix);
                this.latest_streamed_row.subtitle =
                    format_datetime (entry.latest_unix);
                this.streaming_expander.subtitle = idle_summary;
            }
        }

        // Short protocol tag ("SRT · ", "RTMP · ") for the condensed
        // Streaming summary, or empty when the URL scheme is unknown.
        private static string protocol_lead (string url) {
            switch (StreamUrl.protocol (url)) {
                case StreamProtocol.SRT:
                    return "SRT · ";
                case StreamProtocol.RTMP:
                    return "RTMP · ";
                default:
                    return "";
            }
        }

        private static int64 real_now () {
            return (int64) (GLib.get_real_time () / 1000000);
        }

        private static string format_datetime (int64 unix_seconds) {
            if (unix_seconds <= 0) {
                return _("Never");
            }
            var dt = new DateTime.from_unix_local (unix_seconds);
            return dt.format ("%Y-%m-%d %H:%M:%S");
        }

        private bool on_close_request () {
            this.stats_store.flush ();
            if (!this.streamer.is_active) {
                return false;
            }

            var dialog = new Adw.AlertDialog (
                _("Stop streaming?"),
                _("Streaming is in progress. Stop it and quit?"));
            dialog.add_response ("keep", _("Keep Streaming"));
            dialog.add_response ("stop", _("Stop and Quit"));
            dialog.set_response_appearance ("stop",
                Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.set_default_response ("keep");
            dialog.set_close_response ("keep");
            dialog.choose.begin (this, null, (obj, res) => {
                string response = dialog.choose.end (res);
                if (response == "stop") {
                    this.streamer.stop ();
                    this.destroy ();
                }
            });
            return true;
        }

        private void toast (string message) {
            this.toast_overlay.add_toast (new Adw.Toast (message));
        }

        private static string format_duration (int64 seconds) {
            int h = (int) (seconds / 3600);
            int m = (int) ((seconds % 3600) / 60);
            int s = (int) (seconds % 60);
            return "%d:%02d:%02d".printf (h, m, s);
        }

        private async void run_checks () {
            this.refresh_button.sensitive = false;

            this.apply_status (CHECK_ADAPTER, this.adapter_icon, CheckStatus.CHECKING);
            this.apply_status (CHECK_LOCAL_IPV4, this.local_ipv4_icon,
                CheckStatus.CHECKING);
            this.apply_status (CHECK_LOCAL_IPV6, this.local_ipv6_icon,
                CheckStatus.CHECKING);
            this.apply_status (CHECK_PUBLIC_IPV4, this.public_ipv4_icon,
                CheckStatus.CHECKING);
            this.apply_status (CHECK_PUBLIC_IPV6, this.public_ipv6_icon,
                CheckStatus.CHECKING);
            this.apply_status (CHECK_INTERNET, this.internet_icon, CheckStatus.CHECKING);
            this.apply_status (CHECK_WEBSITE, this.website_icon, CheckStatus.CHECKING);
            this.apply_status (CHECK_LATENCY, this.latency_icon, CheckStatus.CHECKING);

            // Local IP (both families) and the adapter are resolved together
            // and quickly.
            update_local_and_adapter ();

            // Network round-trips run concurrently.
            this.check_internet.begin ();
            this.check_website.begin ();
            this.check_latency.begin ();
            this.check_public_ipv6.begin ();
            this.check_public_ipv4.begin ((obj, res) => {
                this.check_public_ipv4.end (res);
                this.refresh_button.sensitive = true;
            });
        }

        // Measures round-trip latency to the LinTO server as the time to open a
        // TCP connection (the sandbox cannot send ICMP echo). Succeeds whenever
        // the connection is established; there is no latency threshold.
        private async void check_latency () {
            int latency_ms = -1;
            try {
                var resolver = Resolver.get_default ();
                var addresses = yield resolver.lookup_by_name_async (
                    "studio.linto.ai", null);
                if (addresses != null && addresses.length () > 0) {
                    var target = new InetSocketAddress (addresses.data, 443);
                    var client = new SocketClient ();
                    client.set_timeout (6);
                    var timer = new Timer ();
                    var conn = yield client.connect_async (target, null);
                    double elapsed = timer.elapsed ();
                    if (conn != null) {
                        latency_ms = (int) (elapsed * 1000.0);
                        try {
                            conn.close ();
                        } catch (Error e) {
                            // Closing a probe connection can be ignored.
                        }
                    }
                }
            } catch (Error e) {
                latency_ms = -1;
            }
            if (latency_ms >= 0) {
                this.latency_row.subtitle = _("%d ms").printf (latency_ms);
                this.apply_status (CHECK_LATENCY, this.latency_icon,
                    CheckStatus.OK);
            } else {
                this.latency_row.subtitle = _("No response");
                this.apply_status (CHECK_LATENCY, this.latency_icon,
                    CheckStatus.BAD);
            }
        }

        private void update_local_and_adapter () {
            string? local_ipv4 = get_local_ip (SocketFamily.IPV4, "8.8.8.8");
            string? local_ipv6 =
                get_local_ip (SocketFamily.IPV6, "2001:4860:4860::8888");

            // The LinTO server is IPv4 only, so a missing IPv4 route is a real
            // problem and is flagged; a missing IPv6 route is not.
            if (local_ipv4 != null) {
                this.local_ipv4_row.subtitle = local_ipv4;
                this.apply_status (CHECK_LOCAL_IPV4, this.local_ipv4_icon,
                    CheckStatus.OK);
            } else {
                this.local_ipv4_row.subtitle = _("Unavailable");
                this.apply_status (CHECK_LOCAL_IPV4, this.local_ipv4_icon,
                    CheckStatus.BAD);
            }

            if (local_ipv6 != null) {
                this.local_ipv6_row.subtitle = local_ipv6;
                this.apply_status (CHECK_LOCAL_IPV6, this.local_ipv6_icon,
                    CheckStatus.OK);
            } else {
                this.local_ipv6_row.subtitle = _("Unavailable");
                this.apply_status (CHECK_LOCAL_IPV6, this.local_ipv6_icon,
                    CheckStatus.NEUTRAL);
            }

            // Resolve the adapter from whichever local address exists,
            // preferring IPv4 so the name matches the streaming path.
            string? adapter_ip = local_ipv4 ?? local_ipv6;
            if (adapter_ip != null) {
                bool is_up;
                string? name = NetInfo.iface_for_ip (adapter_ip, out is_up);
                if (name != null) {
                    this.adapter_row.subtitle = is_up
                        ? _("%s (up)").printf (name)
                        : _("%s (down)").printf (name);
                    this.apply_status (CHECK_ADAPTER, this.adapter_icon,
                        is_up ? CheckStatus.OK : CheckStatus.BAD);
                } else {
                    this.adapter_row.subtitle = _("Unknown adapter");
                    this.apply_status (CHECK_ADAPTER, this.adapter_icon,
                        CheckStatus.BAD);
                }
            } else {
                this.adapter_row.subtitle = _("No active adapter");
                this.apply_status (CHECK_ADAPTER, this.adapter_icon,
                    CheckStatus.BAD);
            }
        }

        private static string? get_local_ip (SocketFamily family,
            string probe_address) {
            try {
                var socket = new Socket (family, SocketType.DATAGRAM,
                    SocketProtocol.UDP);
                // A datagram connect sets the outbound route without sending
                // any traffic, which reveals the local source address.
                var target = new InetSocketAddress (
                    new InetAddress.from_string (probe_address), 80);
                socket.connect (target);
                var local = socket.get_local_address () as InetSocketAddress;
                socket.close ();
                if (local != null) {
                    return local.address.to_string ();
                }
            } catch (Error e) {
                // No route to a public address in this family (offline or the
                // family is not configured).
            }
            return null;
        }

        private async void check_internet () {
            bool ok = false;
            var monitor = NetworkMonitor.get_default ();
            try {
                var target = new NetworkAddress ("1.1.1.1", 53);
                ok = yield monitor.can_reach_async (target);
            } catch (Error e) {
                ok = monitor.get_network_available ();
            }
            this.internet_row.subtitle = ok ? _("Available") : _("Unavailable");
            this.apply_status (CHECK_INTERNET, this.internet_icon,
                ok ? CheckStatus.OK : CheckStatus.BAD);
        }

        private async void check_website () {
            bool ok = false;
            var client = new SocketClient ();
            client.set_timeout (6);
            try {
                var conn = yield client.connect_to_host_async (
                    "studio.linto.ai", 443, null);
                if (conn != null) {
                    ok = true;
                    try {
                        conn.close ();
                    } catch (Error e) {
                        // Closing a probe connection can be ignored.
                    }
                }
            } catch (Error e) {
                ok = false;
            }
            this.website_row.subtitle = ok
                ? _("Reachable (studio.linto.ai:443)")
                : _("Not reachable (studio.linto.ai:443)");
            this.apply_status (CHECK_WEBSITE, this.website_icon,
                ok ? CheckStatus.OK : CheckStatus.BAD);
        }

        private async void check_public_ipv4 () {
            // The LinTO server is IPv4 only, so no public IPv4 is flagged.
            string? ip = yield fetch_public_ip ("api.ipify.org");
            if (ip != null) {
                this.public_ipv4_row.subtitle = ip;
                this.apply_status (CHECK_PUBLIC_IPV4, this.public_ipv4_icon,
                    CheckStatus.OK);
            } else {
                this.public_ipv4_row.subtitle = _("Unavailable");
                this.apply_status (CHECK_PUBLIC_IPV4, this.public_ipv4_icon,
                    CheckStatus.BAD);
            }
        }

        private async void check_public_ipv6 () {
            // No public IPv6 is not a failure; it is shown for information.
            string? ip = yield fetch_public_ip ("api6.ipify.org");
            if (ip != null) {
                this.public_ipv6_row.subtitle = ip;
                this.apply_status (CHECK_PUBLIC_IPV6, this.public_ipv6_icon,
                    CheckStatus.OK);
            } else {
                this.public_ipv6_row.subtitle = _("Unavailable");
                this.apply_status (CHECK_PUBLIC_IPV6, this.public_ipv6_icon,
                    CheckStatus.NEUTRAL);
            }
        }

        // Fetches the public IP as seen by the given ipify host. The host is
        // family specific (api.ipify.org is IPv4 only, api6.ipify.org is IPv6
        // only), so the returned address is in that family.
        private async string? fetch_public_ip (string host) {
            var client = new SocketClient ();
            client.set_timeout (8);
            try {
                var conn = yield client.connect_to_host_async (
                    host, 80, null);
                var request =
                    "GET / HTTP/1.1\r\n" +
                    "Host: " + host + "\r\n" +
                    "User-Agent: gnome-linto\r\n" +
                    "Connection: close\r\n\r\n";
                yield conn.output_stream.write_all_async (
                    request.data, Priority.DEFAULT, null, null);

                var input = new DataInputStream (conn.input_stream);
                // Skip headers up to the blank line.
                string? line;
                while ((line = yield input.read_line_async ()) != null) {
                    if (line.strip () == "") {
                        break;
                    }
                }
                // The body holds just the IP address.
                var body = new StringBuilder ();
                while ((line = yield input.read_line_async ()) != null) {
                    body.append (line);
                }
                try {
                    conn.close ();
                } catch (Error e) {
                    // Ignore close errors on a finished response.
                }

                string candidate = body.str.strip ();
                if (candidate != "" &&
                    new InetAddress.from_string (candidate) != null) {
                    return candidate;
                }
            } catch (Error e) {
                // Offline or the lookup service is unreachable.
            }
            return null;
        }

        private void apply_status (int index, Gtk.Image icon,
            CheckStatus status) {
            this.check_statuses[index] = status;
            set_status (icon, status);
            this.update_network_summary ();
            this.push_status ();
        }

        private void update_network_summary () {
            int ok = 0;
            int checking = 0;
            int applicable = 0;
            int unavailable = 0;
            foreach (var status in this.check_statuses) {
                if (status == CheckStatus.OK) {
                    ok++;
                    applicable++;
                } else if (status == CheckStatus.CHECKING) {
                    checking++;
                    applicable++;
                } else if (status == CheckStatus.BAD) {
                    applicable++;
                } else if (status == CheckStatus.NEUTRAL) {
                    // NEUTRAL checks (for example no IPv6) are not failures, so
                    // they stay out of the pass/fail ratio, but they are still
                    // reported so the summary does not hide that they were run.
                    unavailable++;
                }
            }
            if (checking > 0) {
                this.network_expander.subtitle = _("Checking…");
            } else if (unavailable > 0) {
                this.network_expander.subtitle =
                    _("%d of %d checks OK, %d unavailable").printf (
                        ok, applicable, unavailable);
            } else {
                this.network_expander.subtitle =
                    _("%d of %d checks OK").printf (ok, applicable);
            }
        }

        private static void set_status (Gtk.Image icon, CheckStatus status) {
            icon.remove_css_class ("success");
            icon.remove_css_class ("error");
            icon.remove_css_class ("dim-label");
            switch (status) {
                case CheckStatus.OK:
                    icon.icon_name = "object-select-symbolic";
                    icon.add_css_class ("success");
                    break;
                case CheckStatus.BAD:
                    icon.icon_name = "process-stop-symbolic";
                    icon.add_css_class ("error");
                    break;
                case CheckStatus.NEUTRAL:
                    // Present but not applicable (for example no IPv6): a muted
                    // dash, neither a success nor a failure.
                    icon.icon_name = "list-remove-symbolic";
                    icon.add_css_class ("dim-label");
                    break;
                default:
                    icon.icon_name = "content-loading-symbolic";
                    break;
            }
        }
    }
}
