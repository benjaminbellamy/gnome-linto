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
    // A file logger for diagnosing streaming problems (notably the intermittent
    // SRT start). Off by default; when enabled a fresh, uniquely named log file
    // is opened for each streaming session, so every start can be compared side
    // by side. The enabled state follows the "debug-enabled" GSetting.
    public class DebugLog : Object {
        private static DebugLog? instance = null;

        public static DebugLog get_default () {
            if (instance == null) {
                instance = new DebugLog ();
            }
            return instance;
        }

        // True while logging is armed. Callers check this before building
        // expensive log strings, so logging costs nothing when disabled.
        public bool enabled { get; private set; default = false; }
        // The folder holding the per-session log files.
        public string directory { get; private set; }

        private GLib.FileStream? stream = null;
        private string? current_path = null;
        private Mutex mutex;
        private GLib.Settings settings;

        private DebugLog () {
            this.directory = Path.build_filename (
                Environment.get_user_data_dir (), "logs");
            DirUtils.create_with_parents (this.directory, 0755);

            this.settings = new GLib.Settings (Config.APP_ID);
            this.settings.changed["debug-enabled"].connect (this.sync_enabled);
            this.enabled = this.settings.get_boolean ("debug-enabled");
        }

        // Tracks the setting. Disabling closes the current file; enabling only
        // arms logging, the next streaming session opens the actual file.
        private void sync_enabled () {
            bool want = this.settings.get_boolean ("debug-enabled");
            this.mutex.lock ();
            this.enabled = want;
            if (!want && this.stream != null) {
                this.write_line ("app", "Logging disabled");
                this.stream = null;
            }
            this.mutex.unlock ();
        }

        // Opens a fresh, uniquely named log file for a new streaming session and
        // writes the version header. No-op when logging is disabled. Seconds are
        // in the name so quick pause/restart cycles never share a file.
        public void new_session () {
            if (!this.enabled) {
                return;
            }
            this.mutex.lock ();
            var now = new DateTime.now_local ();
            string name = "gnomelinto-" + now.format ("%Y-%m-%d-%H-%M-%S")
                + ".log";
            this.current_path = Path.build_filename (this.directory, name);
            this.stream = FileStream.open (this.current_path, "a");
            this.write_line ("app", "LinTO " + Config.VERSION);
            this.mutex.unlock ();
        }

        // Appends one timestamped line. The category groups related lines
        // (session, network, format, state, pipeline, srt, reconnect, ...).
        public void log (string category, string message) {
            this.mutex.lock ();
            this.write_line (category, message);
            this.mutex.unlock ();
        }

        // The most recent log file, for copying to the clipboard. Empty if there
        // is nothing to read yet.
        public string read_contents () {
            string? path = (this.current_path != null)
                ? this.current_path
                : this.newest_log ();
            if (path == null) {
                return "";
            }
            string contents;
            try {
                FileUtils.get_contents (path, out contents);
            } catch (Error e) {
                contents = "";
            }
            return contents;
        }

        // The newest session log on disk. The timestamped names sort
        // chronologically, so the lexicographic maximum is the latest.
        private string? newest_log () {
            string? best = null;
            try {
                var dir = Dir.open (this.directory);
                string? name;
                while ((name = dir.read_name ()) != null) {
                    if (name.has_prefix ("gnomelinto-")
                        && name.has_suffix (".log")
                        && (best == null || name > best)) {
                        best = name;
                    }
                }
            } catch (Error e) {
            }
            return (best != null)
                ? Path.build_filename (this.directory, best)
                : null;
        }

        // Writes a single line. The caller must hold the mutex.
        private void write_line (string category, string message) {
            if (this.stream == null) {
                return;
            }
            var now = new DateTime.now_local ();
            this.stream.printf ("%s [%s] %s\n",
                now.format ("%Y-%m-%d %H:%M:%S"), category, message);
            this.stream.flush ();
        }
    }
}
