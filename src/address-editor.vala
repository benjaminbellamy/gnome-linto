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
        private unowned Adw.EntryRow transcription_url_row;
        [GtkChild]
        private unowned Gtk.Button paste_button;
        [GtkChild]
        private unowned Gtk.Button transcription_paste_button;
        [GtkChild]
        private unowned Adw.ToastOverlay toast_overlay;

        public signal void saved (string label, string url,
            string transcription_url);

        // The clipboard is watched so each paste button reflects, at any moment,
        // whether the clipboard holds a value valid for its field. These hold
        // the last valid candidate (null when the clipboard is empty or does not
        // match).
        private Gdk.Clipboard? clipboard = null;
        private ulong clipboard_handler = 0;
        private string? clipboard_candidate = null;
        private string? transcription_candidate = null;

        public AddressEditor (string title, string label, string url,
            string transcription_url) {
            Object ();
            this.title = title;
            this.label_row.text = label;
            this.url_row.text = url;
            this.transcription_url_row.text = transcription_url;

            var display = Gdk.Display.get_default ();
            if (display != null) {
                this.clipboard = display.get_clipboard ();
                this.clipboard_handler =
                    this.clipboard.changed.connect (this.refresh_paste_button);
                this.refresh_paste_button ();
            } else {
                this.paste_button.sensitive = false;
                this.transcription_paste_button.sensitive = false;
            }

            // The clipboard outlives this dialog, so drop the handler on close
            // to avoid keeping the dialog alive for the whole session.
            this.closed.connect (() => {
                if (this.clipboard != null && this.clipboard_handler != 0) {
                    this.clipboard.disconnect (this.clipboard_handler);
                    this.clipboard_handler = 0;
                }
            });
        }

        // Reads the clipboard text asynchronously and updates the paste button.
        private void refresh_paste_button () {
            if (this.clipboard == null) {
                return;
            }
            this.clipboard.read_text_async.begin (null, (obj, res) => {
                string? text = null;
                try {
                    text = this.clipboard.read_text_async.end (res);
                } catch (Error e) {
                    text = null;
                }
                this.apply_clipboard_state (text);
            });
        }

        // Returns null when the value is valid for its field, else the reason.
        private delegate string? Validator (string value);

        // Enables each paste button only when the clipboard holds a value valid
        // for its field, and otherwise explains in the tooltip why it cannot be
        // pasted.
        private void apply_clipboard_state (string? text) {
            string trimmed = (text ?? "").strip ();
            this.clipboard_candidate = this.paste_state (this.paste_button,
                trimmed, StreamUrl.validate,
                _("Paste the address from the clipboard"));
            this.transcription_candidate = this.paste_state (
                this.transcription_paste_button, trimmed, transcription_error,
                _("Paste the transcription URL from the clipboard"));
        }

        // Sets a paste button's sensitivity and tooltip for the clipboard text,
        // and returns the value to paste (null when it cannot be pasted).
        private string? paste_state (Gtk.Button button, string trimmed,
            Validator validate, string ok_tooltip) {
            if (trimmed == "") {
                button.sensitive = false;
                button.tooltip_text = _("The clipboard has no text to paste.");
                return null;
            }
            string? error = validate (trimmed);
            if (error != null) {
                button.sensitive = false;
                button.tooltip_text = error;
                return null;
            }
            button.sensitive = true;
            button.tooltip_text = ok_tooltip;
            return trimmed;
        }

        // Null when the value is an acceptable (optional) transcription URL,
        // else the reason. The one definition of the field's validity.
        private static string? transcription_error (string value) {
            return StreamUrl.is_web_url (value)
                ? null
                : _("The transcription URL must start with http:// or "
                    + "https://.");
        }

        [GtkCallback]
        private void on_paste () {
            // Reset the field and paste the clipboard address. The button is
            // only enabled when the clipboard holds a valid one.
            if (this.clipboard_candidate != null) {
                this.url_row.text = this.clipboard_candidate;
            }
        }

        [GtkCallback]
        private void on_paste_transcription () {
            // The button is only enabled when the clipboard holds a web URL.
            if (this.transcription_candidate != null) {
                this.transcription_url_row.text = this.transcription_candidate;
            }
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
            // The transcription URL is optional; when set it must be a web URL.
            string transcription = this.transcription_url_row.text.strip ();
            string? transcription_err = transcription_error (transcription);
            if (transcription != "" && transcription_err != null) {
                this.toast_overlay.add_toast (
                    new Adw.Toast (transcription_err));
                return;
            }
            this.saved (this.label_row.text.strip (), url, transcription);
            this.close ();
        }
    }
}
