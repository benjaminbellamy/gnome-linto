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
    public enum StreamProtocol {
        SRT,
        RTMP,
        WEBSOCKET,
        UNKNOWN
    }

    namespace StreamUrl {
        public StreamProtocol protocol (string url) {
            string u = url.strip ().down ();
            if (u.has_prefix ("srt://")) {
                return StreamProtocol.SRT;
            }
            if (u.has_prefix ("rtmp://") || u.has_prefix ("rtmps://")) {
                return StreamProtocol.RTMP;
            }
            if (u.has_prefix ("ws://") || u.has_prefix ("wss://")) {
                return StreamProtocol.WEBSOCKET;
            }
            return StreamProtocol.UNKNOWN;
        }

        // Validates a streaming URL. Returns null when valid and supported, or a
        // human-readable reason when not.
        public string? validate (string url) {
            string trimmed = url.strip ();
            if (trimmed == "") {
                return _("The streaming URL is empty. Set it in Preferences.");
            }
            switch (protocol (trimmed)) {
                case StreamProtocol.UNKNOWN:
                    return _("The URL must start with srt://, rtmp:// or rtmps://");
                case StreamProtocol.WEBSOCKET:
                    return _("WebSocket (ws/wss) output is not supported yet.");
                default:
                    break;
            }
            try {
                var uri = Uri.parse (trimmed, UriFlags.NONE);
                string? host = uri.get_host ();
                if (host == null || host == "") {
                    return _("The URL has no host.");
                }
                if (protocol (trimmed) == StreamProtocol.SRT &&
                    uri.get_port () <= 0) {
                    return _("The SRT URL has no port (expected srt://host:port).");
                }
            } catch (Error e) {
                return _("The URL is malformed: %s").printf (e.message);
            }
            return null;
        }

        // True when the URL looks like a public web URL (http or https). The
        // one definition of an acceptable transcription URL, used by the CSV
        // column heuristic and the address editor's field and paste button.
        public bool is_web_url (string url) {
            string u = url.strip ().down ();
            return u.has_prefix ("http://") || u.has_prefix ("https://");
        }

        // Returns true when the URL's query string already contains the given
        // parameter (matched case-insensitively). Used to leave a URL-provided
        // value untouched when applying app defaults.
        public bool has_query_param (string url, string name) {
            try {
                var uri = Uri.parse (url.strip (), UriFlags.NONE);
                string? query = uri.get_query ();
                if (query == null || query == "") {
                    return false;
                }
                var pairs = Uri.parse_params (query, -1, "&",
                                              UriParamsFlags.CASE_INSENSITIVE);
                return pairs.contains (name);
            } catch (Error e) {
                return false;
            }
        }
    }
}
