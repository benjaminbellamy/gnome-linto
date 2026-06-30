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
    namespace SrtUrl {
        // Validates an SRT caller URL of the form
        // srt://host:port?streamid=...&mode=caller .
        // Returns null when valid, or a human-readable reason when not.
        public string? validate (string url) {
            string trimmed = url.strip ();
            if (trimmed == "") {
                return _("The SRT URL is empty. Set it in Preferences.");
            }
            if (!trimmed.has_prefix ("srt://")) {
                return _("The URL must start with srt://");
            }
            try {
                var uri = Uri.parse (trimmed, UriFlags.NONE);
                string? host = uri.get_host ();
                if (host == null || host == "") {
                    return _("The URL has no host.");
                }
                if (uri.get_port () <= 0) {
                    return _("The URL has no port (expected srt://host:port).");
                }
            } catch (Error e) {
                return _("The URL is malformed: %s").printf (e.message);
            }
            return null;
        }
    }
}
