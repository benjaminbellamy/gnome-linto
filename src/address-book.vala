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
    // A saved stream address: a human-readable label and its URL.
    public struct Address {
        public string label;
        public string url;
    }

    // Stores the list of saved addresses in the "addresses" GSettings key and
    // mirrors the selected one to "srt-url", which the rest of the app reads.
    namespace AddressBook {
        public Address[] load (GLib.Settings settings) {
            Address[] result = {};
            Variant arr = settings.get_value ("addresses");
            VariantIter it = arr.iterator ();
            string label;
            string url;
            while (it.next ("(ss)", out label, out url)) {
                result += Address () { label = label, url = url };
            }
            // Migrate a single URL saved before the address list existed, so an
            // upgrade keeps the address the user had configured.
            if (result.length == 0) {
                string legacy = settings.get_string ("srt-url").strip ();
                if (legacy != "") {
                    result += Address () { label = _("Default"), url = legacy };
                    save (settings, result);
                }
            }
            return result;
        }

        public void save (GLib.Settings settings, Address[] entries) {
            var builder = new VariantBuilder (new VariantType ("a(ss)"));
            foreach (var e in entries) {
                builder.add ("(ss)", e.label, e.url);
            }
            settings.set_value ("addresses", builder.end ());
        }

        // The currently selected URL (mirrored to srt-url).
        public string selected_url (GLib.Settings settings) {
            return settings.get_string ("srt-url").strip ();
        }

        public void select (GLib.Settings settings, string url) {
            settings.set_string ("srt-url", url.strip ());
        }

        // The label to show for the active address: its label, or the URL when
        // the label is empty, or an empty string when nothing is selected.
        public string active_label (GLib.Settings settings) {
            string active = selected_url (settings);
            if (active == "") {
                return "";
            }
            foreach (var e in load (settings)) {
                if (e.url == active) {
                    return e.label != "" ? e.label : e.url;
                }
            }
            return active;
        }
    }
}
