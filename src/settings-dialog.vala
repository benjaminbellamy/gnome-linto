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
    // The application settings: the SRT send latency, the silence auto-pause
    // timeout, and the Stream Controller control server (enable, port, password,
    // address, status). Changes are written to GSettings immediately.
    [GtkTemplate (ui = "/ai/linto/gnomelinto/ui/settings.ui")]
    public class SettingsDialog : Adw.Dialog {
        [GtkChild] private unowned Adw.SpinRow srt_latency_row;
        [GtkChild] private unowned Gtk.Adjustment srt_latency_adjustment;
        [GtkChild] private unowned Gtk.Adjustment silence_adjustment;
        [GtkChild] private unowned Adw.SwitchRow voice_threshold_auto_row;
        [GtkChild] private unowned Adw.SpinRow voice_threshold_row;
        [GtkChild] private unowned Gtk.Adjustment voice_threshold_adjustment;
        [GtkChild] private unowned Adw.SwitchRow enable_row;
        [GtkChild] private unowned Gtk.Adjustment port_adjustment;
        [GtkChild] private unowned Adw.ActionRow password_row;
        [GtkChild] private unowned Adw.ActionRow address_row;
        [GtkChild] private unowned Adw.ActionRow status_row;
        [GtkChild] private unowned Adw.ToastOverlay toast_overlay;

        private GLib.Settings settings;
        // The main window, used to tell whether a stream is active (the latency
        // is read once at start, so it is locked while streaming) and to reach
        // the control server for its live status. Null when opened without a
        // window.
        public Window? window { private get; construct; }
        private ControlServer? server = null;
        private ulong connection_handler = 0;

        public SettingsDialog (Window? window) {
            Object (window: window);
        }

        construct {
            this.settings = new GLib.Settings (Config.APP_ID);

            this.bind_int_adjustment (this.srt_latency_adjustment, "srt-latency");
            this.bind_int_adjustment (this.silence_adjustment, "silence-timeout");

            // Voice level gate: an automatic switch, plus a manual dBFS row that
            // is only editable while automatic is off.
            this.settings.bind ("voice-threshold-auto",
                this.voice_threshold_auto_row, "active",
                SettingsBindFlags.DEFAULT);
            this.bind_int_adjustment (this.voice_threshold_adjustment,
                "voice-threshold");
            this.settings.bind ("voice-threshold-auto",
                this.voice_threshold_row, "sensitive",
                SettingsBindFlags.GET | SettingsBindFlags.INVERT_BOOLEAN);

            // Latency is an SRT-only knob and does not apply to RTMP, so the row
            // is shown only when the active address is an SRT URL.
            this.update_latency_visibility ();
            this.settings.changed["srt-url"].connect (
                this.update_latency_visibility);

            // The latency is read once at stream start, so a change only takes
            // effect on the next start; lock the row while a stream is active to
            // avoid the impression it applies live.
            this.srt_latency_row.sensitive =
                (this.window == null || !this.window.is_streaming ());

            // Control server (Stream Controller).
            this.settings.bind ("control-enabled", this.enable_row, "active",
                SettingsBindFlags.DEFAULT);
            this.password_row.subtitle =
                this.settings.get_string ("control-password");
            this.bind_int_adjustment (this.port_adjustment, "control-port");
            this.port_adjustment.value_changed.connect (this.refresh_address);
            this.refresh_address ();

            if (this.window != null) {
                this.server = this.window.control_server;
                this.status_row.subtitle = this.server.status_message;
                this.connection_handler =
                    this.server.connection_changed.connect ((msg) => {
                        this.status_row.subtitle = msg;
                    });
                this.closed.connect (() => {
                    if (this.connection_handler != 0) {
                        this.server.disconnect (this.connection_handler);
                        this.connection_handler = 0;
                    }
                });
            }
        }

        private void update_latency_visibility () {
            string url = this.settings.get_string ("srt-url").strip ();
            this.srt_latency_row.visible =
                StreamUrl.protocol (url) == StreamProtocol.SRT;
        }

        // Two-way binds an integer GSettings key to a spin row's adjustment:
        // seed from the setting, then write back on change (skipping no-ops).
        private void bind_int_adjustment (Gtk.Adjustment adjustment,
            string key) {
            adjustment.value = (double) this.settings.get_int (key);
            adjustment.value_changed.connect (() => {
                int value = (int) adjustment.value;
                if (value != this.settings.get_int (key)) {
                    this.settings.set_int (key, value);
                }
            });
        }

        [GtkCallback]
        private void on_generate () {
            var password = ControlServer.generate_password ();
            this.settings.set_string ("control-password", password);
            this.password_row.subtitle = password;
        }

        [GtkCallback]
        private void on_password_activated () {
            var password = this.settings.get_string ("control-password");
            this.get_clipboard ().set_text (password);
            this.toast_overlay.add_toast (
                new Adw.Toast (_("Password copied to clipboard")));
        }

        [GtkCallback]
        private void on_address_activated () {
            this.get_clipboard ().set_text (this.address_row.subtitle);
            this.toast_overlay.add_toast (
                new Adw.Toast (_("Address copied to clipboard")));
        }

        private void refresh_address () {
            // The outbound local IP, so the user knows what address to give the
            // Stream Controller plugin.
            string ip = Window.get_local_ip (SocketFamily.IPV4, "8.8.8.8")
                ?? "127.0.0.1";
            this.address_row.subtitle = "ws://%s:%d/".printf (
                ip, this.settings.get_int ("control-port"));
        }
    }
}
