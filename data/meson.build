resources = gnome.compile_resources(
  'gnome-linto-resources',
  'ai.linto.gnomelinto.gresource.xml',
  c_name: 'gnome_linto',
)

# Desktop entry
desktop_file = i18n.merge_file(
  input: 'ai.linto.gnomelinto.desktop.in',
  output: 'ai.linto.gnomelinto.desktop',
  type: 'desktop',
  po_dir: '../po',
  install: true,
  install_dir: datadir / 'applications',
)

desktop_utils = find_program('desktop-file-validate', required: false)
if desktop_utils.found()
  test('Validate desktop file', desktop_utils, args: [desktop_file])
endif

# AppStream metainfo
metainfo_file = i18n.merge_file(
  input: 'ai.linto.gnomelinto.metainfo.xml.in',
  output: 'ai.linto.gnomelinto.metainfo.xml',
  po_dir: '../po',
  install: true,
  install_dir: datadir / 'metainfo',
)

appstream_util = find_program('appstreamcli', required: false)
if appstream_util.found()
  test('Validate appstream file', appstream_util,
    args: ['validate', '--no-net', '--explain', metainfo_file])
endif

# GSettings schema
install_data(
  'ai.linto.gnomelinto.gschema.xml',
  install_dir: datadir / 'glib-2.0' / 'schemas',
)

compile_schemas = find_program('glib-compile-schemas', required: false)
if compile_schemas.found()
  test('Validate schema file', compile_schemas,
    args: ['--strict', '--dry-run', meson.current_source_dir()])
endif

# Application icon (scalable)
install_data(
  'icons/hicolor/scalable/apps/ai.linto.gnomelinto.svg',
  install_dir: datadir / 'icons' / 'hicolor' / 'scalable' / 'apps',
)
