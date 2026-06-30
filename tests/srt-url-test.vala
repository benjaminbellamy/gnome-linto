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

private void test_valid () {
    assert (Linto.SrtUrl.validate (
        "srt://studio.linto.ai:8889?streamid=8d30ef9d-394e,0&mode=caller")
        == null);
}

private void test_empty () {
    assert (Linto.SrtUrl.validate ("   ") != null);
}

private void test_wrong_scheme () {
    assert (Linto.SrtUrl.validate ("https://studio.linto.ai:443") != null);
}

private void test_missing_port () {
    assert (Linto.SrtUrl.validate ("srt://studio.linto.ai") != null);
}

private void test_missing_host () {
    assert (Linto.SrtUrl.validate ("srt://:8889") != null);
}

public int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/srt-url/valid", test_valid);
    Test.add_func ("/srt-url/empty", test_empty);
    Test.add_func ("/srt-url/wrong-scheme", test_wrong_scheme);
    Test.add_func ("/srt-url/missing-port", test_missing_port);
    Test.add_func ("/srt-url/missing-host", test_missing_host);
    return Test.run ();
}
