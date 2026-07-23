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

void test_looks_like_https () {
    assert (Linto.Csv.looks_like_https ("https://studio.linto.ai/t/abc"));
    assert (Linto.Csv.looks_like_https ("  http://example.org  "));
    assert (!Linto.Csv.looks_like_https ("srt://studio.linto.ai:8889?x"));
    assert (!Linto.Csv.looks_like_https ("rtmp://host/app/key"));
    assert (!Linto.Csv.looks_like_https ("just a label"));
}

Linto.CsvRow row (string a, string b, string c) {
    return new Linto.CsvRow ({ a, b, c });
}

void test_detect_three_columns () {
    Linto.CsvRow[] rows = {
        row ("Name", "Stream", "Transcription"),
        row ("Room A", "srt://studio.linto.ai:8889?streamid=a,0&mode=caller",
            "https://studio.linto.ai/t/a"),
        row ("Room B", "srt://studio.linto.ai:8889?streamid=b,0&mode=caller",
            "https://studio.linto.ai/t/b")
    };
    int label_col, address_col, transcription_col;
    Linto.Csv.detect_columns (rows, out label_col, out address_col,
        out transcription_col);
    assert (address_col == 1);
    assert (transcription_col == 2);
    assert (label_col == 0);
}

void test_no_transcription_column () {
    Linto.CsvRow[] rows = {
        row ("Room A", "srt://h:8889?streamid=a,0&mode=caller", "note"),
        row ("Room B", "srt://h:8889?streamid=b,0&mode=caller", "note")
    };
    int label_col, address_col, transcription_col;
    Linto.Csv.detect_columns (rows, out label_col, out address_col,
        out transcription_col);
    assert (address_col == 1);
    assert (transcription_col == -1);   // optional, none detected
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/csv/looks-like-https", test_looks_like_https);
    Test.add_func ("/csv/detect-three-columns", test_detect_three_columns);
    Test.add_func ("/csv/no-transcription-column", test_no_transcription_column);
    return Test.run ();
}
