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
    public class Application : Adw.Application {
        public Application () {
            Object (
                application_id: Config.APP_ID,
                flags: ApplicationFlags.DEFAULT_FLAGS
            );
        }

        construct {
            ActionEntry[] action_entries = {
                { "preferences", this.on_preferences_action },
                { "about", this.on_about_action },
                { "quit", this.on_quit_action },
            };
            this.add_action_entries (action_entries, this);
            this.set_accels_for_action ("app.preferences", { "<primary>comma" });
            this.set_accels_for_action ("app.quit", { "<primary>q" });
        }

        public override void activate () {
            base.activate ();
            var window = this.active_window;
            if (window == null) {
                window = new Linto.Window (this);
            }
            window.present ();
        }

        private void on_quit_action () {
            this.quit ();
        }

        private void on_preferences_action () {
            var preferences = new Linto.Preferences ();
            preferences.present (this.active_window);
        }

        private void on_about_action () {
            var about = new Adw.AboutDialog () {
                application_name = "LinTO",
                application_icon = Config.APP_ID,
                developer_name = "Benjamin Bellamy",
                version = Config.VERSION,
                website = "https://github.com/benjaminbellamy/gnome-linto",
                issue_url = "https://github.com/benjaminbellamy/gnome-linto/issues",
                license_type = Gtk.License.AGPL_3_0,
                copyright = "Copyright © 2026 Benjamin Bellamy"
            };
            about.present (this.active_window);
        }
    }
}
