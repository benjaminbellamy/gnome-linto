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
    // A small dialog to add or edit one saved address (label and URL). Emits
    // "saved" with a validated URL; the manager persists it.
    [GtkTemplate (ui = "/ai/linto/gnomelinto/ui/address-editor.ui")]
    public class AddressEditor : Adw.Dialog {
        [GtkChild]
        private unowned Adw.EntryRow label_row;
        [GtkChild]
        private unowned Adw.EntryRow url_row;
        [GtkChild]
        private unowned Adw.ToastOverlay toast_overlay;

        public signal void saved (string label, string url);

        public AddressEditor (string title, string label, string url) {
            Object ();
            this.title = title;
            this.label_row.text = label;
            this.url_row.text = url;
        }

        [GtkCallback]
        private void on_cancel () {
            this.close ();
        }

        [GtkCallback]
        private void on_save () {
            string url = this.url_row.text.strip ();
            string? error = StreamUrl.validate (url);
            if (error != null) {
                this.toast_overlay.add_toast (new Adw.Toast (error));
                return;
            }
            this.saved (this.label_row.text.strip (), url);
            this.close ();
        }
    }
}
