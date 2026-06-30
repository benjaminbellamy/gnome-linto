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
    [GtkTemplate (ui = "/ai/linto/gnomelinto/ui/preferences.ui")]
    public class Preferences : Adw.Dialog {
        [GtkChild]
        private unowned Adw.EntryRow url_row;

        private GLib.Settings settings;

        public Preferences () {
            Object ();
        }

        construct {
            this.settings = new GLib.Settings (Config.APP_ID);
            // Edit a copy; only OK writes it back.
            this.url_row.text = this.settings.get_string ("srt-url");
        }

        [GtkCallback]
        private void on_cancel () {
            this.close ();
        }

        [GtkCallback]
        private void on_save () {
            this.settings.set_string ("srt-url", this.url_row.text.strip ());
            this.close ();
        }
    }
}
