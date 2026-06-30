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
    // Persistent per-URL streaming totals, stored in a key file in the user
    // data directory so they survive restarts and stay tied to each SRT URL.
    // A first_unix of 0 means the URL has never been streamed.
    public class StatsStore : Object {
        public struct Entry {
            int64 first_unix;
            int64 latest_unix;
            int64 bytes;
            int64 packets;
            int64 seconds;
        }

        private KeyFile keyfile = new KeyFile ();
        private string path;
        private int unsaved_ticks = 0;

        construct {
            this.path = Path.build_filename (
                Environment.get_user_data_dir (), "gnome-linto", "stats.ini");
            try {
                this.keyfile.load_from_file (this.path, KeyFileFlags.NONE);
            } catch (Error e) {
                // No stats yet on first run; start with an empty key file.
            }
        }

        public Entry get (string url) {
            Entry entry = Entry ();
            if (url == "" || !this.keyfile.has_group (url)) {
                return entry;
            }
            try {
                entry.first_unix = this.keyfile.get_int64 (url, "first");
                entry.latest_unix = this.keyfile.get_int64 (url, "latest");
                entry.bytes = this.keyfile.get_int64 (url, "bytes");
                entry.packets = this.keyfile.get_int64 (url, "packets");
                entry.seconds = this.keyfile.get_int64 (url, "seconds");
            } catch (Error e) {
                warning ("Could not read saved statistics: %s", e.message);
            }
            return entry;
        }

        public void put (string url, Entry entry) {
            if (url == "") {
                return;
            }
            this.keyfile.set_int64 (url, "first", entry.first_unix);
            this.keyfile.set_int64 (url, "latest", entry.latest_unix);
            this.keyfile.set_int64 (url, "bytes", entry.bytes);
            this.keyfile.set_int64 (url, "packets", entry.packets);
            this.keyfile.set_int64 (url, "seconds", entry.seconds);
        }

        public void flush () {
            this.unsaved_ticks = 0;
            try {
                DirUtils.create_with_parents (
                    Path.get_dirname (this.path), 0755);
                this.keyfile.save_to_file (this.path);
            } catch (Error e) {
                warning ("Could not save statistics: %s", e.message);
            }
        }

        // Writes to disk only every few calls, to limit churn while streaming.
        public void flush_throttled () {
            this.unsaved_ticks++;
            if (this.unsaved_ticks >= 5) {
                this.flush ();
            }
        }
    }
}
