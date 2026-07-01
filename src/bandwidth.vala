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
    namespace Bandwidth {
        private const string HOST = "speed.cloudflare.com";
        private const int PAYLOAD_BYTES = 5000000; // 5 MB

        // Measures upload throughput in Mbit/s by timing a POST of test data to
        // a speed-test endpoint. Returns a negative value on failure.
        public async double upload_mbps () {
            var client = new SocketClient ();
            client.tls = true;
            client.timeout = 15;
            try {
                var conn = yield client.connect_to_host_async (HOST, 443, null);

                var body = new uint8[PAYLOAD_BYTES];
                string headers =
                    "POST /__up HTTP/1.1\r\n" +
                    "Host: " + HOST + "\r\n" +
                    "User-Agent: gnome-linto\r\n" +
                    "Content-Type: application/octet-stream\r\n" +
                    "Content-Length: %d\r\n".printf (PAYLOAD_BYTES) +
                    "Connection: close\r\n\r\n";

                unowned OutputStream ostream = conn.output_stream;
                size_t written;
                yield ostream.write_all_async (headers.data, Priority.DEFAULT,
                    null, out written);

                var timer = new Timer ();
                yield ostream.write_all_async (body, Priority.DEFAULT, null,
                    out written);
                yield ostream.flush_async (Priority.DEFAULT, null);
                double seconds = timer.elapsed ();

                var input = new DataInputStream (conn.input_stream);
                string? status = yield input.read_line_async ();
                try {
                    conn.close ();
                } catch (Error e) {
                    // Closing a finished probe connection can be ignored.
                }

                if (status != null && "200" in status && seconds > 0.0) {
                    return (double) PAYLOAD_BYTES * 8.0 / seconds / 1e6;
                }
            } catch (Error e) {
                // Offline, TLS failure, or the endpoint is unreachable.
            }
            return -1.0;
        }
    }
}
