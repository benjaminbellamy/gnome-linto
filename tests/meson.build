test_c_args = [
  '-DGETTEXT_PACKAGE="@0@"'.format(meson.project_name()),
]

srt_url_test = executable('srt-url-test',
  ['srt-url-test.vala', srt_url_vala],
  dependencies: [gio_dep],
  c_args: test_c_args,
)
test('srt-url', srt_url_test)

level_meter_test = executable('level-meter-test',
  ['level-meter-test.vala', level_meter_vala],
  dependencies: [gio_dep, gst_dep, m_dep],
  c_args: test_c_args,
)
test('level-meter', level_meter_test)
