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
    // A resizable window showing a transcription URL as a QR code. The code is
    // drawn with integer-sized modules so it stays crisp at any window size, on
    // a white background (independent of the theme) so it always scans.
    [GtkTemplate (ui = "/ai/linto/gnomelinto/ui/qr-dialog.ui")]
    public class QrDialog : Adw.Window {
        [GtkChild] private unowned Gtk.DrawingArea area;
        [GtkChild] private unowned Gtk.Label url_label;

        // Modules of quiet zone around the code, as required by the standard.
        private const int QUIET = 4;

        private QrCode qr;

        public QrDialog (Gtk.Window parent, QrCode qr, string url) {
            Object (transient_for: parent);
            this.qr = qr;
            this.url_label.label = url;
            this.area.set_draw_func (this.draw);
        }

        private void draw (Gtk.DrawingArea a, Cairo.Context cr,
            int width, int height) {
            int modules = this.qr.size;
            int cells = modules + 2 * QUIET;
            int cell = (int) (double.min (width, height) / cells);
            if (cell < 1) {
                cell = 1;
            }
            int side = cell * cells;
            int ox = (width - side) / 2;
            int oy = (height - side) / 2;

            cr.set_source_rgb (1.0, 1.0, 1.0);
            cr.rectangle (ox, oy, side, side);
            cr.fill ();

            cr.set_source_rgb (0.0, 0.0, 0.0);
            for (int y = 0; y < modules; y++) {
                for (int x = 0; x < modules; x++) {
                    if (this.qr.get_module (x, y)) {
                        cr.rectangle (ox + (QUIET + x) * cell,
                            oy + (QUIET + y) * cell, cell, cell);
                    }
                }
            }
            cr.fill ();
        }
    }
}
