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
    // A small WebSocket control server (for a Stream Controller client). It
    // pushes status JSON and accepts toggle/start/pause commands. Bound to
    // 0.0.0.0 with a password; wrong passwords are closed after a short delay.
    public class ControlServer : Object {
        public signal void command (string action);
        public signal void connection_changed (string message);

        // Last connection message and last status, so a new connection and the
        // dialog can be brought up to date immediately.
        public string status_message { get; private set; default = ""; }
        public bool running { get; private set; default = false; }

        private GLib.Settings settings;
        private Soup.Server? server = null;
        private GenericArray<Soup.WebsocketConnection> connections;
        private string current_status = "{}";
        private uint heartbeat_id = 0;

        construct {
            this.settings = new GLib.Settings (Config.APP_ID);
            this.connections = new GenericArray<Soup.WebsocketConnection> ();
            this.set_message (_("No Stream Controller connected"));
        }

        ~ControlServer () {
            this.stop ();
        }

        // 8 lowercase letters from a secure source.
        public static string generate_password () {
            var buf = new uint8[8];
            bool filled = false;
            try {
                var stream = File.new_for_path ("/dev/urandom").read ();
                size_t read;
                stream.read_all (buf, out read);
                filled = (read == buf.length);
                stream.close ();
            } catch (Error e) {
                filled = false;
            }
            if (!filled) {
                for (int i = 0; i < buf.length; i++) {
                    buf[i] = (uint8) Random.int_range (0, 256);
                }
            }
            var sb = new StringBuilder ();
            for (int i = 0; i < buf.length; i++) {
                sb.append_c ((char) ('a' + (buf[i] % 26)));
            }
            return sb.str;
        }

        // Starts, stops or rebinds the server to match the current settings.
        public void apply_settings () {
            if (this.settings.get_boolean ("control-enabled")) {
                this.restart ();
            } else {
                this.stop ();
            }
        }

        public void restart () {
            this.stop ();

            this.server = (Soup.Server) Object.new (typeof (Soup.Server));
            this.server.add_websocket_handler ("/", null, null, this.on_websocket);

            int port = this.settings.get_int ("control-port");
            try {
                this.server.listen_all ((uint) port,
                    (Soup.ServerListenOptions) 0);
                this.running = true;
                this.set_message (_("No Stream Controller connected"));
                this.heartbeat_id = Timeout.add_seconds (5, () => {
                    this.broadcast (this.current_status);
                    return Source.CONTINUE;
                });
            } catch (Error e) {
                this.running = false;
                this.set_message (_("Server error: %s").printf (e.message));
            }
        }

        public void stop () {
            if (this.heartbeat_id != 0) {
                Source.remove (this.heartbeat_id);
                this.heartbeat_id = 0;
            }
            for (int i = 0; i < this.connections.length; i++) {
                var conn = this.connections.get (i);
                if (conn.get_state () == Soup.WebsocketState.OPEN) {
                    conn.close (Soup.WebsocketCloseCode.NORMAL, null);
                }
            }
            this.connections = new GenericArray<Soup.WebsocketConnection> ();
            if (this.server != null) {
                this.server.disconnect ();
                this.server = null;
            }
            this.running = false;
        }

        // Stores the latest status and pushes it to every open connection.
        public void broadcast_status (string json) {
            this.current_status = json;
            this.broadcast (json);
        }

        private void broadcast (string text) {
            for (int i = 0; i < this.connections.length; i++) {
                var conn = this.connections.get (i);
                if (conn.get_state () == Soup.WebsocketState.OPEN) {
                    conn.send_text (text);
                }
            }
        }

        private void set_message (string message) {
            this.status_message = message;
            this.connection_changed (message);
        }

        private void on_websocket (Soup.Server server, Soup.ServerMessage msg,
            string path, Soup.WebsocketConnection connection) {
            string ip = client_ip (msg);
            string expected = this.settings.get_string ("control-password");
            string? provided = query_password (msg);

            if (expected == "" || provided == null || provided != expected) {
                this.set_message (_("Password error (%s)").printf (ip));
                // Delay the close a little to slow brute-force attempts.
                Timeout.add (1000, () => {
                    if (connection.get_state () == Soup.WebsocketState.OPEN) {
                        connection.close (Soup.WebsocketCloseCode.NORMAL, null);
                    }
                    return Source.REMOVE;
                });
                return;
            }

            this.connections.add (connection);
            this.set_message (_("Stream Controller connected (%s)").printf (ip));

            connection.message.connect ((type, message) => {
                this.on_message (bytes_to_string (message));
            });
            connection.closed.connect (() => {
                this.connections.remove (connection);
                if (this.connections.length == 0) {
                    this.set_message (_("No Stream Controller connected"));
                }
            });

            if (connection.get_state () == Soup.WebsocketState.OPEN) {
                connection.send_text (this.current_status);
            }
        }

        private void on_message (string text) {
            if ("toggle" in text) {
                this.command ("toggle");
            } else if ("pause" in text) {
                this.command ("pause");
            } else if ("start" in text) {
                this.command ("start");
            }
        }

        private static string? query_password (Soup.ServerMessage msg) {
            unowned GLib.Uri? uri = msg.get_uri ();
            if (uri == null || uri.get_query () == null) {
                return null;
            }
            try {
                var params = GLib.Uri.parse_params (uri.get_query (), -1, "&",
                    GLib.UriParamsFlags.NONE);
                return params.get ("password");
            } catch (Error e) {
                return null;
            }
        }

        private static string client_ip (Soup.ServerMessage msg) {
            var remote = msg.get_remote_address () as InetSocketAddress;
            if (remote != null) {
                return remote.get_address ().to_string ();
            }
            return "?";
        }

        private static string bytes_to_string (Bytes bytes) {
            unowned uint8[]? data = bytes.get_data ();
            if (data == null) {
                return "";
            }
            var sb = new StringBuilder ();
            sb.append_len ((string) data, (ssize_t) data.length);
            return sb.str;
        }
    }
}
