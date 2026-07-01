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
        BAD
    }

    [GtkTemplate (ui = "/ai/linto/gnomelinto/ui/window.ui")]
    public class Window : Adw.ApplicationWindow {
        [GtkChild] private unowned Adw.ActionRow adapter_row;
        [GtkChild] private unowned Gtk.Image adapter_icon;
        [GtkChild] private unowned Adw.ActionRow local_ip_row;
        [GtkChild] private unowned Gtk.Image local_ip_icon;
        [GtkChild] private unowned Adw.ActionRow public_ip_row;
        [GtkChild] private unowned Gtk.Image public_ip_icon;
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
        [GtkChild] private unowned Gtk.Button refresh_button;

        private const int CHECK_ADAPTER = 0;
        private const int CHECK_LOCAL_IP = 1;
        private const int CHECK_PUBLIC_IP = 2;
        private const int CHECK_INTERNET = 3;
        private const int CHECK_WEBSITE = 4;
        private const int CHECK_LATENCY = 5;
        private const int CHECK_BANDWIDTH = 6;
        // Minimum upload the check treats as sufficient to stream (Mbit/s).
        private const double MIN_UPLOAD_MBPS = 1.0;
        private CheckStatus[] check_statuses = new CheckStatus[7];
        [GtkChild] private unowned Adw.ComboRow device_row;
        [GtkChild] private unowned Gtk.LevelBar level_bar;
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

        public Window (Adw.Application app) {
            Object (application: app);
        }

        construct {
            this.settings = new GLib.Settings (Config.APP_ID);
            this.stats_store = new StatsStore ();
            this.show_stored_stats (this.settings.get_string ("srt-url").strip ());
            this.settings.changed["srt-url"].connect (() => {
                if (!this.streamer.is_active) {
                    this.show_stored_stats (
                        this.settings.get_string ("srt-url").strip ());
                }
            });

            this.audio_monitor = new AudioMonitor ();
            this.audio_monitor.level.connect ((peak) => {
                this.level_bar.value = peak;
            });

            this.streamer = new Streamer ();
            this.streamer.level.connect ((peak) => {
                this.level_bar.value = peak;
            });
            this.streamer.state_changed.connect (this.on_stream_state_changed);
            this.streamer.stats.connect (this.on_stream_stats);

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

            this.run_checks.begin ();
            // Measured once at startup; the refresh button re-runs the others.
            this.measure_bandwidth.begin ();
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
        }

        [GtkCallback]
        private void on_stream_clicked () {
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

            // Free the preview pipeline so the device is available to stream.
            this.audio_monitor.stop ();
            // Re-resolve the device on every (re)build so the stream survives
            // an unplug/replug of the input.
            string id = device_identifier;
            this.streamer.start (() => {
                var device = this.audio_monitor.find_device (id);
                return (device != null)
                    ? AudioMonitor.create_source (device)
                    : null;
            }, url);
        }

        private void on_stream_state_changed (StreamState state, string? detail) {
            switch (state) {
                case StreamState.CONNECTING:
                case StreamState.STREAMING:
                case StreamState.RECONNECTING:
                    this.stream_button.label = _("Pause");
                    this.stream_button.remove_css_class ("suggested-action");
                    this.stream_button.add_css_class ("destructive-action");
                    this.device_row.sensitive = false;
                    // The address cannot be changed mid-stream.
                    this.set_prefs_enabled (false);
                    string lead = protocol_lead (this.active_url);
                    if (state == StreamState.CONNECTING) {
                        this.streaming_expander.subtitle = lead + _("Connecting…");
                    } else if (state == StreamState.RECONNECTING) {
                        this.streaming_expander.subtitle =
                            lead + _("Reconnecting…");
                    }
                    break;
                case StreamState.IDLE:
                    this.stream_button.label = _("Start streaming");
                    this.stream_button.remove_css_class ("destructive-action");
                    this.stream_button.add_css_class ("suggested-action");
                    this.device_row.sensitive =
                        this.audio_monitor.devices.length > 0;
                    this.set_prefs_enabled (true);
                    // Persist the final totals for this URL.
                    this.stats_store.flush ();
                    // Statistics stay on screen; they are never reset.
                    // Resume the preview level meter.
                    this.audio_monitor.select (this.device_row.selected);
                    break;
            }
        }

        private void on_stream_stats (int64 elapsed, uint64 bytes,
            uint64 packets, double bitrate_kbps) {
            int64 total_bytes = this.baseline.bytes + (int64) bytes;
            int64 total_packets = this.baseline.packets + (int64) packets;
            int64 total_seconds = this.baseline.seconds + elapsed;
            int64 now = real_now ();

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

        // Enables or disables the Stream address action (its menu item and
        // shortcut), so the address cannot be changed while streaming.
        private void set_prefs_enabled (bool enabled) {
            var app = this.application as Gtk.Application;
            if (app == null) {
                return;
            }
            var action = app.lookup_action ("preferences") as SimpleAction;
            if (action != null) {
                action.set_enabled (enabled);
            }
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
            this.apply_status (CHECK_LOCAL_IP, this.local_ip_icon, CheckStatus.CHECKING);
            this.apply_status (CHECK_PUBLIC_IP, this.public_ip_icon, CheckStatus.CHECKING);
            this.apply_status (CHECK_INTERNET, this.internet_icon, CheckStatus.CHECKING);
            this.apply_status (CHECK_WEBSITE, this.website_icon, CheckStatus.CHECKING);
            this.apply_status (CHECK_LATENCY, this.latency_icon, CheckStatus.CHECKING);

            // Local IP and adapter are resolved together and quickly.
            update_local_and_adapter ();

            // Network round-trips run concurrently.
            this.check_internet.begin ();
            this.check_website.begin ();
            this.check_latency.begin ();
            this.check_public_ip.begin ((obj, res) => {
                this.check_public_ip.end (res);
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
            string? local_ip = get_local_ip ();

            if (local_ip != null) {
                this.local_ip_row.subtitle = local_ip;
                this.apply_status (CHECK_LOCAL_IP, this.local_ip_icon,
                    CheckStatus.OK);

                bool is_up;
                string? name = NetInfo.iface_for_ip (local_ip, out is_up);
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
                this.local_ip_row.subtitle = _("Unavailable");
                this.apply_status (CHECK_LOCAL_IP, this.local_ip_icon,
                    CheckStatus.BAD);
                this.adapter_row.subtitle = _("No active adapter");
                this.apply_status (CHECK_ADAPTER, this.adapter_icon,
                    CheckStatus.BAD);
            }
        }

        private static string? get_local_ip () {
            try {
                var socket = new Socket (SocketFamily.IPV4, SocketType.DATAGRAM,
                    SocketProtocol.UDP);
                // A datagram connect sets the outbound route without sending
                // any traffic, which reveals the local source address.
                var target = new InetSocketAddress (
                    new InetAddress.from_string ("8.8.8.8"), 80);
                socket.connect (target);
                var local = socket.get_local_address () as InetSocketAddress;
                socket.close ();
                if (local != null) {
                    return local.address.to_string ();
                }
            } catch (Error e) {
                // No route to a public address (offline).
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

        private async void check_public_ip () {
            string? ip = yield fetch_public_ip ();
            if (ip != null) {
                this.public_ip_row.subtitle = ip;
                this.apply_status (CHECK_PUBLIC_IP, this.public_ip_icon,
                    CheckStatus.OK);
            } else {
                this.public_ip_row.subtitle = _("Unavailable");
                this.apply_status (CHECK_PUBLIC_IP, this.public_ip_icon,
                    CheckStatus.BAD);
            }
        }

        private async string? fetch_public_ip () {
            var client = new SocketClient ();
            client.set_timeout (8);
            try {
                var conn = yield client.connect_to_host_async (
                    "api.ipify.org", 80, null);
                var request =
                    "GET / HTTP/1.1\r\n" +
                    "Host: api.ipify.org\r\n" +
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
        }

        private void update_network_summary () {
            int ok = 0;
            int checking = 0;
            foreach (var status in this.check_statuses) {
                if (status == CheckStatus.OK) {
                    ok++;
                } else if (status == CheckStatus.CHECKING) {
                    checking++;
                }
            }
            if (checking > 0) {
                this.network_expander.subtitle = _("Checking…");
            } else {
                this.network_expander.subtitle =
                    _("%d of %d checks OK").printf (ok,
                        this.check_statuses.length);
            }
        }

        private static void set_status (Gtk.Image icon, CheckStatus status) {
            icon.remove_css_class ("success");
            icon.remove_css_class ("error");
            switch (status) {
                case CheckStatus.OK:
                    icon.icon_name = "object-select-symbolic";
                    icon.add_css_class ("success");
                    break;
                case CheckStatus.BAD:
                    icon.icon_name = "process-stop-symbolic";
                    icon.add_css_class ("error");
                    break;
                default:
                    icon.icon_name = "content-loading-symbolic";
                    break;
            }
        }
    }
}
