project('gnome-linto', ['vala', 'c'],
  version: '1.0.14',
  license: 'AGPL-3.0-or-later',
  meson_version: '>= 1.0.0',
  default_options: [
    'warning_level=2',
  ],
)

gnome = import('gnome')
i18n = import('i18n')

app_id = 'ai.linto.gnomelinto'

cc = meson.get_compiler('c')

gtk_dep = dependency('gtk4', version: '>= 4.16')
adw_dep = dependency('libadwaita-1', version: '>= 1.6')
gio_dep = dependency('gio-2.0', version: '>= 2.80')
gst_dep = dependency('gstreamer-1.0', version: '>= 1.20')
gst_app_dep = dependency('gstreamer-app-1.0', version: '>= 1.20')
soup_dep = dependency('libsoup-3.0', version: '>= 3.0')
m_dep = cc.find_library('m', required: false)

prefix = get_option('prefix')
datadir = prefix / get_option('datadir')
localedir = prefix / get_option('localedir')

config_data = configuration_data()
config_data.set_quoted('APP_ID', app_id)
config_data.set_quoted('VERSION', meson.project_version())
config_data.set_quoted('GETTEXT_PACKAGE', meson.project_name())
config_data.set_quoted('LOCALEDIR', localedir)

config_h = configure_file(
  output: 'config.h',
  configuration: config_data,
)
config_dep = declare_dependency(
  sources: config_h,
  include_directories: include_directories('.'),
)

subdir('data')
subdir('po')
subdir('src')
subdir('tests')

gnome.post_install(
  glib_compile_schemas: true,
  gtk_update_icon_cache: true,
  update_desktop_database: true,
)
