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
    [GtkTemplate (ui = "/ai/linto/gnomelinto/ui/stream-controller.ui")]
    public class StreamControllerDialog : Adw.Dialog {
        [GtkChild] private unowned Adw.SwitchRow enable_row;
        [GtkChild] private unowned Gtk.Adjustment port_adjustment;
        [GtkChild] private unowned Adw.ActionRow password_row;
        [GtkChild] private unowned Adw.ActionRow address_row;
        [GtkChild] private unowned Adw.ActionRow status_row;
        [GtkChild] private unowned Adw.ToastOverlay toast_overlay;

        private GLib.Settings settings;
        private ControlServer server;
        private ulong connection_handler = 0;

        public StreamControllerDialog (ControlServer server) {
            Object ();
            this.server = server;
            this.status_row.subtitle = server.status_message;
            this.connection_handler = server.connection_changed.connect ((msg) => {
                this.status_row.subtitle = msg;
            });
            this.closed.connect (() => {
                if (this.connection_handler != 0) {
                    this.server.disconnect (this.connection_handler);
                    this.connection_handler = 0;
                }
            });
            this.refresh_address ();
        }

        construct {
            this.settings = new GLib.Settings (Config.APP_ID);
            this.settings.bind ("control-enabled", this.enable_row, "active",
                SettingsBindFlags.DEFAULT);
            this.password_row.subtitle =
                this.settings.get_string ("control-password");
            this.port_adjustment.value =
                (double) this.settings.get_int ("control-port");
            this.port_adjustment.value_changed.connect (() => {
                int port = (int) this.port_adjustment.value;
                if (port != this.settings.get_int ("control-port")) {
                    this.settings.set_int ("control-port", port);
                }
                this.refresh_address ();
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
            this.address_row.subtitle = "ws://%s:%d/".printf (
                local_ip (), this.settings.get_int ("control-port"));
        }

        // The outbound local IP, so the user knows what address to give the
        // Stream Controller plugin.
        private static string local_ip () {
            try {
                var socket = new Socket (SocketFamily.IPV4, SocketType.DATAGRAM,
                    SocketProtocol.UDP);
                var target = new InetSocketAddress (
                    new InetAddress.from_string ("8.8.8.8"), 80);
                socket.connect (target);
                var local = socket.get_local_address () as InetSocketAddress;
                socket.close ();
                if (local != null) {
                    return local.address.to_string ();
                }
            } catch (Error e) {
            }
            return "127.0.0.1";
        }
    }
}
