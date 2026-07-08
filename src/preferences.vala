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
    // Manages the list of saved stream addresses: add, edit, remove, and pick
    // the active one. Changes are applied to GSettings immediately; the active
    // URL is mirrored to srt-url, which the rest of the app reads.
    [GtkTemplate (ui = "/ai/linto/gnomelinto/ui/preferences.ui")]
    public class Preferences : Adw.Dialog {
        [GtkChild]
        private unowned Adw.PreferencesGroup addresses_group;

        private GLib.Settings settings;
        // The main window, used to detect an active stream and hand off a live
        // address switch (confirm, then stop-and-restart). Null when opened
        // without a window. A construct property so it is set before construct
        // runs the first rebuild, which needs it to disable the active row.
        public Window? window { private get; construct; }
        // The rows we added, so they can be cleared before a rebuild.
        private GenericArray<Gtk.Widget> rows = new GenericArray<Gtk.Widget> ();
        private Gtk.CheckButton? radio_group = null;
        // Set while (re)building rows, so programmatic radio toggles do not
        // change the selection.
        private bool building = false;

        public Preferences (Window? window) {
            Object (window: window);
        }

        construct {
            this.settings = new GLib.Settings (Config.APP_ID);
            this.rebuild ();
            // Rebuild after our own writes settle, off the current signal, so a
            // row is never torn down from inside its own handler.
            this.settings.changed["addresses"].connect (() => {
                Idle.add (() => {
                    this.rebuild ();
                    return Source.REMOVE;
                });
            });
        }

        [GtkCallback]
        private void on_add () {
            var editor = new AddressEditor (_("Add address"), "", "");
            editor.saved.connect ((label, url) => {
                Address[] list = AddressBook.load (this.settings);
                list += Address () { label = label, url = url };
                AddressBook.save (this.settings, list);
                // The first address added becomes the active one.
                if (AddressBook.selected_url (this.settings) == "") {
                    AddressBook.select (this.settings, url);
                }
            });
            editor.present (this);
        }

        private void edit_entry (int index) {
            Address[] entries = AddressBook.load (this.settings);
            if (index < 0 || index >= entries.length) {
                return;
            }
            Address current = entries[index];
            // Never edit the address that is streaming right now (the row's
            // edit button is disabled too; this guards other callers).
            if (this.window != null
                && this.window.is_active_stream (current.url)) {
                return;
            }
            var editor = new AddressEditor (_("Edit address"),
                current.label, current.url);
            editor.saved.connect ((label, url) => {
                Address[] list = AddressBook.load (this.settings);
                if (index >= list.length) {
                    return;
                }
                string old_url = list[index].url;
                list[index] = Address () { label = label, url = url };
                AddressBook.save (this.settings, list);
                // Keep the selection on this entry if it was the active one.
                if (AddressBook.selected_url (this.settings) == old_url) {
                    AddressBook.select (this.settings, url);
                }
            });
            editor.present (this);
        }

        private void remove_entry (int index) {
            Address[] list = AddressBook.load (this.settings);
            if (index < 0 || index >= list.length) {
                return;
            }
            string removed_url = list[index].url;
            // Never remove the address that is streaming right now (the row's
            // remove button is disabled too; this guards other callers).
            if (this.window != null
                && this.window.is_active_stream (removed_url)) {
                return;
            }
            Address[] next = {};
            for (int i = 0; i < list.length; i++) {
                if (i != index) {
                    next += list[i];
                }
            }
            AddressBook.save (this.settings, next);
            // If the active address was removed, fall back to the first left.
            if (AddressBook.selected_url (this.settings) == removed_url) {
                AddressBook.select (this.settings,
                    next.length > 0 ? next[0].url : "");
            }
        }

        // Closes the dialog once an address is picked, off the current signal
        // so the row is not torn down from inside its own toggled handler.
        private void close_after_select () {
            Idle.add (() => {
                this.close ();
                return Source.REMOVE;
            });
        }

        // Restores the radios to the persisted selection, used when a live
        // switch is cancelled so the list stops showing the address the user
        // backed out of.
        public void reset_selection () {
            this.rebuild ();
        }

        private void clear_rows () {
            foreach (var row in this.rows.data) {
                this.addresses_group.remove (row);
            }
            this.rows = new GenericArray<Gtk.Widget> ();
            this.radio_group = null;
        }

        private void rebuild () {
            this.building = true;
            this.clear_rows ();

            Address[] entries = AddressBook.load (this.settings);
            string active = AddressBook.selected_url (this.settings);

            if (entries.length == 0) {
                var empty = new Adw.ActionRow () {
                    title = _("No address yet"),
                    subtitle = _("Use the + button to add a stream address")
                };
                this.addresses_group.add (empty);
                this.rows.add (empty);
                this.building = false;
                return;
            }

            for (int i = 0; i < entries.length; i++) {
                Address entry = entries[i];
                int index = i;
                string url = entry.url;

                // Escape the text: AdwActionRow parses its title and subtitle as
                // Pango markup, and SRT URLs contain "&" (for example
                // "&mode=caller"), which would otherwise break rendering.
                var row = new Adw.ActionRow () {
                    title = Markup.escape_text (
                        entry.label != "" ? entry.label : entry.url),
                    subtitle = Markup.escape_text (entry.url)
                };

                var radio = new Gtk.CheckButton () {
                    valign = Gtk.Align.CENTER
                };
                if (this.radio_group == null) {
                    this.radio_group = radio;
                } else {
                    radio.set_group (this.radio_group);
                }
                radio.active = (entry.url == active);
                radio.toggled.connect (() => {
                    if (this.building || !radio.active) {
                        return;
                    }
                    // While streaming, picking a different address is a live
                    // switch: let the window confirm and restart, and do not
                    // commit the selection here (it commits on confirm, or the
                    // radios roll back on cancel).
                    if (this.window != null && this.window.is_streaming ()
                        && url != AddressBook.selected_url (this.settings)) {
                        // The window closes this dialog on confirm, or rolls the
                        // selection back on cancel.
                        this.window.request_switch (url, this);
                    } else {
                        AddressBook.select (this.settings, url);
                        this.close_after_select ();
                    }
                });
                row.add_prefix (radio);
                row.activatable_widget = radio;

                var edit = new Gtk.Button.from_icon_name (
                    "document-edit-symbolic") {
                    valign = Gtk.Align.CENTER,
                    tooltip_text = _("Edit")
                };
                edit.add_css_class ("flat");
                edit.clicked.connect (() => {
                    this.edit_entry (index);
                });
                // The address that is streaming right now cannot be edited;
                // pause or switch first.
                if (this.window != null
                    && this.window.is_active_stream (entry.url)) {
                    edit.sensitive = false;
                    edit.tooltip_text = _("Stop streaming to edit this address");
                }
                row.add_suffix (edit);

                var remove = new Gtk.Button.from_icon_name (
                    "user-trash-symbolic") {
                    valign = Gtk.Align.CENTER,
                    tooltip_text = _("Remove")
                };
                remove.add_css_class ("flat");
                remove.clicked.connect (() => {
                    this.remove_entry (index);
                });
                // The address that is streaming right now cannot be removed;
                // pause or switch first.
                if (this.window != null
                    && this.window.is_active_stream (entry.url)) {
                    remove.sensitive = false;
                    remove.tooltip_text =
                        _("Stop streaming to remove this address");
                }
                row.add_suffix (remove);

                this.addresses_group.add (row);
                this.rows.add (row);
            }

            this.building = false;
        }
    }
}
