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
    // Lets the user map the columns of a parsed CSV file to a label and an
    // address, previewing the first rows, then imports the matching rows into
    // the address book. Columns are guessed on open; the rest are ignored.
    [GtkTemplate (ui = "/ai/linto/gnomelinto/ui/csv-import.ui")]
    public class CsvImport : Adw.Dialog {
        // The number of leading file rows shown in the preview (including the
        // title row when there is one).
        private const int PREVIEW_ROWS = 4;
        // The longest sample text shown in a combo entry or a preview cell.
        private const int SAMPLE_CHARS = 30;

        [GtkChild]
        private unowned Adw.ComboRow label_combo;
        [GtkChild]
        private unowned Adw.ComboRow address_combo;
        [GtkChild]
        private unowned Gtk.ScrolledWindow preview_scroller;
        [GtkChild]
        private unowned Gtk.Label preview_count;
        [GtkChild]
        private unowned Adw.ToastOverlay toast_overlay;

        private GLib.Settings settings;
        private CsvRow[] rows;
        // Whether the first row is a header (its names label the columns) as
        // opposed to data. When true the header row is not counted or imported.
        private bool has_header;

        // Emitted after a successful import: how many new addresses were added,
        // and how many importable rows the file held.
        public signal void imported (int added, int total);

        public CsvImport (GLib.Settings settings, owned CsvRow[] rows) {
            Object ();
            this.settings = settings;
            this.rows = rows;
            this.has_header = Csv.has_header (this.rows);
            this.build_combos ();
            this.build_preview ();

            int data_rows = this.rows.length - (this.has_header ? 1 : 0);
            this.preview_count.label = _("%d rows").printf (int.max (data_rows, 0));
        }

        private int column_count () {
            int cols = 0;
            foreach (var r in this.rows) {
                if (r.length > cols) {
                    cols = r.length;
                }
            }
            return cols;
        }

        private void build_combos () {
            int cols = this.column_count ();

            // Each combo needs its own model so selecting one does not move the
            // other.
            var label_model = new Gtk.StringList (null);
            var address_model = new Gtk.StringList (null);
            for (int c = 0; c < cols; c++) {
                string title = this.column_title (c);
                label_model.append (title);
                address_model.append (title);
            }
            this.label_combo.model = label_model;
            this.address_combo.model = address_model;

            int label_col, address_col;
            Csv.detect_columns (this.rows, out label_col, out address_col);
            if (label_col >= 0 && label_col < cols) {
                this.label_combo.selected = label_col;
            }
            if (address_col >= 0 && address_col < cols) {
                this.address_combo.selected = address_col;
            }
        }

        // A combo entry for a column. With a header row, the header name is
        // used directly (clearer than "Column 1"). Otherwise the column is
        // numbered, with the first value as a hint so columns can be told
        // apart.
        private string column_title (int c) {
            if (this.has_header) {
                string h = this.rows[0].get (c).strip ();
                if (h != "") {
                    return this.truncate (h, SAMPLE_CHARS);
                }
            }
            string sample = "";
            int start = this.has_header ? 1 : 0;
            for (int i = start; i < this.rows.length; i++) {
                string v = this.rows[i].get (c).strip ();
                if (v != "") {
                    sample = v;
                    break;
                }
            }
            if (sample == "") {
                return _("Column %d").printf (c + 1);
            }
            return _("Column %d (%s)").printf (
                c + 1, this.truncate (sample, SAMPLE_CHARS));
        }

        private void build_preview () {
            int cols = this.column_count ();

            var grid = new Gtk.Grid () {
                column_spacing = 18,
                row_spacing = 6,
                margin_top = 12,
                margin_bottom = 12,
                margin_start = 12,
                margin_end = 12
            };

            int grid_row = 0;

            // With no header row, add a synthetic one numbering the columns so
            // they can still be told apart. With a header, the file's own first
            // row (shown below) serves that purpose.
            if (!this.has_header) {
                for (int c = 0; c < cols; c++) {
                    var head = new Gtk.Label (_("Column %d").printf (c + 1)) {
                        halign = Gtk.Align.START,
                        xalign = 0
                    };
                    head.add_css_class ("heading");
                    grid.attach (head, c, grid_row, 1, 1);
                }
                grid_row++;
            }

            int shown = int.min (this.rows.length, PREVIEW_ROWS);
            for (int r = 0; r < shown; r++) {
                for (int c = 0; c < cols; c++) {
                    var cell = new Gtk.Label (
                        this.truncate (this.rows[r].get (c), SAMPLE_CHARS)) {
                        halign = Gtk.Align.START,
                        xalign = 0
                    };
                    if (this.has_header && r == 0) {
                        cell.add_css_class ("heading");
                    } else {
                        cell.add_css_class ("dim-label");
                    }
                    grid.attach (cell, c, grid_row, 1, 1);
                }
                grid_row++;
            }

            this.preview_scroller.child = grid;
        }

        // Truncates to at most max characters (not bytes), adding an ellipsis,
        // so multi-byte text is never split mid-character.
        private string truncate (string s, int max) {
            if (s.char_count () <= max) {
                return s;
            }
            var sb = new StringBuilder ();
            int index = 0;
            int taken = 0;
            unichar ch = 0;
            while (taken < max && s.get_next_char (ref index, out ch)) {
                sb.append_unichar (ch);
                taken++;
            }
            sb.append ("…");
            return sb.str;
        }

        [GtkCallback]
        private void on_import () {
            int cols = this.column_count ();
            int label_col = (int) this.label_combo.selected;
            int address_col = (int) this.address_combo.selected;

            if (address_col < 0 || address_col >= cols) {
                this.toast (_("Pick the column that holds the address."));
                return;
            }
            if (label_col == address_col) {
                this.toast (
                    _("The label and address columns must be different."));
                return;
            }

            Address[] incoming = {};
            foreach (var r in this.rows) {
                string url = r.get (address_col).strip ();
                if (!Csv.looks_like_address (url)) {
                    continue;
                }
                string label = r.get (label_col).strip ();
                incoming += Address () { label = label, url = url };
            }

            if (incoming.length == 0) {
                this.toast (_("No SRT or RTMP address found in that column."));
                return;
            }

            int added = AddressBook.import_addresses (this.settings, incoming);
            this.imported (added, incoming.length);
            this.close ();
        }

        [GtkCallback]
        private void on_cancel () {
            this.close ();
        }

        private void toast (string message) {
            this.toast_overlay.add_toast (new Adw.Toast (message));
        }
    }
}
