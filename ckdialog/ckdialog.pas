{
  ckdialog — GTK 3 dialogs for shell scripts, with a real wizard.

  Copyright 2026 Dario Ruggi / Ruggi Software — https://ruggi.site
  Licensed under the Apache License, Version 2.0 (see ../LICENSE.md, ../NOTICE).

  A zenity-like tool that a script drives, plus the two things zenity lacks:
  a multi-page wizard in ONE window (Back/Next, a summary, all answers printed
  at the end) and a progress window that follows a log. Built for the AI
  Cockpit installer; generic enough for any script.

  Modes:
    ckdialog --wizard SPEC.json [--answers FILE] [--out FILE]
        Pages and fields from the JSON spec (see README.md). Prints KEY=value
        lines (stdout, or --out) on Finish; exit 1 on Cancel/close.
    ckdialog --progress [--title T] [--text T] [--total N] [--auto-close]
        Reads lines from stdin into a log view; a line starting with "▶ "
        advances the bar (N phases). Cannot be closed before EOF (the writer
        would get SIGPIPE). Exit 0 at EOF.
    ckdialog --askpass [PROMPT]        password entry → stdout (SUDO_ASKPASS helper)
    ckdialog --question --text T       exit 0 = Yes, 1 = No
    ckdialog --entry --text T [--entry-text D] [--hide-text]
    ckdialog --info|--error|--warning --text T
    ckdialog --check                   exit 0 when GTK can be loaded and a display is up

  Build:  bash build.sh   (fpc 3.2+, no -dev packages: GTK is bound at run time)
}
program ckdialog;
{$mode objfpc}{$H+}{$PACKRECORDS C}
uses ctypes, sysutils, classes, strutils, baseunix, unix, dynlibs, math, process, fpjson, jsonparser;

const
  VERSION = '1.0';
  GTK  = 'libgtk-3.so.0';
  GDK  = 'libgdk-3.so.0';
  GOBJ = 'libgobject-2.0.so.0';
  GLIB = 'libglib-2.0.so.0';
  GTK_WINDOW_TOPLEVEL = 0;
  GTK_WIN_POS_CENTER = 1;
  GTK_ORIENTATION_HORIZONTAL = 0;
  GTK_ORIENTATION_VERTICAL = 1;
  GTK_ALIGN_START = 1; GTK_ALIGN_END = 2; GTK_ALIGN_CENTER = 3;
  GTK_POLICY_AUTOMATIC = 1; GTK_POLICY_NEVER = 2;
  GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER = 2;
  GTK_STACK_TRANSITION_TYPE_SLIDE_LEFT_RIGHT = 6;
  GTK_STYLE_PROVIDER_PRIORITY_APPLICATION = 600;
  GTK_WRAP_WORD_CHAR = 3;

type
  gboolean = cint;
  PGtkWidget = Pointer;
  PGObject = Pointer;
  TGtkTextIter = array[0..127] of byte;   { opaque; 80 bytes on every platform we ship to }

var
  gtk_init: procedure(argc: Pointer; argv: Pointer); cdecl;
  gtk_main: procedure; cdecl;
  gtk_main_quit: procedure; cdecl;
  gtk_window_new: function(t: cint): PGtkWidget; cdecl;
  gtk_window_set_title: procedure(w: PGtkWidget; t: PChar); cdecl;
  gtk_window_set_default_size: procedure(w: PGtkWidget; a, b: cint); cdecl;
  gtk_window_set_position: procedure(w: PGtkWidget; p: cint); cdecl;
  gtk_window_set_icon_name: procedure(w: PGtkWidget; n: PChar); cdecl;
  gtk_window_set_icon_from_file: function(w: PGtkWidget; f: PChar; err: Pointer): gboolean; cdecl;
  gtk_window_set_keep_above: procedure(w: PGtkWidget; b: gboolean); cdecl;
  gtk_container_add: procedure(c, w: PGtkWidget); cdecl;
  gtk_container_set_border_width: procedure(c: PGtkWidget; b: cuint); cdecl;
  gtk_widget_show_all: procedure(w: PGtkWidget); cdecl;
  gtk_widget_show: procedure(w: PGtkWidget); cdecl;
  gtk_widget_hide: procedure(w: PGtkWidget); cdecl;
  gtk_widget_set_visible: procedure(w: PGtkWidget; b: gboolean); cdecl;
  gtk_widget_set_sensitive: procedure(w: PGtkWidget; b: gboolean); cdecl;
  gtk_widget_set_halign: procedure(w: PGtkWidget; a: cint); cdecl;
  gtk_widget_set_hexpand: procedure(w: PGtkWidget; b: gboolean); cdecl;
  gtk_widget_set_vexpand: procedure(w: PGtkWidget; b: gboolean); cdecl;
  gtk_widget_set_margin_top: procedure(w: PGtkWidget; m: cint); cdecl;
  gtk_widget_set_margin_bottom: procedure(w: PGtkWidget; m: cint); cdecl;
  gtk_widget_set_margin_start: procedure(w: PGtkWidget; m: cint); cdecl;
  gtk_widget_set_size_request: procedure(w: PGtkWidget; a, b: cint); cdecl;
  gtk_widget_grab_focus: procedure(w: PGtkWidget); cdecl;
  gtk_widget_get_style_context: function(w: PGtkWidget): Pointer; cdecl;
  gtk_style_context_add_class: procedure(c: Pointer; n: PChar); cdecl;
  gtk_style_context_add_provider_for_screen: procedure(s, p: Pointer; prio: cuint); cdecl;
  gtk_css_provider_new: function: Pointer; cdecl;
  gtk_css_provider_load_from_data: function(p: Pointer; d: PChar; len: PtrInt; err: Pointer): gboolean; cdecl;
  gtk_css_provider_load_from_resource: procedure(p: Pointer; path: PChar); cdecl;
  gtk_style_context_remove_provider_for_screen: procedure(s, p: Pointer); cdecl;
  gdk_screen_get_default: function: Pointer; cdecl;
  gtk_box_new: function(o: cint; spacing: cint): PGtkWidget; cdecl;
  gtk_box_pack_start: procedure(b, w: PGtkWidget; expand, fill: gboolean; pad: cuint); cdecl;
  gtk_box_pack_end: procedure(b, w: PGtkWidget; expand, fill: gboolean; pad: cuint); cdecl;
  gtk_label_new: function(t: PChar): PGtkWidget; cdecl;
  gtk_label_set_markup: procedure(l: PGtkWidget; t: PChar); cdecl;
  gtk_label_set_text: procedure(l: PGtkWidget; t: PChar); cdecl;
  gtk_label_set_line_wrap: procedure(l: PGtkWidget; b: gboolean); cdecl;
  gtk_label_set_xalign: procedure(l: PGtkWidget; x: single); cdecl;
  gtk_label_set_selectable: procedure(l: PGtkWidget; b: gboolean); cdecl;
  gtk_entry_new: function: PGtkWidget; cdecl;
  gtk_entry_set_text: procedure(e: PGtkWidget; t: PChar); cdecl;
  gtk_entry_get_text: function(e: PGtkWidget): PChar; cdecl;
  gtk_entry_set_visibility: procedure(e: PGtkWidget; b: gboolean); cdecl;
  gtk_entry_set_placeholder_text: procedure(e: PGtkWidget; t: PChar); cdecl;
  gtk_entry_set_activates_default: procedure(e: PGtkWidget; b: gboolean); cdecl;
  gtk_entry_set_icon_from_icon_name: procedure(e: PGtkWidget; pos: cint; name: PChar); cdecl;
  gtk_entry_get_visibility: function(e: PGtkWidget): gboolean; cdecl;
  gtk_check_button_new_with_label: function(t: PChar): PGtkWidget; cdecl;
  gtk_radio_button_new_with_label_from_widget: function(g: PGtkWidget; t: PChar): PGtkWidget; cdecl;
  gtk_toggle_button_set_active: procedure(b: PGtkWidget; a: gboolean); cdecl;
  gtk_toggle_button_get_active: function(b: PGtkWidget): gboolean; cdecl;
  gtk_combo_box_text_new: function: PGtkWidget; cdecl;
  gtk_combo_box_text_append: procedure(c: PGtkWidget; id, t: PChar); cdecl;
  gtk_combo_box_set_active_id: function(c: PGtkWidget; id: PChar): gboolean; cdecl;
  gtk_combo_box_get_active_id: function(c: PGtkWidget): PChar; cdecl;
  gtk_button_new_with_label: function(t: PChar): PGtkWidget; cdecl;
  gtk_button_set_label: procedure(b: PGtkWidget; t: PChar); cdecl;
  gtk_stack_new: function: PGtkWidget; cdecl;
  gtk_stack_add_named: procedure(s, w: PGtkWidget; n: PChar); cdecl;
  gtk_stack_set_visible_child_name: procedure(s: PGtkWidget; n: PChar); cdecl;
  gtk_stack_set_transition_type: procedure(s: PGtkWidget; t: cint); cdecl;
  gtk_progress_bar_new: function: PGtkWidget; cdecl;
  gtk_progress_bar_set_fraction: procedure(p: PGtkWidget; f: double); cdecl;
  gtk_progress_bar_set_text: procedure(p: PGtkWidget; t: PChar); cdecl;
  gtk_progress_bar_set_show_text: procedure(p: PGtkWidget; b: gboolean); cdecl;
  gtk_progress_bar_pulse: procedure(p: PGtkWidget); cdecl;
  gtk_text_view_new: function: PGtkWidget; cdecl;
  gtk_text_view_get_buffer: function(v: PGtkWidget): Pointer; cdecl;
  gtk_text_view_set_editable: procedure(v: PGtkWidget; b: gboolean); cdecl;
  gtk_text_view_set_monospace: procedure(v: PGtkWidget; b: gboolean); cdecl;
  gtk_text_view_set_cursor_visible: procedure(v: PGtkWidget; b: gboolean); cdecl;
  gtk_text_view_set_wrap_mode: procedure(v: PGtkWidget; m: cint); cdecl;
  gtk_text_view_scroll_mark_onscreen: procedure(v: PGtkWidget; m: Pointer); cdecl;
  gtk_text_buffer_insert_at_cursor: procedure(b: Pointer; t: PChar; len: cint); cdecl;
  gtk_text_buffer_get_end_iter: procedure(b: Pointer; it: Pointer); cdecl;
  gtk_text_buffer_place_cursor: procedure(b: Pointer; it: Pointer); cdecl;
  gtk_text_buffer_get_insert: function(b: Pointer): Pointer; cdecl;
  gtk_scrolled_window_new: function(a, b: Pointer): PGtkWidget; cdecl;
  gtk_scrolled_window_set_policy: procedure(s: PGtkWidget; h, v: cint); cdecl;
  gtk_file_chooser_button_new: function(t: PChar; action: cint): PGtkWidget; cdecl;
  gtk_file_chooser_set_filename: function(c: PGtkWidget; f: PChar): gboolean; cdecl;
  gtk_file_chooser_get_filename: function(c: PGtkWidget): PChar; cdecl;
  gtk_separator_new: function(o: cint): PGtkWidget; cdecl;
  gtk_image_new_from_file: function(f: PChar): PGtkWidget; cdecl;
  gtk_image_new_from_icon_name: function(n: PChar; size: cint): PGtkWidget; cdecl;
  g_signal_connect_data: function(obj: PGObject; sig: PChar; cb: Pointer; data: Pointer; destroy: Pointer; flags: cint): culong; cdecl;
  g_timeout_add: function(ms: cuint; fn: Pointer; data: Pointer): cuint; cdecl;
  g_free: procedure(p: Pointer); cdecl;
  g_set_prgname: procedure(n: PChar); cdecl;
  gtk_settings_get_default: function: Pointer; cdecl;
  gtk_settings_set_long_property: procedure(s: Pointer; name: PChar; v: clong; origin: PChar); cdecl;
  gtk_settings_set_string_property: procedure(s: Pointer; name: PChar; v: PChar; origin: PChar); cdecl;

