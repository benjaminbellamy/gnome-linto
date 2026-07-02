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
    [GtkTemplate (ui = "/ai/linto/gnomelinto/ui/debug.ui")]
    public class DebugDialog : Adw.Dialog {
        [GtkChild] private unowned Adw.SwitchRow enable_row;
        [GtkChild] private unowned Adw.ActionRow path_row;
        [GtkChild] private unowned Adw.ToastOverlay toast_overlay;

        private GLib.Settings settings;

        construct {
            this.settings = new GLib.Settings (Config.APP_ID);
            this.settings.bind ("debug-enabled", this.enable_row, "active",
                SettingsBindFlags.DEFAULT);
            this.path_row.subtitle = DebugLog.get_default ().directory;
        }

        [GtkCallback]
        private void on_open_folder () {
            var folder = File.new_for_path (DebugLog.get_default ().directory);
            var launcher = new Gtk.FileLauncher (folder);
            launcher.launch.begin (
                this.get_root () as Gtk.Window, null, (obj, res) => {
                    try {
                        launcher.launch.end (res);
                    } catch (Error e) {
                    }
                });
        }

        [GtkCallback]
        private void on_copy_log () {
            this.get_clipboard ().set_text (
                DebugLog.get_default ().read_contents ());
            this.toast_overlay.add_toast (
                new Adw.Toast (_("Log copied to clipboard")));
        }
    }
}
