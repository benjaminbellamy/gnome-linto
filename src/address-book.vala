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
    // A saved stream address: a human-readable label, its URL, and an optional
    // public transcription URL (empty when none).
    public struct Address {
        public string label;
        public string url;
        public string transcription_url;
    }

    // Stores the list of saved addresses in the "addresses" GSettings key and
    // mirrors the selected one to "srt-url", which the rest of the app reads.
    namespace AddressBook {
        public Address[] load (GLib.Settings settings) {
            Address[] result = {};
            // Optional transcription URLs live in a separate key (so the
            // addresses key never has to change type on upgrade); join them onto
            // each address by stream URL.
            var transcription = transcription_map (settings);
            Variant arr = settings.get_value ("addresses");
            VariantIter it = arr.iterator ();
            string label;
            string url;
            while (it.next ("(ss)", out label, out url)) {
                string? t = transcription.lookup (url);
                result += Address () {
                    label = label, url = url, transcription_url = t ?? ""
                };
            }
            // Migrate a single URL saved before the address list existed, so an
            // upgrade keeps the address the user had configured. Do this only
            // once, while the addresses key has never been written: an empty
            // list the user created by deleting every address must not
            // resurrect a deleted address from srt-url.
            if (result.length == 0 && settings.get_user_value ("addresses") == null) {
                string legacy = settings.get_string ("srt-url").strip ();
                if (legacy != "") {
                    result += Address () {
                        label = _("Default"), url = legacy, transcription_url = ""
                    };
                    save (settings, result);
                }
            }
            return result;
        }

        // The stored (stream URL -> transcription URL) map.
        private HashTable<string, string> transcription_map (
            GLib.Settings settings) {
            var map = new HashTable<string, string> (str_hash, str_equal);
            Variant arr = settings.get_value ("transcription-urls");
            VariantIter it = arr.iterator ();
            string url;
            string transcription;
            while (it.next ("(ss)", out url, out transcription)) {
                map.insert (url, transcription);
            }
            return map;
        }

        public void save (GLib.Settings settings, Address[] entries) {
            var builder = new VariantBuilder (new VariantType ("a(ss)"));
            var transcription =
                new VariantBuilder (new VariantType ("a(ss)"));
            foreach (var e in entries) {
                builder.add ("(ss)", e.label, e.url);
                if (e.transcription_url != "") {
                    transcription.add ("(ss)", e.url, e.transcription_url);
                }
            }
            settings.set_value ("addresses", builder.end ());
            settings.set_value ("transcription-urls", transcription.end ());
        }

        // The currently selected URL (mirrored to srt-url).
        public string selected_url (GLib.Settings settings) {
            return settings.get_string ("srt-url").strip ();
        }

        public void select (GLib.Settings settings, string url) {
            settings.set_string ("srt-url", url.strip ());
        }

        // Merges imported addresses into the saved list and returns how many
        // new entries were added. Rules: an address already present (same URL)
        // is skipped, whatever its label, so an identical label/address couple
        // is skipped too. A new address whose label is already taken gets a
        // unique label with an incremental " (2)", " (3)"... suffix. Within one
        // import the growing list is checked, so duplicates inside the file are
        // deduplicated the same way.
        public int import_addresses (GLib.Settings settings, Address[] incoming) {
            Address[] list = load (settings);
            bool was_empty = (list.length == 0);
            var urls = new GenericSet<string> (str_hash, str_equal);
            var labels = new GenericSet<string> (str_hash, str_equal);
            foreach (var e in list) {
                urls.add (e.url);
                labels.add (e.label);
            }

            int added = 0;
            foreach (var inc in incoming) {
                string url = inc.url.strip ();
                if (url == "" || urls.contains (url)) {
                    continue;
                }
                string label = unique_label (labels, inc.label.strip ());
                list += Address () {
                    label = label,
                    url = url,
                    transcription_url = inc.transcription_url.strip ()
                };
                urls.add (url);
                labels.add (label);
                added++;
            }

            if (added > 0) {
                save (settings, list);
                // If the list was empty, the first imported address becomes the
                // active one, matching the behavior of adding the first address.
                if (was_empty && selected_url (settings) == "") {
                    select (settings, list[0].url);
                }
            }
            return added;
        }

        // Returns the label unchanged when it is free, otherwise the first
        // "label (n)" (n starting at 2) that is not already taken.
        private string unique_label (GenericSet<string> taken, string label) {
            if (label == "" || !taken.contains (label)) {
                return label;
            }
            int n = 2;
            string candidate = "%s (%d)".printf (label, n);
            while (taken.contains (candidate)) {
                n++;
                candidate = "%s (%d)".printf (label, n);
            }
            return candidate;
        }

        // The label to show for a saved URL: its label, or the URL itself when
        // the label is empty, or an empty string for an empty URL.
        public string label_for (GLib.Settings settings, string url) {
            if (url == "") {
                return "";
            }
            foreach (var e in load (settings)) {
                if (e.url == url) {
                    return e.label != "" ? e.label : e.url;
                }
            }
            return url;
        }

        // The label to show for the active address: its label, or the URL when
        // the label is empty, or an empty string when nothing is selected.
        public string active_label (GLib.Settings settings) {
            return label_for (settings, selected_url (settings));
        }

        // The public transcription URL saved for a stream URL, or "" when none.
        public string transcription_url_for (GLib.Settings settings,
            string url) {
            if (url == "") {
                return "";
            }
            string? t = transcription_map (settings).lookup (url);
            return t ?? "";
        }

        // The public transcription URL of the active address, or "" when none.
        public string active_transcription_url (GLib.Settings settings) {
            return transcription_url_for (settings, selected_url (settings));
        }
    }
}