procedure Bind(lib: TLibHandle; const libname, name: string; var p);
begin
  Pointer(p) := GetProcAddress(lib, name);
  if Pointer(p) = nil then begin writeln(stderr, 'ckdialog: missing symbol ', name, ' in ', libname); Halt(3); end;
end;

function LoadBindings(quiet: Boolean): Boolean;
var h: TLibHandle;
  function Open(const libname: string): Boolean;
  begin
    h := LoadLibrary(libname);
    Result := h <> NilHandle;
    if (not Result) and (not quiet) then writeln(stderr, 'ckdialog: cannot load ', libname, ' (GTK 3 runtime missing)');
  end;
begin
  Result := False;
  if not Open(GTK) then Exit;
  Bind(h, GTK, 'gtk_init', gtk_init);
  Bind(h, GTK, 'gtk_main', gtk_main);
  Bind(h, GTK, 'gtk_main_quit', gtk_main_quit);
  Bind(h, GTK, 'gtk_window_new', gtk_window_new);
  Bind(h, GTK, 'gtk_window_set_title', gtk_window_set_title);
  Bind(h, GTK, 'gtk_window_set_default_size', gtk_window_set_default_size);
  Bind(h, GTK, 'gtk_window_set_position', gtk_window_set_position);
  Bind(h, GTK, 'gtk_window_set_icon_name', gtk_window_set_icon_name);
  Bind(h, GTK, 'gtk_window_set_icon_from_file', gtk_window_set_icon_from_file);
  Bind(h, GTK, 'gtk_window_set_keep_above', gtk_window_set_keep_above);
  Bind(h, GTK, 'gtk_container_add', gtk_container_add);
  Bind(h, GTK, 'gtk_container_set_border_width', gtk_container_set_border_width);
  Bind(h, GTK, 'gtk_widget_show_all', gtk_widget_show_all);
  Bind(h, GTK, 'gtk_widget_show', gtk_widget_show);
  Bind(h, GTK, 'gtk_widget_hide', gtk_widget_hide);
  Bind(h, GTK, 'gtk_widget_set_visible', gtk_widget_set_visible);
  Bind(h, GTK, 'gtk_widget_set_sensitive', gtk_widget_set_sensitive);
  Bind(h, GTK, 'gtk_widget_set_halign', gtk_widget_set_halign);
  Bind(h, GTK, 'gtk_widget_set_hexpand', gtk_widget_set_hexpand);
  Bind(h, GTK, 'gtk_widget_set_vexpand', gtk_widget_set_vexpand);
  Bind(h, GTK, 'gtk_widget_set_margin_top', gtk_widget_set_margin_top);
  Bind(h, GTK, 'gtk_widget_set_margin_bottom', gtk_widget_set_margin_bottom);
  Bind(h, GTK, 'gtk_widget_set_margin_start', gtk_widget_set_margin_start);
  Bind(h, GTK, 'gtk_widget_set_size_request', gtk_widget_set_size_request);
  Bind(h, GTK, 'gtk_widget_grab_focus', gtk_widget_grab_focus);
  Bind(h, GTK, 'gtk_widget_get_style_context', gtk_widget_get_style_context);
  Bind(h, GTK, 'gtk_style_context_add_class', gtk_style_context_add_class);
  Bind(h, GTK, 'gtk_style_context_add_provider_for_screen', gtk_style_context_add_provider_for_screen);
  Bind(h, GTK, 'gtk_css_provider_new', gtk_css_provider_new);
  Bind(h, GTK, 'gtk_css_provider_load_from_data', gtk_css_provider_load_from_data);
  Bind(h, GTK, 'gtk_css_provider_load_from_resource', gtk_css_provider_load_from_resource);
  Bind(h, GTK, 'gtk_style_context_remove_provider_for_screen', gtk_style_context_remove_provider_for_screen);
  Bind(h, GTK, 'gtk_box_new', gtk_box_new);
  Bind(h, GTK, 'gtk_box_pack_start', gtk_box_pack_start);
  Bind(h, GTK, 'gtk_box_pack_end', gtk_box_pack_end);
  Bind(h, GTK, 'gtk_label_new', gtk_label_new);
  Bind(h, GTK, 'gtk_label_set_markup', gtk_label_set_markup);
  Bind(h, GTK, 'gtk_label_set_text', gtk_label_set_text);
  Bind(h, GTK, 'gtk_label_set_line_wrap', gtk_label_set_line_wrap);
  Bind(h, GTK, 'gtk_label_set_xalign', gtk_label_set_xalign);
  Bind(h, GTK, 'gtk_label_set_selectable', gtk_label_set_selectable);
  Bind(h, GTK, 'gtk_entry_new', gtk_entry_new);
  Bind(h, GTK, 'gtk_entry_set_text', gtk_entry_set_text);
  Bind(h, GTK, 'gtk_entry_get_text', gtk_entry_get_text);
  Bind(h, GTK, 'gtk_entry_set_visibility', gtk_entry_set_visibility);
  Bind(h, GTK, 'gtk_entry_set_placeholder_text', gtk_entry_set_placeholder_text);
  Bind(h, GTK, 'gtk_entry_set_activates_default', gtk_entry_set_activates_default);
  Bind(h, GTK, 'gtk_entry_set_icon_from_icon_name', gtk_entry_set_icon_from_icon_name);
  Bind(h, GTK, 'gtk_entry_get_visibility', gtk_entry_get_visibility);
  Bind(h, GTK, 'gtk_check_button_new_with_label', gtk_check_button_new_with_label);
  Bind(h, GTK, 'gtk_radio_button_new_with_label_from_widget', gtk_radio_button_new_with_label_from_widget);
  Bind(h, GTK, 'gtk_toggle_button_set_active', gtk_toggle_button_set_active);
  Bind(h, GTK, 'gtk_toggle_button_get_active', gtk_toggle_button_get_active);
  Bind(h, GTK, 'gtk_combo_box_text_new', gtk_combo_box_text_new);
  Bind(h, GTK, 'gtk_combo_box_text_append', gtk_combo_box_text_append);
  Bind(h, GTK, 'gtk_combo_box_set_active_id', gtk_combo_box_set_active_id);
  Bind(h, GTK, 'gtk_combo_box_get_active_id', gtk_combo_box_get_active_id);
  Bind(h, GTK, 'gtk_button_new_with_label', gtk_button_new_with_label);
  Bind(h, GTK, 'gtk_button_set_label', gtk_button_set_label);
  Bind(h, GTK, 'gtk_stack_new', gtk_stack_new);
  Bind(h, GTK, 'gtk_stack_add_named', gtk_stack_add_named);
  Bind(h, GTK, 'gtk_stack_set_visible_child_name', gtk_stack_set_visible_child_name);
  Bind(h, GTK, 'gtk_stack_set_transition_type', gtk_stack_set_transition_type);
  Bind(h, GTK, 'gtk_progress_bar_new', gtk_progress_bar_new);
  Bind(h, GTK, 'gtk_progress_bar_set_fraction', gtk_progress_bar_set_fraction);
  Bind(h, GTK, 'gtk_progress_bar_set_text', gtk_progress_bar_set_text);
  Bind(h, GTK, 'gtk_progress_bar_set_show_text', gtk_progress_bar_set_show_text);
  Bind(h, GTK, 'gtk_progress_bar_pulse', gtk_progress_bar_pulse);
  Bind(h, GTK, 'gtk_text_view_new', gtk_text_view_new);
  Bind(h, GTK, 'gtk_text_view_get_buffer', gtk_text_view_get_buffer);
  Bind(h, GTK, 'gtk_text_view_set_editable', gtk_text_view_set_editable);
  Bind(h, GTK, 'gtk_text_view_set_monospace', gtk_text_view_set_monospace);
  Bind(h, GTK, 'gtk_text_view_set_cursor_visible', gtk_text_view_set_cursor_visible);
  Bind(h, GTK, 'gtk_text_view_set_wrap_mode', gtk_text_view_set_wrap_mode);
  Bind(h, GTK, 'gtk_text_view_scroll_mark_onscreen', gtk_text_view_scroll_mark_onscreen);
  Bind(h, GTK, 'gtk_text_buffer_insert_at_cursor', gtk_text_buffer_insert_at_cursor);
  Bind(h, GTK, 'gtk_text_buffer_get_end_iter', gtk_text_buffer_get_end_iter);
  Bind(h, GTK, 'gtk_text_buffer_place_cursor', gtk_text_buffer_place_cursor);
  Bind(h, GTK, 'gtk_text_buffer_get_insert', gtk_text_buffer_get_insert);
  Bind(h, GTK, 'gtk_scrolled_window_new', gtk_scrolled_window_new);
  Bind(h, GTK, 'gtk_scrolled_window_set_policy', gtk_scrolled_window_set_policy);
  Bind(h, GTK, 'gtk_file_chooser_button_new', gtk_file_chooser_button_new);
  Bind(h, GTK, 'gtk_file_chooser_set_filename', gtk_file_chooser_set_filename);
  Bind(h, GTK, 'gtk_file_chooser_get_filename', gtk_file_chooser_get_filename);
  Bind(h, GTK, 'gtk_separator_new', gtk_separator_new);
  Bind(h, GTK, 'gtk_image_new_from_file', gtk_image_new_from_file);
  Bind(h, GTK, 'gtk_image_new_from_icon_name', gtk_image_new_from_icon_name);
  Bind(h, GTK, 'gtk_settings_get_default', gtk_settings_get_default);
  Bind(h, GTK, 'gtk_settings_set_long_property', gtk_settings_set_long_property);
  Bind(h, GTK, 'gtk_settings_set_string_property', gtk_settings_set_string_property);
  if not Open(GDK) then Exit;
  Bind(h, GDK, 'gdk_screen_get_default', gdk_screen_get_default);
  if not Open(GOBJ) then Exit;
  Bind(h, GOBJ, 'g_signal_connect_data', g_signal_connect_data);
  if not Open(GLIB) then Exit;
  Bind(h, GLIB, 'g_timeout_add', g_timeout_add);
  Bind(h, GLIB, 'g_free', g_free);
  Bind(h, GLIB, 'g_set_prgname', g_set_prgname);
  Result := True;
