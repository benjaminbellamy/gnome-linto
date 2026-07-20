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

private void test_srt_valid () {
    assert (Linto.StreamUrl.validate (
        "srt://studio.linto.ai:8889?streamid=8d30ef9d-394e,0&mode=caller")
        == null);
    assert (Linto.StreamUrl.protocol ("srt://h:1") == Linto.StreamProtocol.SRT);
}

private void test_rtmp_valid () {
    assert (Linto.StreamUrl.validate (
        "rtmp://studio.linto.ai:1935/8d30ef9d-394e-4725/0") == null);
    assert (Linto.StreamUrl.protocol ("rtmp://h/a/b")
        == Linto.StreamProtocol.RTMP);
    assert (Linto.StreamUrl.protocol ("rtmps://h/a/b")
        == Linto.StreamProtocol.RTMP);
}

private void test_websocket_rejected_for_now () {
    // Recognized as a protocol but not yet a supported output.
    assert (Linto.StreamUrl.protocol ("wss://h/x")
        == Linto.StreamProtocol.WEBSOCKET);
    assert (Linto.StreamUrl.validate ("wss://studio.linto.ai:443/x") != null);
}

private void test_empty_and_unknown () {
    assert (Linto.StreamUrl.validate ("   ") != null);
    assert (Linto.StreamUrl.validate ("https://studio.linto.ai:443") != null);
}

private void test_srt_missing_port () {
    assert (Linto.StreamUrl.validate ("srt://studio.linto.ai") != null);
}

private void test_has_query_param () {
    // Present, absent, and case-insensitive key match.
    assert (Linto.StreamUrl.has_query_param (
        "srt://h:1?streamid=x,0&mode=caller&latency=1500", "latency"));
    assert (!Linto.StreamUrl.has_query_param (
        "srt://h:1?streamid=x,0&mode=caller", "latency"));
    assert (Linto.StreamUrl.has_query_param (
        "srt://h:1?streamid=x,0&LATENCY=800", "latency"));
    // No query string at all.
    assert (!Linto.StreamUrl.has_query_param ("srt://h:1", "latency"));
}

public int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/stream-url/srt-valid", test_srt_valid);
    Test.add_func ("/stream-url/rtmp-valid", test_rtmp_valid);
    Test.add_func ("/stream-url/websocket-rejected", test_websocket_rejected_for_now);
    Test.add_func ("/stream-url/empty-and-unknown", test_empty_and_unknown);
    Test.add_func ("/stream-url/srt-missing-port", test_srt_missing_port);
    Test.add_func ("/stream-url/has-query-param", test_has_query_param);
    return Test.run ();
}
