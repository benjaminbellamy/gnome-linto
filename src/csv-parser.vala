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
    // One parsed CSV line, as its list of fields. A small class because Vala
    // has no jagged "string[][]" array type.
    public class CsvRow {
        public string[] fields;

        public CsvRow (owned string[] fields) {
            this.fields = fields;
        }

        public int length {
            get { return this.fields.length; }
        }

        // The field at index i, or an empty string when out of range.
        public string get (int i) {
            return (i >= 0 && i < this.fields.length) ? this.fields[i] : "";
        }
    }

    // A small RFC 4180 style CSV reader, plus helpers to guess which columns
    // hold the label and the stream address. Kept free of UI so it can be
    // reasoned about (and tested) on its own.
    namespace Csv {
        // Parses CSV text into rows of string fields. Quoted fields (which may
        // contain the delimiter or newlines, with "" for a literal quote) are
        // honored, and the delimiter is guessed from the first line. Blank
        // lines are dropped.
        public CsvRow[] parse (string content) {
            char delim = detect_delimiter (content);
            CsvRow[] rows = {};
            string[] row = {};
            var field = new StringBuilder ();
            bool in_quotes = false;
            bool row_started = false;
            int len = content.length;

            for (int i = 0; i < len; i++) {
                char c = content[i];
                if (in_quotes) {
                    if (c == '"') {
                        if (i + 1 < len && content[i + 1] == '"') {
                            field.append_c ('"');
                            i++;
                        } else {
                            in_quotes = false;
                        }
                    } else {
                        field.append_c (c);
                    }
                    continue;
                }

                if (c == '"') {
                    in_quotes = true;
                    row_started = true;
                } else if (c == delim) {
                    row += field.str;
                    field.truncate ();
                    row_started = true;
                } else if (c == '\n' || c == '\r') {
                    if (c == '\r' && i + 1 < len && content[i + 1] == '\n') {
                        i++;
                    }
                    // Commit the line, ignoring a completely blank one.
                    if (row_started || field.len > 0 || row.length > 0) {
                        row += field.str;
                        rows += new CsvRow ((owned) row);
                    }
                    row = {};
                    field.truncate ();
                    row_started = false;
                } else {
                    field.append_c (c);
                    row_started = true;
                }
            }

            // A final line with no trailing newline.
            if (row_started || field.len > 0 || row.length > 0) {
                row += field.str;
                rows += new CsvRow ((owned) row);
            }
            return rows;
        }

        // Guesses the field separator from the first line: comma, semicolon or
        // tab, whichever occurs most (comma wins ties).
        private char detect_delimiter (string content) {
            int nl = content.index_of_char ('\n');
            string first = (nl >= 0) ? content.substring (0, nl) : content;
            int commas = count_char (first, ',');
            int semis = count_char (first, ';');
            int tabs = count_char (first, '\t');
            if (semis > commas && semis >= tabs) {
                return ';';
            }
            if (tabs > commas && tabs > semis) {
                return '\t';
            }
            return ',';
        }

        private int count_char (string s, char c) {
            int n = 0;
            for (int i = 0; i < s.length; i++) {
                if (s[i] == c) {
                    n++;
                }
            }
            return n;
        }

        // True when the value looks like a stream address we can import (SRT or
        // RTMP/RTMPS), reusing the app's own protocol detection.
        public bool looks_like_address (string value) {
            var p = StreamUrl.protocol (value);
            return p == StreamProtocol.SRT || p == StreamProtocol.RTMP;
        }

        // True when the first row looks like a header: it has fields and none
        // of them contains "://", so no cell is an address or a URL.
        public bool has_header (CsvRow[] rows) {
            if (rows.length == 0 || rows[0].length == 0) {
                return false;
            }
            foreach (var v in rows[0].fields) {
                if (v.contains ("://")) {
                    return false;
                }
            }
            return true;
        }

        // True when any cell anywhere looks like an SRT/RTMP address, so the
        // file has something worth importing.
        public bool has_any_address (CsvRow[] rows) {
            foreach (var r in rows) {
                foreach (var v in r.fields) {
                    if (looks_like_address (v)) {
                        return true;
                    }
                }
            }
            return false;
        }

        // Guesses which column holds the address (the one with the most values
        // that look like an SRT/RTMP address) and which holds the label (the
        // non-address column with the most plain, non-URL values). Falls back
        // to sensible defaults so a selection is always offered.
        public void detect_columns (CsvRow[] rows,
                                    out int label_col, out int address_col) {
            int cols = 0;
            foreach (var r in rows) {
                if (r.length > cols) {
                    cols = r.length;
                }
            }

            address_col = -1;
            int best_addr = 0;
            for (int c = 0; c < cols; c++) {
                int hits = 0;
                foreach (var r in rows) {
                    if (c < r.length && looks_like_address (r.get (c))) {
                        hits++;
                    }
                }
                if (hits > best_addr) {
                    best_addr = hits;
                    address_col = c;
                }
            }

            label_col = -1;
            int best_label = -1;
            for (int c = 0; c < cols; c++) {
                if (c == address_col) {
                    continue;
                }
                int good = 0;
                foreach (var r in rows) {
                    if (c < r.length) {
                        string v = r.get (c).strip ();
                        if (v != "" && !v.contains ("://")) {
                            good++;
                        }
                    }
                }
                if (good > best_label) {
                    best_label = good;
                    label_col = c;
                }
            }

            if (address_col < 0) {
                address_col = (cols > 0) ? cols - 1 : 0;
            }
            if (label_col < 0) {
                label_col = (address_col == 0 && cols > 1) ? 1 : 0;
            }
        }
    }
}