end;

{ ── small helpers ────────────────────────────────────────────────────────── }
var
  ExitCode: Integer = 1;
  Dark: Boolean = False;
  ThemeForced: Integer = -1;   { --light = 0, --dark = 1 }
  OptTitle: string = '';
  OptText: string = '';
  OptIcon: string = '';

function Esc(const s: string): string;   { Pango markup escape }
begin
  Result := StringReplace(s, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
end;

function MkLabel(const markup: string; wrap: Boolean): PGtkWidget;
begin
  Result := gtk_label_new(nil);
  gtk_label_set_markup(Result, PChar(markup));
  gtk_label_set_xalign(Result, 0);
  gtk_widget_set_halign(Result, GTK_ALIGN_START);
  if wrap then gtk_label_set_line_wrap(Result, 1);
end;

procedure AddClass(w: PGtkWidget; const cls: string);
begin gtk_style_context_add_class(gtk_widget_get_style_context(w), PChar(cls)); end;

{ password entries: an eye icon at the right end shows/hides what was typed }
procedure OnEyePress(e: PGtkWidget; pos: cint; ev: Pointer; data: Pointer); cdecl;
begin
  if gtk_entry_get_visibility(e) <> 0 then begin
    gtk_entry_set_visibility(e, 0); gtk_entry_set_icon_from_icon_name(e, 1, 'view-reveal-symbolic');
  end else begin
    gtk_entry_set_visibility(e, 1); gtk_entry_set_icon_from_icon_name(e, 1, 'view-conceal-symbolic');
  end;
end;
procedure AddEye(e: PGtkWidget);
begin
  gtk_entry_set_icon_from_icon_name(e, 1, 'view-reveal-symbolic');
  g_signal_connect_data(e, 'icon-press', @OnEyePress, nil, nil, 0);
end;

{ the theme the person picked last time (wizard toggle) — the askpass and
  progress windows of the same run follow it; --dark/--light still win }
function ThemeFile: string;
var d: string;
begin
  d := GetEnvironmentVariable('XDG_CONFIG_HOME'); if d = '' then d := GetEnvironmentVariable('HOME') + '/.config';
  Result := d + '/ckdialog/theme';
end;
procedure SaveThemeChoice;
var sl: TStringList;
begin
  try
    ForceDirectories(ExtractFileDir(ThemeFile));
    sl := TStringList.Create; try if Dark then sl.Add('dark') else sl.Add('light'); sl.SaveToFile(ThemeFile); finally sl.Free; end;
  except end;
end;
function LoadThemeChoice(out isDark: Boolean): Boolean;
var sl: TStringList;
begin
  Result := False;
  if not FileExists(ThemeFile) then Exit;
  sl := TStringList.Create;
  try sl.LoadFromFile(ThemeFile); if sl.Count > 0 then begin isDark := Trim(sl[0]) = 'dark'; Result := True; end; finally sl.Free; end;
end;

{ ── theme: follow the desktop, toggle at will ──────────────────────────── }
function RunOut(const cmd: string; const args: array of string): string;
var s: string;
begin
  Result := '';
  try if RunCommand(cmd, args, s, [poNoConsole, poStderrToOutPut]) then Result := Trim(s); except Result := ''; end;
end;

{ GNOME/Ubuntu: color-scheme prefer-dark; Cinnamon/MATE/older GNOME: a "…-dark"
  GTK theme name; XFCE: xsettings; KDE: kdeglobals ColorScheme. No answer → light. }
function DesktopPrefersDark: Boolean;
var s, kde: string; sl: TStringList; i: Integer;
begin
  Result := False;
  if Pos('dark', LowerCase(GetEnvironmentVariable('GTK_THEME'))) > 0 then Exit(True);
  s := RunOut('gsettings', ['get', 'org.gnome.desktop.interface', 'color-scheme']);
  if Pos('prefer-dark', s) > 0 then Exit(True);
  for s in [RunOut('gsettings', ['get', 'org.cinnamon.desktop.interface', 'gtk-theme']),
            RunOut('gsettings', ['get', 'org.gnome.desktop.interface', 'gtk-theme']),
            RunOut('gsettings', ['get', 'org.mate.interface', 'gtk-theme']),
            RunOut('xfconf-query', ['-c', 'xsettings', '-p', '/Net/ThemeName'])] do
    if Pos('dark', LowerCase(s)) > 0 then Exit(True);
  kde := GetEnvironmentVariable('HOME') + '/.config/kdeglobals';
  if FileExists(kde) then begin
    sl := TStringList.Create;
    try
      sl.LoadFromFile(kde);
      for i := 0 to sl.Count - 1 do
        if (Pos('ColorScheme=', sl[i]) = 1) and (Pos('dark', LowerCase(sl[i])) > 0) then Exit(True);
    finally sl.Free; end;
  end;
end;

var BaseTheme: string = '';   { the desktop's GTK theme without a -dark suffix }
function ThemeDirExists(const name: string): Boolean;
begin
  Result := DirectoryExists('/usr/share/themes/' + name + '/gtk-3.0')
         or DirectoryExists(GetEnvironmentVariable('HOME') + '/.themes/' + name + '/gtk-3.0')
         or DirectoryExists(GetEnvironmentVariable('HOME') + '/.local/share/themes/' + name + '/gtk-3.0');
end;
{ "Mint-Y-Blue" with n=2 → "Mint-Y-Dark-Blue"; n=1 → "Mint-Dark-Y-Blue" }
function DarkInsert(const name: string; n: Integer): string;
var parts: TStringArray; i: Integer;
begin
  parts := name.Split('-');
  if Length(parts) <= n then Exit(name + '-Dark');
  Result := '';
  for i := 0 to High(parts) do begin
    if i = n then Result := Result + 'Dark-';
    Result := Result + parts[i];
    if i < High(parts) then Result := Result + '-';
  end;
end;

var DarkCssProv: Pointer = nil;
procedure ApplyTheme;
var want, cand: string;
begin
  { prefer-dark works for Adwaita-style themes (gtk-dark.css); Yaru/Mint-Y & co.
    ship the dark look as a separate "<name>-dark" theme, so switch the name too }
  gtk_settings_set_long_property(gtk_settings_get_default(), 'gtk-application-prefer-dark-theme', Ord(Dark), 'ckdialog');
  { XSettings daemons (MATE's, some XFCE) keep re-imposing gtk-theme-name, so the
    name switch alone can be lost. Belt and braces: for dark, also lay GTK's own
    built-in Adwaita dark CSS over everything at USER priority; drop it for light. }
  if Dark then begin
    if DarkCssProv = nil then begin DarkCssProv := gtk_css_provider_new(); gtk_css_provider_load_from_resource(DarkCssProv, '/org/gtk/libgtk/theme/Adwaita/gtk-contained-dark.css'); end;
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), DarkCssProv, 800);
  end else if DarkCssProv <> nil then gtk_style_context_remove_provider_for_screen(gdk_screen_get_default(), DarkCssProv);
  if BaseTheme = '' then begin
    for want in [RunOut('gsettings', ['get', 'org.gnome.desktop.interface', 'gtk-theme']),
                 RunOut('gsettings', ['get', 'org.cinnamon.desktop.interface', 'gtk-theme']),
                 RunOut('gsettings', ['get', 'org.mate.interface', 'gtk-theme']),
                 RunOut('xfconf-query', ['-c', 'xsettings', '-p', '/Net/ThemeName'])] do
      if want <> '' then begin BaseTheme := Trim(StringReplace(want, '''', '', [rfReplaceAll])); Break; end;
    { light name = the desktop's name without its "dark" segment: Yaru-dark → Yaru, Mint-Y-Dark-Blue → Mint-Y-Blue }
    BaseTheme := StringReplace(BaseTheme, '-Dark', '', [rfReplaceAll]);
    BaseTheme := StringReplace(BaseTheme, '-dark', '', [rfReplaceAll]);
    if BaseTheme = '' then BaseTheme := '-';   { unknown: leave the name alone }
  end;
  if BaseTheme = '-' then Exit;
  want := '';
  if Dark then begin
    for cand in [BaseTheme + '-dark', BaseTheme + '-Dark', DarkInsert(BaseTheme, 2), DarkInsert(BaseTheme, 1)] do
      if ThemeDirExists(cand) then begin want := cand; Break; end;
    { no dark twin (MATE's Menta, many small themes): Adwaita-dark is built into GTK 3 itself }
    if want = '' then want := 'Adwaita-dark';
  end else want := BaseTheme;   { back to the desktop's own name (GTK resolves a built-in like Adwaita itself) }
  if want <> '' then gtk_settings_set_string_property(gtk_settings_get_default(), 'gtk-theme-name', PChar(want), 'ckdialog');
end;

var ThemeBtn: PGtkWidget = nil;
procedure SetThemeButtonLabel;
begin if ThemeBtn <> nil then begin if Dark then gtk_button_set_label(ThemeBtn, '☀ Light') else gtk_button_set_label(ThemeBtn, '☾ Dark'); end; end;
procedure OnThemeToggle(w: PGtkWidget; data: Pointer); cdecl;
begin Dark := not Dark; ApplyTheme; SetThemeButtonLabel; SaveThemeChoice; end;
function MkThemeButton: PGtkWidget;
begin
  ThemeBtn := gtk_button_new_with_label(''); SetThemeButtonLabel;
  gtk_widget_set_halign(ThemeBtn, GTK_ALIGN_END);
  g_signal_connect_data(ThemeBtn, 'clicked', @OnThemeToggle, nil, nil, 0);
  Result := ThemeBtn;
end;

procedure InstallCss;
var p: Pointer; css: string;
begin
  css := '.ck-title { font-size: 17pt; font-weight: bold; }' +
         '.ck-sub { opacity: 0.75; }' +
         '.ck-h { font-weight: bold; margin-top: 6px; }' +
         '.ck-err { color: #d33; }' +
         '.ck-ok { color: #2a7; }' +
         'entry, combobox, button { min-height: 30px; }';
  p := gtk_css_provider_new();
  gtk_css_provider_load_from_data(p, PChar(css), Length(css), nil);
  gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), p, GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
end;

function NewWindow(const title: string; w, h: Integer): PGtkWidget;
begin
  Result := gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(Result, PChar(title));
  gtk_window_set_default_size(Result, w, h);
  gtk_window_set_position(Result, GTK_WIN_POS_CENTER);
  gtk_container_set_border_width(Result, 14);
  if OptIcon <> '' then begin
    if FileExists(OptIcon) then gtk_window_set_icon_from_file(Result, PChar(OptIcon), nil)
    else gtk_window_set_icon_name(Result, PChar(OptIcon));
  end;
end;

procedure OnQuitOk(w: PGtkWidget; data: Pointer); cdecl;  begin ExitCode := 0; gtk_main_quit; end;
procedure OnQuitNo(w: PGtkWidget; data: Pointer); cdecl;  begin ExitCode := 1; gtk_main_quit; end;
function  OnDeleteNo(w: PGtkWidget; ev, data: Pointer): gboolean; cdecl; begin ExitCode := 1; gtk_main_quit; Result := 1; end;
function  OnDeleteVeto(w: PGtkWidget; ev, data: Pointer): gboolean; cdecl; begin Result := 1; end;

{ ── simple dialogs: --question --info --error --entry --askpass ──────────── }
var SimpleEntry: PGtkWidget = nil;

procedure OnEntryOk(w: PGtkWidget; data: Pointer); cdecl;
begin
  writeln(StrPas(gtk_entry_get_text(SimpleEntry)));
  ExitCode := 0; gtk_main_quit;
end;

procedure RunSimple(const kind: string; const entryDefault: string; hideText: Boolean);
var win, box, row, b1, b2, lbl, img: PGtkWidget; icon: string;
begin
  if OptTitle = '' then OptTitle := 'ckdialog';
  win := NewWindow(OptTitle, 420, -1);
  gtk_window_set_keep_above(win, 1);
  box := gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  gtk_container_add(win, box);
  row := gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
  case kind of
    'error':    icon := 'dialog-error';
    'warning':  icon := 'dialog-warning';
    'question': icon := 'dialog-question';
    'askpass':  icon := 'dialog-password';
  else          icon := 'dialog-information';
  end;
  img := gtk_image_new_from_icon_name(PChar(icon), 6);   { GTK_ICON_SIZE_DIALOG }
  gtk_box_pack_start(row, img, 0, 0, 0);
  lbl := MkLabel(Esc(OptText), True);
  gtk_widget_set_hexpand(lbl, 1);
  gtk_box_pack_start(row, lbl, 1, 1, 0);
  gtk_box_pack_start(box, row, 0, 0, 0);
  if (kind = 'entry') or (kind = 'askpass') then begin
    SimpleEntry := gtk_entry_new();
    gtk_entry_set_text(SimpleEntry, PChar(entryDefault));
    if hideText or (kind = 'askpass') then begin gtk_entry_set_visibility(SimpleEntry, 0); AddEye(SimpleEntry); end;
    gtk_box_pack_start(box, SimpleEntry, 0, 0, 0);
    g_signal_connect_data(SimpleEntry, 'activate', @OnEntryOk, nil, nil, 0);
  end;
  row := gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  gtk_widget_set_halign(row, GTK_ALIGN_END);
  if kind = 'question' then begin
    b2 := gtk_button_new_with_label('No');  g_signal_connect_data(b2, 'clicked', @OnQuitNo, nil, nil, 0);
    b1 := gtk_button_new_with_label('Yes'); g_signal_connect_data(b1, 'clicked', @OnQuitOk, nil, nil, 0);
    gtk_box_pack_start(row, b2, 0, 0, 0); gtk_box_pack_start(row, b1, 0, 0, 0);
  end else if (kind = 'entry') or (kind = 'askpass') then begin
    b2 := gtk_button_new_with_label('Cancel'); g_signal_connect_data(b2, 'clicked', @OnQuitNo, nil, nil, 0);
    b1 := gtk_button_new_with_label('OK');     g_signal_connect_data(b1, 'clicked', @OnEntryOk, nil, nil, 0);
    gtk_box_pack_start(row, b2, 0, 0, 0); gtk_box_pack_start(row, b1, 0, 0, 0);
  end else begin
    b1 := gtk_button_new_with_label('OK'); g_signal_connect_data(b1, 'clicked', @OnQuitOk, nil, nil, 0);
    gtk_box_pack_start(row, b1, 0, 0, 0);
  end;
  gtk_box_pack_end(box, row, 0, 0, 0);
  g_signal_connect_data(win, 'delete-event', @OnDeleteNo, nil, nil, 0);
  gtk_widget_show_all(win);
  if SimpleEntry <> nil then gtk_widget_grab_focus(SimpleEntry);
  gtk_main;
end;

{ ── progress: follow stdin ───────────────────────────────────────────────── }
var
  PBar, PLog, PPhase, PClose: PGtkWidget;
  PBuf: Pointer;
  PTotal: Integer = 0;
  PDone: Integer = 0;
  PEof: Boolean = False;
  PAutoClose: Boolean = False;
  PFailed: Boolean = False;
  PPhaseMatch: string = '▶';   { a log line starting with this (after trim) is a phase }
  PPending: string = '';

function StripAnsi(const s: string): string;
var i: Integer; inEsc: Boolean;
begin
  Result := ''; inEsc := False;
  for i := 1 to Length(s) do begin
    if inEsc then begin
      if (s[i] in ['a'..'z', 'A'..'Z']) then inEsc := False;
    end else if s[i] = #27 then inEsc := True
    else if s[i] <> #13 then Result := Result + s[i];
  end;
end;

procedure LogAppend(const line: string);
var it: TGtkTextIter; s: string;
begin
  s := line + #10;
  gtk_text_buffer_get_end_iter(PBuf, @it);
  gtk_text_buffer_place_cursor(PBuf, @it);
  gtk_text_buffer_insert_at_cursor(PBuf, PChar(s), Length(s));
  gtk_text_view_scroll_mark_onscreen(PLog, gtk_text_buffer_get_insert(PBuf));
end;

procedure ProgressLine(const raw: string);
var line: string;
begin
  line := StripAnsi(raw);
  if Trim(line) = '' then Exit;
  LogAppend(line);
  { only the run's own stop line counts — a warning ✗, or an old failure in an appended log, must not paint Stopped }
  if (Pos('Install stopped in', line) > 0) or (Pos('FATAL', line) > 0) then PFailed := True;
  if Pos(PPhaseMatch, TrimLeft(line)) = 1 then begin
    Inc(PDone);
    gtk_label_set_markup(PPhase, PChar('<b>' + Esc(Trim(StringReplace(TrimLeft(line), '▶', '', []))) + '</b>'));
    if PTotal > 0 then begin
      gtk_progress_bar_set_fraction(PBar, Min(1.0, PDone / PTotal));
      gtk_progress_bar_set_text(PBar, PChar(Format('%d / %d', [PDone, PTotal])));
    end else gtk_progress_bar_pulse(PBar);
  end else if PTotal = 0 then gtk_progress_bar_pulse(PBar);
end;

function OnProgressTick(data: Pointer): gboolean; cdecl;
var buf: array[0..4095] of char; n: PtrInt; p: Integer;
begin
  Result := 1;
  if PEof then Exit(0);
  repeat
    n := fpRead(0, buf, SizeOf(buf));
    if n > 0 then begin
      PPending := PPending + Copy(buf, 1, n);
      p := Pos(#10, PPending);
      while p > 0 do begin
        ProgressLine(Copy(PPending, 1, p - 1));
        Delete(PPending, 1, p);
        p := Pos(#10, PPending);
      end;
    end else if n = 0 then begin
      PEof := True;
      if PPending <> '' then ProgressLine(PPending);
      if PFailed then begin
        gtk_progress_bar_set_text(PBar, 'Stopped');
        gtk_label_set_markup(PPhase, '<span foreground="#d33"><b>Stopped with an error — see the last lines below</b></span>');
      end else begin
        gtk_progress_bar_set_fraction(PBar, 1.0);
        gtk_progress_bar_set_text(PBar, 'Done');
        gtk_label_set_markup(PPhase, '<b>Finished</b>');
      end;
      gtk_widget_set_sensitive(PClose, 1);
      gtk_button_set_label(PClose, 'Close');
      ExitCode := Ord(PFailed);
      if PAutoClose and not PFailed then gtk_main_quit;
      Exit(0);
    end;
  until n <= 0;   { EAGAIN: nothing more right now }
end;

function OnProgressDelete(w: PGtkWidget; ev, data: Pointer): gboolean; cdecl;
begin
  { closing the reader would SIGPIPE the writer (the installer) — refuse until EOF }
  if PEof then begin gtk_main_quit; Exit(0); end;
  Result := 1;
end;

procedure RunProgress;
var win, box, sw, lbl: PGtkWidget; fl: cint;
begin
  if OptTitle = '' then OptTitle := 'Working…';
  win := NewWindow(OptTitle, 640, 420);
  box := gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_container_add(win, box);
  lbl := MkLabel('<span size="large"><b>' + Esc(OptTitle) + '</b></span>', True);
  gtk_box_pack_start(box, lbl, 0, 0, 0);
  if OptText <> '' then begin lbl := MkLabel(Esc(OptText), True); AddClass(lbl, 'ck-sub'); gtk_box_pack_start(box, lbl, 0, 0, 0); end;
  PPhase := MkLabel('<b>Starting…</b>', True);
  gtk_box_pack_start(box, PPhase, 0, 0, 0);
  PBar := gtk_progress_bar_new();
  gtk_progress_bar_set_show_text(PBar, 1);
  if PTotal > 0 then gtk_progress_bar_set_text(PBar, PChar(Format('0 / %d', [PTotal])));
  gtk_box_pack_start(box, PBar, 0, 0, 0);
  sw := gtk_scrolled_window_new(nil, nil);
  gtk_scrolled_window_set_policy(sw, GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC);
  gtk_widget_set_vexpand(sw, 1);
  PLog := gtk_text_view_new();
  gtk_text_view_set_editable(PLog, 0);
  gtk_text_view_set_cursor_visible(PLog, 0);
  gtk_text_view_set_monospace(PLog, 1);
  gtk_text_view_set_wrap_mode(PLog, GTK_WRAP_WORD_CHAR);
  PBuf := gtk_text_view_get_buffer(PLog);
  gtk_container_add(sw, PLog);
  gtk_box_pack_start(box, sw, 1, 1, 0);
  lbl := gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  gtk_box_pack_start(lbl, MkThemeButton, 0, 0, 0);
  PClose := gtk_button_new_with_label('Working…');
  gtk_widget_set_sensitive(PClose, 0);
  g_signal_connect_data(PClose, 'clicked', @OnQuitOk, nil, nil, 0);
  gtk_box_pack_end(lbl, PClose, 0, 0, 0);
  gtk_box_pack_end(box, lbl, 0, 0, 0);
  g_signal_connect_data(win, 'delete-event', @OnProgressDelete, nil, nil, 0);
  fl := fpFcntl(0, F_GETFL); fpFcntl(0, F_SETFL, fl or O_NONBLOCK);
  g_timeout_add(100, @OnProgressTick, nil);
  gtk_widget_show_all(win);
  gtk_main;
end;

{ ── wizard ───────────────────────────────────────────────────────────────── }
type
  TField = record
    key, ftype, def, labelText: string;
    widget: PGtkWidget;            { entry / check / combo / folder / first radio }
    opts: array of PGtkWidget;     { radio buttons / checklist checks }
    optIds: array of string;
    optTexts: array of string;
    confirmOf: string;             { password confirm: key of the field it must match }
    row: PGtkWidget;               { container to hide for show_if }
    showIf: TJSONObject;
    pageIdx: Integer;
  end;
  TPage = record
    id, title, ptype: string;
    box: PGtkWidget;
    showIf: TJSONObject;
    summaryLbl: PGtkWidget;
  end;
var
  Spec: TJSONObject;
  Pages: array of TPage;
  Fields: array of TField;
  WStack, WBack, WNext, WCancel, WErr, WStep: PGtkWidget;
  CurPage: Integer = 0;
  OutFile: string = '';
  Answers: TStringList;   { KEY=value prefill (--answers) }

function FieldValue(const f: TField): string;
var i: Integer; p: PChar;
begin
  Result := '';
  case f.ftype of
    'entry', 'password': Result := StrPas(gtk_entry_get_text(f.widget));
    'folder': begin p := gtk_file_chooser_get_filename(f.widget); if p <> nil then begin Result := StrPas(p); g_free(p); end; end;
    'check': if gtk_toggle_button_get_active(f.widget) <> 0 then Result := 'y' else Result := 'n';
    'radio': for i := 0 to High(f.opts) do if gtk_toggle_button_get_active(f.opts[i]) <> 0 then Exit(f.optIds[i]);
    'checklist': for i := 0 to High(f.opts) do if gtk_toggle_button_get_active(f.opts[i]) <> 0 then
                   Result := Trim(Result + ' ' + f.optIds[i]);
    'select': begin p := gtk_combo_box_get_active_id(f.widget); if p <> nil then Result := StrPas(p); end;
  end;
end;

function ValueOfKey(const key: string): string;
var i: Integer;
begin
  for i := 0 to High(Fields) do if Fields[i].key = key then Exit(FieldValue(Fields[i]));
  Result := '';
end;

{ show_if: {"KEY": ["v1","v2"]} — every listed key must currently hold one of its values }
function ShowIf(o: TJSONObject): Boolean;
var i, j: Integer; v: string; arr: TJSONArray;
begin
  Result := True;
  if o = nil then Exit;
  for i := 0 to o.Count - 1 do begin
    v := ValueOfKey(o.Names[i]);
    if o.Items[i].JSONType = jtArray then begin
      arr := TJSONArray(o.Items[i]); Result := False;
      for j := 0 to arr.Count - 1 do if arr.Items[j].AsString = v then Result := True;
      if not Result then Exit;
    end else if o.Items[i].AsString <> v then Exit(False);
  end;
end;

function PageVisible(i: Integer): Boolean;
begin Result := ShowIf(Pages[i].showIf); end;

procedure RefreshFieldVisibility;
var i: Integer;
begin
  for i := 0 to High(Fields) do
    if Fields[i].showIf <> nil then gtk_widget_set_visible(Fields[i].row, Ord(ShowIf(Fields[i].showIf)));
end;

function MaskIfSecret(const f: TField; const v: string): string;
var i: Integer;
begin
  if (f.ftype = 'radio') or (f.ftype = 'select') then begin
    Result := v;
    for i := 0 to High(f.optIds) do if f.optIds[i] = v then begin Result := f.optTexts[i]; Break; end;
    if Length(Result) > 60 then Result := Copy(Result, 1, 57) + '…';
  end
  else if f.ftype = 'checklist' then begin
    { the title part of each ticked option ("Node.js — already here" → "Node.js") }
    Result := '';
    for i := 0 to High(f.optIds) do if Pos(' ' + f.optIds[i] + ' ', ' ' + v + ' ') > 0 then begin
      if Result <> '' then Result := Result + ', ';
      if Pos(' — ', f.optTexts[i]) > 0 then Result := Result + Copy(f.optTexts[i], 1, Pos(' — ', f.optTexts[i]) - 1)
      else Result := Result + f.optTexts[i];
    end;
    if Result = '' then Result := '—';
  end
  else if f.ftype = 'password' then Result := DupeString('•', Min(8, Length(v)))
  else if f.ftype = 'check' then begin if v = 'y' then Result := 'yes' else Result := 'no'; end
  else Result := v;
end;

{ one line per page: "Page title — label: value · label: value" — a long list
  of one-per-line answers did not fit the window on the first desktop run }
procedure BuildSummary(i: Integer);
var s, line, v: string; j, p: Integer;
begin
  s := '';
  for p := 0 to High(Pages) do begin
    if (p = i) or (not PageVisible(p)) then Continue;
    line := '';
    for j := 0 to High(Fields) do begin
      if Fields[j].pageIdx <> p then Continue;
      if (Fields[j].confirmOf <> '') or (Fields[j].ftype = 'note') then Continue;
      if (Fields[j].showIf <> nil) and (not ShowIf(Fields[j].showIf)) then Continue;
      v := FieldValue(Fields[j]);
      if v = '' then v := '—';
      if line <> '' then line := line + '  ·  ';
      line := line + Esc(Fields[j].labelText) + ': <b>' + Esc(MaskIfSecret(Fields[j], v)) + '</b>';
    end;
    if line = '' then Continue;
    s := s + '<span size="small" alpha="70%">' + Esc(Pages[p].title) + '</span>'#10 + line + #10#10;
  end;
  gtk_label_set_markup(Pages[i].summaryLbl, PChar(TrimRight(s)));
end;

function Validate(i: Integer): string;   { '' = ok, else the message }
var j: Integer; v, other: string;
begin
  Result := '';
  for j := 0 to High(Fields) do begin
    if Fields[j].pageIdx <> i then Continue;
    if (Fields[j].showIf <> nil) and (not ShowIf(Fields[j].showIf)) then Continue;
    v := FieldValue(Fields[j]);
    if Fields[j].confirmOf <> '' then begin
      other := ValueOfKey(Fields[j].confirmOf);
      if v <> other then Exit('The two passwords differ.');
    end;
    if (Fields[j].ftype = 'password') and (v <> '') and (Length(v) < 6) then Exit('Password: at least 6 characters.');
  end;
end;

procedure GotoPage(i: Integer; forward: Boolean);
var n, vis, idx: Integer;
begin
  { skip pages whose show_if is false }
  while (i >= 0) and (i <= High(Pages)) and (not PageVisible(i)) do if forward then Inc(i) else Dec(i);
  if i < 0 then i := 0;
  if i > High(Pages) then i := High(Pages);
  CurPage := i;
  if Pages[i].ptype = 'summary' then BuildSummary(i);
  RefreshFieldVisibility;
  gtk_stack_set_visible_child_name(WStack, PChar(Pages[i].id));
  gtk_widget_set_sensitive(WBack, Ord(i > 0));
  n := 0; vis := 0; idx := 0;
  for n := 0 to High(Pages) do if PageVisible(n) then begin Inc(vis); if n <= i then Inc(idx); end;
  gtk_label_set_markup(WStep, PChar('<span size="small">' + Esc(Format('Step %d of %d', [idx, vis])) + '</span>'));
  if i = High(Pages) then gtk_button_set_label(WNext, PChar(Spec.Get('finish_label', 'Finish')))
  else gtk_button_set_label(WNext, 'Next  ›');
  gtk_label_set_text(WErr, '');
end;

procedure WriteAnswers;
var j: Integer; sl: TStringList;
begin
  sl := TStringList.Create;
  try
    for j := 0 to High(Fields) do begin
      if Fields[j].confirmOf <> '' then Continue;
      sl.Add(Fields[j].key + '=' + FieldValue(Fields[j]));
    end;
    if OutFile <> '' then sl.SaveToFile(OutFile) else write(sl.Text);
  finally sl.Free; end;
end;

procedure OnNext(w: PGtkWidget; data: Pointer); cdecl;
var msg: string;
begin
  msg := Validate(CurPage);
  if msg <> '' then begin gtk_label_set_markup(WErr, PChar('<span foreground="#d33">' + Esc(msg) + '</span>')); Exit; end;
  if CurPage = High(Pages) then begin WriteAnswers; ExitCode := 0; gtk_main_quit; Exit; end;
  GotoPage(CurPage + 1, True);
end;
procedure OnBack(w: PGtkWidget; data: Pointer); cdecl; begin if CurPage > 0 then GotoPage(CurPage - 1, False); end;

function Prefill(const key, def: string): string;
var i: Integer;
begin
  Result := def;
  if Answers = nil then Exit;
  i := Answers.IndexOfName(key);
  if i >= 0 then Result := Answers.ValueFromIndex[i];
end;

procedure BuildField(pageIdx: Integer; box: PGtkWidget; fo: TJSONObject);
var f: TField; lbl, w, grp: PGtkWidget; opts: TJSONArray; i: Integer; id, txt, v: string; oi: TJSONData;
begin
  FillChar(f, SizeOf(f), 0);
  f.key := fo.Get('key', '');
  f.ftype := fo.Get('type', 'entry');
  f.def := Prefill(f.key, fo.Get('default', ''));
  f.confirmOf := fo.Get('confirm_of', '');
  f.labelText := fo.Get('summary', fo.Get('label', fo.Get('text', f.key)));
  f.pageIdx := pageIdx;
  if fo.Find('show_if') <> nil then f.showIf := TJSONObject(fo.Find('show_if'));
  f.row := gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
  if f.ftype = 'note' then begin
    lbl := MkLabel(fo.Get('text', ''), True);   { markup allowed in notes }
    if fo.Get('dim', False) then AddClass(lbl, 'ck-sub');
    gtk_box_pack_start(f.row, lbl, 0, 0, 0);
    gtk_box_pack_start(box, f.row, 0, 0, 0);
    if f.showIf <> nil then begin SetLength(Fields, Length(Fields) + 1); Fields[High(Fields)] := f; end;
    Exit;
  end;
  if fo.Get('label', '') <> '' then begin
    lbl := MkLabel('<b>' + Esc(fo.Get('label', '')) + '</b>', True);
    gtk_box_pack_start(f.row, lbl, 0, 0, 0);
  end;
  if fo.Get('hint', '') <> '' then begin
    lbl := MkLabel('<span size="small">' + Esc(fo.Get('hint', '')) + '</span>', True); AddClass(lbl, 'ck-sub');
    gtk_box_pack_start(f.row, lbl, 0, 0, 0);
  end;
  case f.ftype of
    'entry', 'password': begin
      w := gtk_entry_new();
      gtk_entry_set_text(w, PChar(f.def));
      if fo.Get('placeholder', '') <> '' then gtk_entry_set_placeholder_text(w, PChar(fo.Get('placeholder', '')));
      if f.ftype = 'password' then begin gtk_entry_set_visibility(w, 0); AddEye(w); end;
      f.widget := w; gtk_box_pack_start(f.row, w, 0, 0, 0);
    end;
    'folder': begin
      w := gtk_file_chooser_button_new(PChar(fo.Get('label', 'Folder')), GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER);
      if f.def <> '' then begin ForceDirectories(f.def); gtk_file_chooser_set_filename(w, PChar(f.def)); end;
      f.widget := w; gtk_box_pack_start(f.row, w, 0, 0, 0);
    end;
    'check': begin
      w := gtk_check_button_new_with_label(PChar(fo.Get('text', fo.Get('label', f.key))));
      gtk_toggle_button_set_active(w, Ord(LowerCase(f.def) = 'y') or Ord(LowerCase(f.def) = 'yes'));
      f.widget := w; gtk_box_pack_start(f.row, w, 0, 0, 0);
    end;
    'radio', 'checklist': begin
      opts := TJSONArray(fo.Find('options')); grp := nil;
      if opts <> nil then begin
        SetLength(f.opts, opts.Count); SetLength(f.optIds, opts.Count); SetLength(f.optTexts, opts.Count);
        for i := 0 to opts.Count - 1 do begin
          oi := opts.Items[i];
          if oi.JSONType = jtArray then begin id := TJSONArray(oi).Items[0].AsString; txt := TJSONArray(oi).Items[1].AsString; end
          else begin id := oi.AsString; txt := id; end;
          if f.ftype = 'radio' then begin w := gtk_radio_button_new_with_label_from_widget(grp, PChar(txt)); grp := w; end
          else w := gtk_check_button_new_with_label(PChar(txt));
          f.opts[i] := w; f.optIds[i] := id; f.optTexts[i] := txt;
          if f.ftype = 'radio' then gtk_toggle_button_set_active(w, Ord(id = f.def))
          else begin v := ' ' + f.def + ' '; gtk_toggle_button_set_active(w, Ord((f.def = 'all') or (Pos(' ' + id + ' ', v) > 0))); end;
          gtk_box_pack_start(f.row, w, 0, 0, 0);
        end;
      end;
    end;
    'select': begin
      w := gtk_combo_box_text_new(); opts := TJSONArray(fo.Find('options'));
      if opts <> nil then begin
        SetLength(f.optIds, opts.Count); SetLength(f.optTexts, opts.Count);
        for i := 0 to opts.Count - 1 do begin
          oi := opts.Items[i];
          if oi.JSONType = jtArray then begin id := TJSONArray(oi).Items[0].AsString; txt := TJSONArray(oi).Items[1].AsString; end
          else begin id := oi.AsString; txt := id; end;
          gtk_combo_box_text_append(w, PChar(id), PChar(txt)); f.optIds[i] := id; f.optTexts[i] := txt;
        end;
      end;
      gtk_combo_box_set_active_id(w, PChar(f.def));
      f.widget := w; gtk_box_pack_start(f.row, w, 0, 0, 0);
    end;
  end;
  gtk_widget_set_margin_bottom(f.row, 6);
  gtk_box_pack_start(box, f.row, 0, 0, 0);
  SetLength(Fields, Length(Fields) + 1); Fields[High(Fields)] := f;
end;

procedure RunWizard(const specFile: string);
var s: TStringList; win, outer, head, hbox, sw, pbox, lbl, btns, img: PGtkWidget;
    pgArr: TJSONArray; i, j: Integer; po: TJSONObject; fldArr: TJSONArray; w, h: Integer;
begin
  s := TStringList.Create;
  try s.LoadFromFile(specFile); Spec := TJSONObject(GetJSON(s.Text)); finally s.Free; end;
  OptTitle := Spec.Get('title', 'Setup');
  if Spec.Get('icon', '') <> '' then OptIcon := Spec.Get('icon', '');
  w := Spec.Get('width', 680); h := Spec.Get('height', 560);
  win := NewWindow(OptTitle, w, h);
  outer := gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_container_add(win, outer);
  { header }
  head := gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
  if (Spec.Get('logo', '') <> '') and FileExists(Spec.Get('logo', '')) then begin
    img := gtk_image_new_from_file(PChar(Spec.Get('logo', ''))); gtk_box_pack_start(head, img, 0, 0, 0);
  end;
  hbox := gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
  lbl := MkLabel(Esc(Spec.Get('heading', OptTitle)), False); AddClass(lbl, 'ck-title');
  gtk_box_pack_start(hbox, lbl, 0, 0, 0);
  if Spec.Get('subheading', '') <> '' then begin
    lbl := MkLabel(Esc(Spec.Get('subheading', '')), True); AddClass(lbl, 'ck-sub'); gtk_box_pack_start(hbox, lbl, 0, 0, 0);
  end;
  gtk_widget_set_hexpand(hbox, 1);
  gtk_box_pack_start(head, hbox, 1, 1, 0);
  WStep := MkLabel('', False); gtk_widget_set_halign(WStep, GTK_ALIGN_END); AddClass(WStep, 'ck-sub');
  gtk_box_pack_end(head, MkThemeButton, 0, 0, 0);
  gtk_box_pack_end(head, WStep, 0, 0, 0);
  gtk_box_pack_start(outer, head, 0, 0, 0);
  gtk_box_pack_start(outer, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, 0, 0);
  { pages }
  WStack := gtk_stack_new();
  gtk_stack_set_transition_type(WStack, GTK_STACK_TRANSITION_TYPE_SLIDE_LEFT_RIGHT);
  gtk_widget_set_vexpand(WStack, 1);
  pgArr := TJSONArray(Spec.Find('pages'));
  if pgArr = nil then begin writeln(stderr, 'ckdialog: spec has no "pages"'); Halt(2); end;
  SetLength(Pages, pgArr.Count);
  for i := 0 to pgArr.Count - 1 do begin
    po := TJSONObject(pgArr.Items[i]);
    Pages[i].id := po.Get('id', 'p' + IntToStr(i));
    Pages[i].title := po.Get('title', '');
    Pages[i].ptype := po.Get('type', 'form');
    if po.Find('show_if') <> nil then Pages[i].showIf := TJSONObject(po.Find('show_if'));
    sw := gtk_scrolled_window_new(nil, nil);
    gtk_scrolled_window_set_policy(sw, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    pbox := gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_container_set_border_width(pbox, 6);
    if Pages[i].title <> '' then begin
      lbl := MkLabel('<span size="large"><b>' + Esc(Pages[i].title) + '</b></span>', True);
      gtk_widget_set_margin_bottom(lbl, 4); gtk_box_pack_start(pbox, lbl, 0, 0, 0);
    end;
    if po.Get('text', '') <> '' then begin
      lbl := MkLabel(po.Get('text', ''), True); gtk_widget_set_margin_bottom(lbl, 8);
      gtk_label_set_selectable(lbl, 0); gtk_box_pack_start(pbox, lbl, 0, 0, 0);
    end;
    if Pages[i].ptype = 'summary' then begin
      Pages[i].summaryLbl := MkLabel('', True); gtk_label_set_selectable(Pages[i].summaryLbl, 1);
      gtk_box_pack_start(pbox, Pages[i].summaryLbl, 0, 0, 0);
    end;
    fldArr := TJSONArray(po.Find('fields'));
    if fldArr <> nil then for j := 0 to fldArr.Count - 1 do BuildField(i, pbox, TJSONObject(fldArr.Items[j]));
    gtk_container_add(sw, pbox);
    Pages[i].box := sw;
    gtk_stack_add_named(WStack, sw, PChar(Pages[i].id));
  end;
  gtk_box_pack_start(outer, WStack, 1, 1, 0);
  { footer }
  WErr := MkLabel('', True);
  gtk_box_pack_start(outer, WErr, 0, 0, 0);
  btns := gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  WCancel := gtk_button_new_with_label('Cancel'); g_signal_connect_data(WCancel, 'clicked', @OnQuitNo, nil, nil, 0);
  gtk_box_pack_start(btns, WCancel, 0, 0, 0);
  WNext := gtk_button_new_with_label('Next  ›'); g_signal_connect_data(WNext, 'clicked', @OnNext, nil, nil, 0);
  gtk_widget_set_size_request(WNext, 110, -1);
  gtk_box_pack_end(btns, WNext, 0, 0, 0);
  WBack := gtk_button_new_with_label('‹  Back'); g_signal_connect_data(WBack, 'clicked', @OnBack, nil, nil, 0);
  gtk_box_pack_end(btns, WBack, 0, 0, 0);
  gtk_box_pack_end(outer, btns, 0, 0, 0);
  g_signal_connect_data(win, 'delete-event', @OnDeleteNo, nil, nil, 0);
  gtk_widget_show_all(win);
  GotoPage(0, True);
  gtk_main;
end;

{ ── main ─────────────────────────────────────────────────────────────────── }
var
  mode: string = '';
  specFile, entryDefault, answersFile: string;
  hideText: Boolean = False;
  i: Integer;
begin
  entryDefault := ''; answersFile := ''; specFile := '';
  i := 1;
  while i <= ParamCount do begin
    case ParamStr(i) of
      '--wizard':     begin mode := 'wizard'; Inc(i); specFile := ParamStr(i); end;
      '--progress':   mode := 'progress';
      '--askpass':    begin mode := 'askpass'; if (i < ParamCount) and (Copy(ParamStr(i + 1), 1, 2) <> '--') then begin Inc(i); OptText := ParamStr(i); end; end;
      '--question', '--info', '--error', '--warning', '--entry': mode := Copy(ParamStr(i), 3, MaxInt);
      '--check':      mode := 'check';
      '--title':      begin Inc(i); OptTitle := ParamStr(i); end;
      '--text':       begin Inc(i); OptText := ParamStr(i); end;
      '--icon':       begin Inc(i); OptIcon := ParamStr(i); end;
      '--entry-text': begin Inc(i); entryDefault := ParamStr(i); end;
      '--hide-text':  hideText := True;
      '--total':      begin Inc(i); PTotal := StrToIntDef(ParamStr(i), 0); end;
      '--auto-close': PAutoClose := True;
      '--phase-match': begin Inc(i); PPhaseMatch := ParamStr(i); end;
      '--dark':       ThemeForced := 1;
      '--light':      ThemeForced := 0;
      '--answers':    begin Inc(i); answersFile := ParamStr(i); end;
      '--out':        begin Inc(i); OutFile := ParamStr(i); end;
      '--version':    begin writeln('ckdialog ', VERSION); Halt(0); end;
      '--help', '-h': begin writeln('ckdialog ', VERSION, ' — see the header of ckdialog.pas / README.md'); Halt(0); end;
    else
      writeln(stderr, 'ckdialog: unknown option ', ParamStr(i)); Halt(2);
    end;
    Inc(i);
  end;
  if mode = '' then begin writeln(stderr, 'ckdialog: no mode (--wizard SPEC | --progress | --askpass | --question | --entry | --info | --error | --check)'); Halt(2); end;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  { JSON and GTK speak UTF-8; without this a non-UTF-8 locale (or none, as under
    Xvfb) turned "—" into "?" on the way through AnsiString }
  SetMultiByteConversionCodePage(CP_UTF8); SetMultiByteRTLFileSystemCodePage(CP_UTF8); DefaultSystemCodePage := CP_UTF8;
  if (GetEnvironmentVariable('DISPLAY') = '') and (GetEnvironmentVariable('WAYLAND_DISPLAY') = '') then begin
    if mode <> 'check' then writeln(stderr, 'ckdialog: no display');
    Halt(4);
  end;
  if not LoadBindings(mode = 'check') then Halt(3);
  if mode = 'check' then Halt(0);
  g_set_prgname('ckdialog');
  gtk_init(nil, nil);
  InstallCss;
  if ThemeForced >= 0 then Dark := ThemeForced = 1
  else if not LoadThemeChoice(Dark) then Dark := DesktopPrefersDark;
  ApplyTheme;
  if OptIcon = '' then OptIcon := 'system-software-install';
  if answersFile <> '' then begin Answers := TStringList.Create; if FileExists(answersFile) then Answers.LoadFromFile(answersFile); end;
  case mode of
    'wizard':   RunWizard(specFile);
    'progress': RunProgress;
    'askpass':  begin if OptText = '' then OptText := 'Password:'; if OptTitle = '' then OptTitle := 'Authentication'; RunSimple('askpass', '', True); end;
    'entry':    RunSimple('entry', entryDefault, hideText);
  else          RunSimple(mode, '', False);
  end;
  Halt(ExitCode);
end.
