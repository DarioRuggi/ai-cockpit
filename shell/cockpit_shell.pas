{
  cockpit_shell — native window for AI Cockpit (GTK 3 + WebKitGTK 4.1).

  Copyright 2026 Dario Ruggi / Ruggi Software — https://ruggi.site
  Licensed under the Apache License, Version 2.0 (see ../LICENSE.md, ../NOTICE).

  Why a shell instead of a browser --app window: the window manager's close
  button, Alt+F4 and the dock's "Quit" all bypass a web page. This program owns
  the window, so every close request is routed to the app's own exit procedure
  (the "Leaving Cockpit" modal); the window only closes when the page says so.

  Protocol with the page (index.html):
    shell → page   on close request:   runs JS  window.cockpitShellClose()
    page  → shell  to really quit:     sets     document.title = '__COCKPIT_QUIT__'
    page detects the shell by the user agent suffix "AICockpitShell/<ver>".

  Usage:
    cockpit_shell --url URL [--title T] [--icon PNG] [--splash FILE --ready FILE]
                  [--width W --height H] [--devtools] [--check] [--kiosk] [--frameless] [--verify DIR] [--hotkey ctrl+alt+c] [--start CMD]
      --splash/--ready : show FILE first; switch to URL once the ready file
                         exists (the start script touches it when the app is up).

  Build:  fpc -O2 -Xs -XX cockpit_shell.pas     (needs only the runtime libs:
          libgtk-3.so.0, libwebkit2gtk-4.1.so.0, libgobject/libglib 2.0)
}
program cockpit_shell;
{$mode objfpc}{$H+}{$PACKRECORDS C}
uses ctypes, sysutils, classes, strutils, baseunix, unix, dynlibs, math, process, fpjson, jsonparser;

const
  SHELL_VERSION = '1.0';
  QUIT_SENTINEL = '__COCKPIT_QUIT__';
  GTK  = 'libgtk-3.so.0';
  GOBJ = 'libgobject-2.0.so.0';
  GLIB = 'libglib-2.0.so.0';
  WK   = 'libwebkit2gtk-4.1.so.0';
  JSC  = 'libjavascriptcoregtk-4.1.so.0';

  GTK_WINDOW_TOPLEVEL = 0;
  GDK_KEY_F5  = $FFC2;
  GDK_KEY_F11 = $FFC8;
  GDK_KEY_Left = $FF51; GDK_KEY_Right = $FF53; GDK_MOD1_MASK = 8;
  GDK_CONTROL_MASK = 4;
  GDK_SHIFT_MASK = 1;
  WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION = 0;
  WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION = 1;

type
  gboolean = cint;
  PGtkWidget = Pointer;
  PGObject = Pointer;
  { GdkEventKey, first fields only — enough to read state + keyval }
  TGdkEventKey = record
    etype: cint;
    window: Pointer;
    send_event: cint8;
    time: cuint32;
    state: cuint;
    keyval: cuint;
  end;
  PGdkEventKey = ^TGdkEventKey;


{ ── bindings, loaded at run time (no -dev packages needed to build or run) ── }
type
  T_gtk_init = procedure(argc: pcint; argv: PPPChar); cdecl;
  T_gtk_window_new = function(t: cint): PGtkWidget; cdecl;
  T_gtk_window_set_title = procedure(w: PGtkWidget; t: PChar); cdecl;
  T_gtk_window_set_default_size = procedure(w: PGtkWidget; x, y: cint); cdecl;
  T_gtk_window_maximize = procedure(w: PGtkWidget); cdecl;
  T_gtk_window_fullscreen = procedure(w: PGtkWidget); cdecl;
  T_gtk_window_unfullscreen = procedure(w: PGtkWidget); cdecl;
  T_gtk_window_set_icon_from_file = function(w: PGtkWidget; f: PChar; err: PPointer): gboolean; cdecl;
  T_gtk_container_add = procedure(c, w: PGtkWidget); cdecl;
  T_gtk_widget_show_all = procedure(w: PGtkWidget); cdecl;
  T_gtk_widget_grab_focus = procedure(w: PGtkWidget); cdecl;
  T_gtk_main = procedure; cdecl;
  T_gtk_main_quit = procedure; cdecl;
  T_g_set_prgname = procedure(n: PChar); cdecl;
  T_g_timeout_add = function(ms: cuint; func: Pointer; data: Pointer): cuint; cdecl;
  T_g_signal_connect_data = function(inst: PGObject; sig: PChar; handler: Pointer; data: Pointer;
            destroy: Pointer; flags: cint): culong; cdecl;
  T_webkit_web_view_new = function: PGtkWidget; cdecl;
  T_webkit_web_view_load_uri = procedure(v: PGtkWidget; uri: PChar); cdecl;
  T_webkit_web_view_reload = procedure(v: PGtkWidget); cdecl;
  T_webkit_web_view_go_back = procedure(v: PGtkWidget); cdecl;
  T_webkit_web_view_go_forward = procedure(v: PGtkWidget); cdecl;
  T_webkit_web_view_get_uri = function(v: PGtkWidget): PChar; cdecl;
  T_webkit_web_view_stop_loading = procedure(v: PGtkWidget); cdecl;
  T_webkit_web_view_reload_bypass_cache = procedure(v: PGtkWidget); cdecl;
  T_webkit_web_view_get_title = function(v: PGtkWidget): PChar; cdecl;
  T_webkit_web_view_get_settings = function(v: PGtkWidget): PGObject; cdecl;
  T_webkit_web_view_run_javascript = procedure(v: PGtkWidget; script: PChar; cancellable, cb, data: Pointer); cdecl;
  T_webkit_settings_set_user_agent_with_application_details = procedure(s: PGObject; app, ver: PChar); cdecl;
  T_webkit_settings_set_enable_developer_extras = procedure(s: PGObject; b: gboolean); cdecl;
  T_webkit_settings_set_javascript_can_open_windows_automatically = procedure(s: PGObject; b: gboolean); cdecl;
  T_webkit_settings_set_enable_media_stream = procedure(s: PGObject; b: gboolean); cdecl;
  T_webkit_settings_set_hardware_acceleration_policy = procedure(s: PGObject; p: cint); cdecl;
  T_webkit_policy_decision_ignore = function(d: PGObject): gboolean; cdecl;
  T_webkit_navigation_policy_decision_get_navigation_action = function(d: PGObject): PGObject; cdecl;
  T_webkit_navigation_action_get_request = function(a: PGObject): PGObject; cdecl;
  T_webkit_uri_request_get_uri = function(r: PGObject): PChar; cdecl;
  T_webkit_permission_request_allow = procedure(r: PGObject); cdecl;
  T_webkit_permission_request_deny  = procedure(r: PGObject); cdecl;
  T_g_type_name_from_instance      = function(i: PGObject): PChar; cdecl;
  T_webkit_user_media_permission_is_for_audio_device = function(r: PGObject): gboolean; cdecl;
  T_webkit_user_media_permission_is_for_video_device = function(r: PGObject): gboolean; cdecl;
  T_webkit_user_content_manager_new = function: PGObject; cdecl;
  T_webkit_user_content_manager_register_script_message_handler = function(m: PGObject; name: PChar): gboolean; cdecl;
  T_webkit_web_view_new_with_user_content_manager = function(m: PGObject): PGtkWidget; cdecl;
  T_webkit_javascript_result_get_js_value = function(r: PGObject): PGObject; cdecl;
  T_jsc_value_to_string = function(v: PGObject): PChar; cdecl;
  T_g_free = procedure(p: Pointer); cdecl;
  T_webkit_web_context_get_default = function: PGObject; cdecl;
  T_webkit_web_context_get_cookie_manager = function(c: PGObject): PGObject; cdecl;
  T_webkit_cookie_manager_set_persistent_storage = procedure(m: PGObject; f: PChar; storage: cint); cdecl;

var
  gtk_init: T_gtk_init;
  gtk_window_new: T_gtk_window_new;
  gtk_window_set_title: T_gtk_window_set_title;
  gtk_window_set_default_size: T_gtk_window_set_default_size;
  gtk_window_maximize: T_gtk_window_maximize;
  gtk_window_fullscreen: T_gtk_window_fullscreen;
  gtk_window_unfullscreen: T_gtk_window_unfullscreen;
  gtk_window_set_icon_from_file: T_gtk_window_set_icon_from_file;
  gtk_container_add: T_gtk_container_add;
  gtk_widget_show_all: T_gtk_widget_show_all;
  gtk_widget_grab_focus: T_gtk_widget_grab_focus;
  gtk_main: T_gtk_main;
  gtk_main_quit: T_gtk_main_quit;
  gtk_settings_get_default: function: Pointer; cdecl;
  gtk_settings_set_long_property: procedure(s: Pointer; name: PChar; v: clong; origin: PChar); cdecl;
  g_set_prgname: T_g_set_prgname;
  g_timeout_add: T_g_timeout_add;
  g_signal_connect_data: T_g_signal_connect_data;
  webkit_web_view_new: T_webkit_web_view_new;
  webkit_web_view_load_uri: T_webkit_web_view_load_uri;
  webkit_web_view_reload: T_webkit_web_view_reload;
  webkit_web_view_go_back: T_webkit_web_view_go_back;
  webkit_web_view_go_forward: T_webkit_web_view_go_forward;
  webkit_web_view_get_uri: T_webkit_web_view_get_uri;
  webkit_web_view_stop_loading: T_webkit_web_view_stop_loading;
  webkit_web_view_reload_bypass_cache: T_webkit_web_view_reload_bypass_cache;
  webkit_web_view_get_title: T_webkit_web_view_get_title;
  webkit_web_view_get_settings: T_webkit_web_view_get_settings;
  webkit_web_view_run_javascript: T_webkit_web_view_run_javascript;
  webkit_settings_set_user_agent_with_application_details: T_webkit_settings_set_user_agent_with_application_details;
  webkit_settings_set_enable_developer_extras: T_webkit_settings_set_enable_developer_extras;
  webkit_settings_set_javascript_can_open_windows_automatically: T_webkit_settings_set_javascript_can_open_windows_automatically;
  webkit_settings_set_enable_media_stream: T_webkit_settings_set_enable_media_stream;
  webkit_settings_set_hardware_acceleration_policy: T_webkit_settings_set_hardware_acceleration_policy;
  webkit_policy_decision_ignore: T_webkit_policy_decision_ignore;
  webkit_navigation_policy_decision_get_navigation_action: T_webkit_navigation_policy_decision_get_navigation_action;
  webkit_navigation_action_get_request: T_webkit_navigation_action_get_request;
  webkit_uri_request_get_uri: T_webkit_uri_request_get_uri;
  webkit_permission_request_allow: T_webkit_permission_request_allow;
  webkit_permission_request_deny:  T_webkit_permission_request_deny;
  g_type_name_from_instance:       T_g_type_name_from_instance;
  webkit_user_media_permission_is_for_audio_device: T_webkit_user_media_permission_is_for_audio_device;
  webkit_user_media_permission_is_for_video_device: T_webkit_user_media_permission_is_for_video_device;
  webkit_user_content_manager_new: T_webkit_user_content_manager_new;
  webkit_user_content_manager_register_script_message_handler: T_webkit_user_content_manager_register_script_message_handler;
  webkit_web_view_new_with_user_content_manager: T_webkit_web_view_new_with_user_content_manager;
  webkit_javascript_result_get_js_value: T_webkit_javascript_result_get_js_value;
  jsc_value_to_string: T_jsc_value_to_string;
  g_free: T_g_free;
  webkit_web_context_get_default: T_webkit_web_context_get_default;
  webkit_web_context_get_cookie_manager: T_webkit_web_context_get_cookie_manager;
  webkit_cookie_manager_set_persistent_storage: T_webkit_cookie_manager_set_persistent_storage;

procedure Bind(lib: TLibHandle; const libname, name: string; var p);
begin
  Pointer(p) := GetProcAddress(lib, name);
  if Pointer(p) = nil then begin writeln(stderr, 'cockpit_shell: missing symbol ', name, ' in ', libname); Halt(3); end;
end;

procedure LoadBindings;
var h: TLibHandle;
  procedure Open(const libname: string);
  begin
    h := LoadLibrary(libname);
    if h = NilHandle then begin writeln(stderr, 'cockpit_shell: cannot load ', libname, ' (install the GTK 3 / WebKitGTK 4.1 runtime)'); Halt(3); end;
  end;
begin
  Open(GTK);
  Bind(h, GTK, 'gtk_init', gtk_init);
  Bind(h, GTK, 'gtk_window_new', gtk_window_new);
  Bind(h, GTK, 'gtk_window_set_title', gtk_window_set_title);
  Bind(h, GTK, 'gtk_window_set_default_size', gtk_window_set_default_size);
  Bind(h, GTK, 'gtk_window_maximize', gtk_window_maximize);
  Bind(h, GTK, 'gtk_window_fullscreen', gtk_window_fullscreen);
  Bind(h, GTK, 'gtk_window_unfullscreen', gtk_window_unfullscreen);
  Bind(h, GTK, 'gtk_window_set_icon_from_file', gtk_window_set_icon_from_file);
  Bind(h, GTK, 'gtk_container_add', gtk_container_add);
  Bind(h, GTK, 'gtk_widget_show_all', gtk_widget_show_all);
  Bind(h, GTK, 'gtk_widget_grab_focus', gtk_widget_grab_focus);
  Bind(h, GTK, 'gtk_main', gtk_main);
  Bind(h, GTK, 'gtk_main_quit', gtk_main_quit);
  Bind(h, GTK, 'gtk_settings_get_default', gtk_settings_get_default);
  Bind(h, GTK, 'gtk_settings_set_long_property', gtk_settings_set_long_property);
  Open(GLIB);
  Bind(h, GLIB, 'g_set_prgname', g_set_prgname);
  Bind(h, GLIB, 'g_timeout_add', g_timeout_add);
  Open(GOBJ);
  Bind(h, GOBJ, 'g_signal_connect_data', g_signal_connect_data);
  Open(WK);
  Bind(h, WK, 'webkit_web_view_new', webkit_web_view_new);
  Bind(h, WK, 'webkit_web_view_load_uri', webkit_web_view_load_uri);
  Bind(h, WK, 'webkit_web_view_reload', webkit_web_view_reload);
  Bind(h, WK, 'webkit_web_view_go_back', webkit_web_view_go_back);
  Bind(h, WK, 'webkit_web_view_go_forward', webkit_web_view_go_forward);
  Bind(h, WK, 'webkit_web_view_get_uri', webkit_web_view_get_uri);
  Bind(h, WK, 'webkit_web_view_stop_loading', webkit_web_view_stop_loading);
  Bind(h, WK, 'webkit_web_view_reload_bypass_cache', webkit_web_view_reload_bypass_cache);
  Bind(h, WK, 'webkit_web_view_get_title', webkit_web_view_get_title);
  Bind(h, WK, 'webkit_web_view_get_settings', webkit_web_view_get_settings);
  Bind(h, WK, 'webkit_web_view_run_javascript', webkit_web_view_run_javascript);
  Bind(h, WK, 'webkit_settings_set_user_agent_with_application_details', webkit_settings_set_user_agent_with_application_details);
  Bind(h, WK, 'webkit_settings_set_enable_developer_extras', webkit_settings_set_enable_developer_extras);
  Bind(h, WK, 'webkit_settings_set_javascript_can_open_windows_automatically', webkit_settings_set_javascript_can_open_windows_automatically);
  Bind(h, WK, 'webkit_settings_set_enable_media_stream', webkit_settings_set_enable_media_stream);
  Bind(h, WK, 'webkit_settings_set_hardware_acceleration_policy', webkit_settings_set_hardware_acceleration_policy);
  Bind(h, WK, 'webkit_policy_decision_ignore', webkit_policy_decision_ignore);
  Bind(h, WK, 'webkit_navigation_policy_decision_get_navigation_action', webkit_navigation_policy_decision_get_navigation_action);
  Bind(h, WK, 'webkit_navigation_action_get_request', webkit_navigation_action_get_request);
  Bind(h, WK, 'webkit_uri_request_get_uri', webkit_uri_request_get_uri);
  Bind(h, WK, 'webkit_permission_request_allow', webkit_permission_request_allow);
  Bind(h, WK, 'webkit_permission_request_deny', webkit_permission_request_deny);
  Bind(h, GOBJ, 'g_type_name_from_instance', g_type_name_from_instance);
  Bind(h, WK, 'webkit_user_media_permission_is_for_audio_device', webkit_user_media_permission_is_for_audio_device);
  Bind(h, WK, 'webkit_user_media_permission_is_for_video_device', webkit_user_media_permission_is_for_video_device);
  Bind(h, WK, 'webkit_user_content_manager_new', webkit_user_content_manager_new);
  Bind(h, WK, 'webkit_user_content_manager_register_script_message_handler', webkit_user_content_manager_register_script_message_handler);
  Bind(h, WK, 'webkit_web_view_new_with_user_content_manager', webkit_web_view_new_with_user_content_manager);
  Bind(h, WK, 'webkit_javascript_result_get_js_value', webkit_javascript_result_get_js_value);
  Bind(h, WK, 'webkit_web_context_get_default', webkit_web_context_get_default);
  Bind(h, WK, 'webkit_web_context_get_cookie_manager', webkit_web_context_get_cookie_manager);
  Bind(h, WK, 'webkit_cookie_manager_set_persistent_storage', webkit_cookie_manager_set_persistent_storage);
  Open(JSC);
  Bind(h, JSC, 'jsc_value_to_string', jsc_value_to_string);
  Open(GLIB);
  Bind(h, GLIB, 'g_free', g_free);
end;

var
  Win, View: PGtkWidget;
  UCM: PGObject;
  BwSession: string = '';        { Bitwarden CLI session token — memory only }
  BwPendingReq: TJSONObject = nil; { request waiting for an unlock }
  BwUnlockFile: string = '';
  BwUnlockPolls: Integer = 0;
  OptUrl, OptTitle, OptIcon, OptSplash, OptReady: string;
  OptW: cint = 1600; OptH: cint = 1000;
  OptDevTools: Boolean = False;
  OptCheck: Boolean = False;      { --check: load the libraries and exit 0 }
  OptEval: string = '';          { --eval JS: run once the app page loaded (testing) }
  OptKiosk: Boolean = False;      { --kiosk: fullscreen, undecorated, no F11 }
  OptBrowser: Boolean = False;    { --browser: a plain web window — links navigate in place, no tray/hotkey/verify/exit dialog }
  OptVerify: string = '';        { --verify DIR: check the manifest before loading }
  OptHotkey: string = '';        { --hotkey ctrl+alt+c | none }
  OptStart: string = '';         { --start CMD: bring Cockpit up when the URL is dead }
  OptStartTimeout: Integer = 90;  { --start-timeout seconds }
  PageLoaded: Boolean = False;    { the app page finished loading at least once }
  AppShown: Boolean = False;      { URL (not the splash) is what the view shows }
  IsFullscreen: Boolean = False;
  CloseRequests: Integer = 0;

procedure QuitApp; forward;
procedure RegWrite; forward;
var RegFile: string = ''; RegLast: string = '';   { this Browser window's line in the window list (see the window list block) }
procedure WorkerHide; forward;
procedure WorkerLoaded(v: PGtkWidget); forward;
var WorkerShown: Boolean = False;   { the worker's page is in an on-screen window (for a login) and not behind the screen }
var ViewHost: PGtkWidget = nil;   { what the page is parented to: nil = the window itself, or the overlay that carries the border strips }
var OptWorker: string = '';   { --worker DIR: a hidden page driven through files in DIR (see the web worker block) }
function UrlAnswers(const url: string): Boolean; forward;
procedure BootPage(const status: string; retry: Boolean); forward;

procedure Log(const s: string);
begin
  writeln(stderr, FormatDateTime('hh:nn:ss', Now), ' cockpit_shell: ', s); Flush(stderr);
end;

{ Hand a URL to the desktop (external links, window.open targets). }
{ Is any web browser installed? A bare Arch/MATE VM had none: xdg-open then
  handed http links to the text editor (pluma). Better to say so. }
function HaveBrowser: Boolean;
const B: array[0..9] of string = ('firefox', 'brave-browser', 'brave', 'chromium', 'chromium-browser',
  'google-chrome', 'google-chrome-stable', 'vivaldi-stable', 'microsoft-edge', 'epiphany');
var i: Integer; d: string;
begin
  for i := 0 to High(B) do for d in ['/usr/bin/', '/usr/local/bin/', '/opt/', '/snap/bin/'] do
    if FileExists(d + B[i]) then Exit(True);
  Result := FileExists('/var/lib/flatpak/exports/bin/org.mozilla.firefox');
end;

procedure OpenExternal(const uri: string);
begin
  if uri = '' then Exit;
  if ((Pos('http://', uri) = 1) or (Pos('https://', uri) = 1)) and not HaveBrowser then begin
    Log('external: no web browser installed — ' + uri);
    if View <> nil then webkit_web_view_run_javascript(View, PChar('if (window.appendSystem) appendSystem("No web browser is installed on this machine — install one (Firefox, Brave, Chromium…) to open links outside Cockpit.");'), nil, nil, nil);
    Exit;
  end;
  Log('external: ' + uri);
  fpSystem('xdg-open ' + QuotedStr(uri) + ' >/dev/null 2>&1 &');
end;

function IsAppOrigin(const uri: string): Boolean;
begin
  { the app itself, its splash file, and anything local }
  Result := (Pos('http://localhost', uri) = 1) or (Pos('http://127.0.0.1', uri) = 1)
         or (Pos('file://', uri) = 1) or (Pos('about:', uri) = 1);
end;

{ Third parties the app embeds in an iframe and that must load IN the view:
  a sub-frame navigation goes through decide-policy exactly like a click, and
  sending it to the desktop browser leaves the frame empty. Seen with the
  account form's Cloudflare Turnstile ("human verification"): the challenge
  opened in Firefox as a blank page and nobody could register from the window. }
function IsEmbeddedThirdParty(const uri: string): Boolean;
var host: string; p: Integer;
begin
  Result := False;
  if Pos('https://', uri) <> 1 then Exit;
  host := Copy(uri, 9, MaxInt); p := Pos('/', host); if p > 0 then host := Copy(host, 1, p - 1);
  Result := (host = 'challenges.cloudflare.com') or (host = 'static.cloudflareinsights.com');
end;

{ ── signal handlers (cdecl, GLib calling convention) ─────────────────────── }

{ Close request from the WM (X button, Alt+F4, dock Quit): ask the page, veto.
  If the page never loaded (server down, splash still up) there is nothing to
  ask — just quit. }
function OnDelete(w: PGtkWidget; ev: Pointer; data: Pointer): gboolean; cdecl;
begin
  Inc(CloseRequests);
  if OptWorker <> '' then begin WorkerHide; Exit(1); end;   { closing a worker's window only puts it away }
  if OptBrowser then begin QuitApp; Exit(0); end;   { a browser window just closes }
  if (not PageLoaded) or (not AppShown) then begin
    Log('close: page not up, quitting');
    QuitApp;
    Exit(0);
  end;
  Log('close request -> page');
  webkit_web_view_run_javascript(View,
    'if (window.cockpitShellClose) { window.cockpitShellClose(); } else { document.title = "' + QUIT_SENTINEL + '"; }',
    nil, nil, nil);
  Result := 1;   { TRUE = we handled it; do not destroy the window }
end;

{ The page quits by setting its title to the sentinel. }
procedure OnTitle(obj: PGObject; pspec: Pointer; data: Pointer); cdecl;
var t: PChar;
begin
  t := webkit_web_view_get_title(View);
  if (t <> nil) and (Pos('__COCKPIT_LOG__:', StrPas(t)) = 1) then Log('page: ' + Copy(StrPas(t), 17, 4000));
  if OptBrowser and (t <> nil) and (StrPas(t) <> '') then gtk_window_set_title(Win, PChar(StrPas(t) + ' — Cockpit Browser'));
  if (t <> nil) and (StrPas(t) = QUIT_SENTINEL) then begin
    Log('page asked to quit');
    QuitApp;
  end;
end;

{ load-changed: WEBKIT_LOAD_FINISHED = 3 }
procedure OnLoadChanged(v: PGtkWidget; event: cint; data: Pointer); cdecl;
var u: PChar;
begin
  { WEBKIT_LOAD_STARTED = 0: a file dropped outside a drop target starts a
    file:// load that never passes decide-policy — stop it here, the app page
    stays; the page opens the file in its own editor from the drop paths. }
  if (event = 0) and AppShown then begin
    u := webkit_web_view_get_uri(v);
    if (u <> nil) and (Pos('file://', StrPas(u)) = 1) then begin webkit_web_view_stop_loading(v); Log('stopped file:// load'); Exit; end;
  end;
  if (event = 3) and (OptWorker <> '') then WorkerLoaded(v);
  if (event = 3) and AppShown then begin
    PageLoaded := True;
    if OptEval <> '' then begin webkit_web_view_run_javascript(View, PChar(OptEval), nil, nil, nil); OptEval := ''; end;
  end;
end;

function OnLoadFailed(v: PGtkWidget; event: cint; uri: PChar; err: Pointer; data: Pointer): gboolean; cdecl;
begin
  Log('load failed: ' + StrPas(uri));
  PageLoaded := False;
  Result := 0;
end;

{ decide-policy: keep the app inside; everything else goes to the desktop browser. }
function OnDecidePolicy(v: PGtkWidget; decision: PGObject; dtype: cint; data: Pointer): gboolean; cdecl;
var act, req: PGObject; uri: string;
begin
  Result := 0;
  if (dtype <> WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) and
     (dtype <> WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) then Exit;
  act := webkit_navigation_policy_decision_get_navigation_action(decision);
  req := webkit_navigation_action_get_request(act);
  uri := StrPas(webkit_uri_request_get_uri(req));
  { A file dropped outside a drop target would navigate the view to file:// —
    the default browser behaviour — and replace the app. Never, once the app is up. }
  if AppShown and (Pos('file://', uri) = 1) then begin
    webkit_policy_decision_ignore(decision); Log('blocked file:// navigation'); Exit(1);
  end;
  if (dtype = WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) and IsEmbeddedThirdParty(uri) then Exit;
  { browser mode: everything navigates in this window; a target=_blank link too }
  if OptBrowser then begin
    if dtype = WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION then begin webkit_policy_decision_ignore(decision); webkit_web_view_load_uri(View, PChar(uri)); Exit(1); end;
    Exit;
  end;
  if (dtype = WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) or (not IsAppOrigin(uri)) then begin
    webkit_policy_decision_ignore(decision);
    OpenExternal(uri);
    Result := 1;
  end;
end;

{ create: window.open() — open outside, never a second shell window. }
function OnCreate(v: PGtkWidget; action: PGObject; data: Pointer): PGtkWidget; cdecl;
var req: PGObject;
begin
  req := webkit_navigation_action_get_request(action);
  OpenExternal(StrPas(webkit_uri_request_get_uri(req)));
  Result := nil;
end;

{ permission-request.

  This used to allow EVERYTHING unconditionally. For the app window that is
  merely generous — it only ever loads local Cockpit — but --browser mode loads
  whatever site you point it at, and there an unconditional allow hands any page
  the microphone, the camera and your location with no prompt and no indication.

  So: grant only what Cockpit's own features actually use, and only in the app
  window. Anything else, and anything at all in browser mode, is denied. A denial
  is a normal, expected answer to these APIs — the page gets a rejected promise,
  exactly as if a user had clicked "block".

  Deliberately NOT granted anywhere: geolocation, camera (Cockpit has no feature
  that needs either). Note that ONE WebKitUserMediaPermissionRequest covers both
  the microphone and the camera — allowing the type outright also hands over the
  webcam, which a first cut of this handler did (measured: video=GRANTED). So a
  media request is granted only when it asks for audio and NOT video. }
function OnPermission(v: PGtkWidget; req: PGObject; data: Pointer): gboolean; cdecl;
var
  TypeName: string;
  Granted: Boolean;
begin
  TypeName := '';
  if Assigned(g_type_name_from_instance) then TypeName := string(g_type_name_from_instance(req));

  Granted := False;
  if not OptBrowser then
  begin
    { Voice input (getUserMedia AUDIO only) and the away/finished notifications. }
    if TypeName = 'WebKitUserMediaPermissionRequest' then
    begin
      { Both predicates must be bound to make this judgement; if they are not,
        we cannot tell a microphone request from a camera one, and the safe
        reading of an unknown request is no. }
      Granted := Assigned(webkit_user_media_permission_is_for_audio_device)
             and Assigned(webkit_user_media_permission_is_for_video_device)
             and (webkit_user_media_permission_is_for_audio_device(req) <> 0)
             and (webkit_user_media_permission_is_for_video_device(req) = 0);
    end
    else if (TypeName = 'WebKitNotificationPermissionRequest')
         or (TypeName = 'WebKitPointerLockPermissionRequest') then
      Granted := True;
  end;

  { An unknown type name (older/newer WebKit, or the symbol missing) is not a
    reason to say yes — it is exactly when we cannot tell what we are granting. }
  if Granted and Assigned(webkit_permission_request_allow) then
    webkit_permission_request_allow(req)
  else if Assigned(webkit_permission_request_deny) then
    webkit_permission_request_deny(req)
  else
    Exit(0);   { no deny symbol bound: let WebKit apply its own default }

  if not Granted then
    Log('permission denied: ' + TypeName + BoolToStr(OptBrowser, ' (browser mode)', ''));
  Result := 1;
end;

{ F11 fullscreen; F5 / Ctrl+R reload; Ctrl+Shift+R / Ctrl+F5 reload bypassing the cache. }
function OnKey(w: PGtkWidget; ev: PGdkEventKey; data: Pointer): gboolean; cdecl;
var ctrl, shift, keyR: Boolean;
begin
  Result := 0;
  ctrl := (ev^.state and GDK_CONTROL_MASK) <> 0; shift := (ev^.state and GDK_SHIFT_MASK) <> 0;
  keyR := (ev^.keyval = Ord('r')) or (ev^.keyval = Ord('R'));
  if (ctrl and shift and keyR) or (ctrl and (ev^.keyval = GDK_KEY_F5)) then begin
    Log('hard reload'); webkit_web_view_reload_bypass_cache(View); Exit(1);
  end;
  { browser mode: Ctrl+W closes the window (a frameless one has no close button); a web worker's window is only put away }
  if OptBrowser and ctrl and ((ev^.keyval = Ord('w')) or (ev^.keyval = Ord('W'))) then begin if OptWorker <> '' then WorkerHide else QuitApp; Exit(1); end;
  { browser mode: Alt+Left / Alt+Right history, like any browser }
  if OptBrowser and ((ev^.state and GDK_MOD1_MASK) <> 0) then begin
    if ev^.keyval = GDK_KEY_Left then begin webkit_web_view_go_back(View); Exit(1); end;
    if ev^.keyval = GDK_KEY_Right then begin webkit_web_view_go_forward(View); Exit(1); end;
  end;
  if (ev^.keyval = GDK_KEY_F11) and not OptKiosk then begin
    if IsFullscreen then gtk_window_unfullscreen(Win) else gtk_window_fullscreen(Win);
    IsFullscreen := not IsFullscreen;
    Exit(1);
  end;
  if (ev^.keyval = GDK_KEY_F5) or
     (((ev^.state and GDK_CONTROL_MASK) <> 0) and ((ev^.keyval = Ord('r')) or (ev^.keyval = Ord('R')))) then begin
    webkit_web_view_reload(View);
    Exit(1);
  end;
end;

{ Splash → app once the ready file appears (polled every 300 ms). }
var ReadyTries: Integer = 0;
function OnReadyPoll(data: Pointer): gboolean; cdecl;
begin
  if AppShown then Exit(0);
  Inc(ReadyTries);
  { The start script normally touches the ready file. If it died (or the web
    server never came up) the splash would sit there forever — after the
    timeout, load the app when the URL answers, else say what happened. }
  if ReadyTries > OptStartTimeout * 3 then begin
    if UrlAnswers(OptUrl) then begin AppShown := True; webkit_web_view_load_uri(View, PChar(OptUrl)); end
    else BootPage('Cockpit did not finish starting. Run <code>cockpit-start</code> in a terminal to see why.', True);
    Exit(0);
  end;
  if (OptReady = '') or FileExists(OptReady) then begin
    Log('app ready, loading ' + OptUrl);
    AppShown := True;
    webkit_web_view_load_uri(View, PChar(OptUrl));
    Exit(0);   { stop the timer }
  end;
  Result := 1;
end;

{ ── page ↔ shell messages ─────────────────────────────────────────────────
  Page → shell:  window.webkit.messageHandlers.cockpit.postMessage(JSON string)
  Shell → page:  window.cockpitShellReply(JSON)   (carries the request's "id")

  Commands: {"cmd":"quit"}
            {"cmd":"bw_status"}                    → installed, unlocked
            {"cmd":"bw_search","q":"AI Cockpit"}   → items [{id,name,username}]
            {"cmd":"bw_get","item":"<id>"}         → username, password

  Bitwarden CLI (bw) is the only credential source. The master password is
  typed into bw itself, in a terminal this shell opens — never into Cockpit.
  The session token lives in this process and dies with it; the only file
  involved is the 0600 hand-off for the token, deleted the moment it is read. }

{ ── window geometry, kiosk, pre-load integrity check ───────────────────────
  Geometry: size/maximised state are remembered per user under
  $XDG_CONFIG_HOME/ai-cockpit/window.json (never the position — the WM places
  the window, and a saved position lands wrong on a changed monitor set).
  --kiosk: fullscreen, undecorated, no F11 toggle (for a dedicated screen).
  Integrity: with --verify DIR the shell hashes the files integrity.json lists
  BEFORE the page loads; index.html or another shipped file changed → the page
  is not loaded at all and the window says so. This is the check the page
  cannot do for itself (a tampered page can lie about its own manifest). }
type
  T_gtk_window_get_size = procedure(w: PGtkWidget; x, y: pcint); cdecl;
  T_gtk_window_is_maximized = function(w: PGtkWidget): gboolean; cdecl;
  T_gtk_window_get_position = procedure(w: PGtkWidget; x, y: pcint); cdecl;
  T_gtk_window_move = procedure(w: PGtkWidget; x, y: cint); cdecl;
  T_gtk_window_resize = procedure(w: PGtkWidget; x, y: cint); cdecl;   { frameless repaint nudge }
  T_gtk_window_set_decorated = procedure(w: PGtkWidget; b: gboolean); cdecl;
  T_webkit_web_view_load_html = procedure(v: PGtkWidget; html, base: PChar); cdecl;
var
  gtk_window_get_size: T_gtk_window_get_size;
  gtk_window_is_maximized: T_gtk_window_is_maximized;
  gtk_window_get_position: T_gtk_window_get_position = nil;
  gtk_window_move: T_gtk_window_move = nil;
  gtk_window_resize: T_gtk_window_resize = nil;
  gtk_window_set_decorated: T_gtk_window_set_decorated;
  webkit_web_view_load_html: T_webkit_web_view_load_html;

function ConfigDir: string;
begin
  Result := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if Result = '' then Result := GetEnvironmentVariable('HOME') + '/.config';
  Result := Result + '/ai-cockpit';
end;

var GeoX: cint = -1; GeoY: cint = -1;   { last position (root coords: which monitor too); -1 = unknown }
    FramelessApplied: Boolean = False;   { what the mapped window actually is (set at map) }

procedure GeometryLoad(out w, h: cint; out maximised: Boolean);
var f: string; sl: TStringList; j: TJSONData;
begin
  { Floating by default, not maximised. A first run had no window.json, so both
    editions opened filling the screen -- reported 2026-09-26. 1600x1000 is a real
    window you can move and size; anyone who maximises it gets that remembered on
    the next start, which is the behaviour people actually expect. }
  w := OptW; h := OptH; maximised := False;
  f := ConfigDir + '/window.json';
  if not FileExists(f) then Exit;
  sl := TStringList.Create;
  try
    try sl.LoadFromFile(f); j := GetJSON(sl.Text); except Exit; end;
    try
      if j is TJSONObject then begin
        w := TJSONObject(j).Get('w', w); h := TJSONObject(j).Get('h', h);
        maximised := TJSONObject(j).Get('max', True);
        GeoX := TJSONObject(j).Get('x', -1); GeoY := TJSONObject(j).Get('y', -1);
        if (w < 400) or (w > 20000) then w := OptW;
        if (h < 300) or (h > 20000) then h := OptH;
      end;
    finally j.Free; end;
  finally sl.Free; end;
end;

procedure GeometrySave;
var w, h, x, y: cint; o: TJSONObject; sl: TStringList;
begin
  if OptKiosk or (OptWorker <> '') then Exit;   { a web worker's hidden window is not the person's window: it must never overwrite the saved size and position }
  if (Pointer(gtk_window_get_size) = nil) or (Pointer(gtk_window_is_maximized) = nil) then Exit;
  gtk_window_get_size(Win, @w, @h);
  x := -1; y := -1; if Pointer(gtk_window_get_position) <> nil then gtk_window_get_position(Win, @x, @y);
  { x/y: where it was (and so on which monitor) — restored before the map; a maximised
    window still records its position so it comes back on the same screen }
  o := TJSONObject.Create(['w', w, 'h', h, 'max', gtk_window_is_maximized(Win) <> 0, 'x', x, 'y', y, 'frameless', FramelessApplied]);
  sl := TStringList.Create;
  try
    ForceDirectories(ConfigDir);
    sl.Text := o.AsJSON; try sl.SaveToFile(ConfigDir + '/window.json'); except end;
  finally sl.Free; o.Free; end;
end;

{ ── pre-load integrity ── }
function Sha256File(const path: string): string;
var p: TProcess; buf: array[0..255] of Byte; n: Integer; s: string;
begin
  Result := ''; s := '';
  p := TProcess.Create(nil);
  try
    p.Executable := '/usr/bin/sha256sum';
    if not FileExists(p.Executable) then p.Executable := 'sha256sum';
    p.Parameters.Add(path);
    p.Options := [poUsePipes, poNoConsole];
    try p.Execute; except Exit; end;
    repeat
      n := p.Output.Read(buf, SizeOf(buf));
      if n > 0 then begin SetString(Result, PChar(@buf[0]), n); s := s + Result; end
      else if p.Running then Sleep(5);
    until (n <= 0) and not p.Running;
    Result := Copy(Trim(s), 1, 64);
  finally p.Free; end;
end;

{ Returns '' when the tree matches its manifest, else a description. }
function VerifyTree(const dir: string; out changed, missing: Integer): string;
var f, rel, want, got, scripts: string; sl: TStringList; j: TJSONData; files: TJSONObject; i: Integer; base: string;
begin
  Result := ''; changed := 0; missing := 0;
  f := dir + '/integrity.json';
  if not FileExists(f) then Exit('no manifest (' + f + ')');
  sl := TStringList.Create;
  try
    try sl.LoadFromFile(f); j := GetJSON(sl.Text); except Exit('manifest unreadable'); end;
    try
      if not (j is TJSONObject) then Exit('manifest unreadable');
      files := TJSONObject(TJSONObject(j).Find('files'));
      if files = nil then Exit('manifest has no file list');
      scripts := GetEnvironmentVariable('HOME') + '/scripts';
      for i := 0 to files.Count - 1 do begin
        rel := files.Names[i]; want := files.Items[i].AsString;
        { the manifest skips these by design; scripts/ live beside the web root }
        if (rel = 'integrity.json') or (rel = 'MANIFEST.txt') or (rel = 'config.php')
           or (rel = 'paths.json') or (rel = '.edition') then Continue;
        if Pos('scripts/', rel) = 1 then base := scripts + '/' + Copy(rel, 9, MaxInt)
        else base := dir + '/' + rel;
        if not FileExists(base) then begin Inc(missing); Continue; end;
        { only the files that decide what runs in this window are hashed here —
          the page's own Integrity panel checks everything, this is the gate }
        if (rel = 'index.html') or (rel = 'auth.php') or (rel = 'paths.php') or (rel = 'integrity_lib.php')
           or (Pos('js/', rel) = 1) or (Pos('css/', rel) = 1) then begin   { the split front end: every script and sheet }
          got := Sha256File(base);
          if (got <> '') and (got <> want) then Inc(changed);
        end;
      end;
    finally j.Free; end;
  finally sl.Free; end;
  if changed > 0 then Result := IntToStr(changed) + ' shipped file(s) changed';
end;

procedure ShowVerifyFailure(const msg: string);
var html: string;
begin
  html := '<html><head><meta charset="utf-8"><style>body{background:#0f141c;color:#cbd5e0;font:14px system-ui,sans-serif;' +
          'display:flex;align-items:center;justify-content:center;height:100vh;margin:0}div{max-width:560px;padding:28px;' +
          'border:1px solid #2d3748;border-radius:8px;background:#121824}h1{font-size:16px;margin:0 0 10px;color:#ffa500}' +
          'code{color:#7ecfff}</style></head><body><div><h1>AI Cockpit did not start</h1>' +
          '<p>' + msg + '</p><p>The window refuses to load the app when a shipped file differs from the build manifest. ' +
          'Reinstall from the bundle, or run <code>~/scripts/cockpit_restore.sh</code> to put the shipped files back, then start Cockpit again.</p>' +
          '<p style="color:#718096">Started with <code>--verify</code>; pass <code>--no-verify</code> to skip this check.</p></div></body></html>';
  if Pointer(webkit_web_view_load_html) <> nil then webkit_web_view_load_html(View, PChar(html), 'about:blank');
end;

procedure QuitApp;
begin
  if RegFile <> '' then begin DeleteFile(RegFile); DeleteFile(ChangeFileExt(RegFile, '.cmd')); end;   { leave the window list }
  GeometrySave;   { size/maximised state for the next launch — also on a kill }
  gtk_main_quit;
end;

procedure PageReply(const j: TJSONObject);
var js: string;
begin
  js := 'if (window.cockpitShellReply) window.cockpitShellReply(' + j.AsJSON + ');';
  webkit_web_view_run_javascript(View, PChar(js), nil, nil, nil);
end;

procedure ReplyError(const id, msg: string);
var j: TJSONObject;
begin
  j := TJSONObject.Create(['id', id, 'ok', False, 'error', msg]);
  try PageReply(j); finally j.Free; end;
end;

{ bw lives in ~/.local/bin (our installer's choice — no sudo) or wherever PATH says. }
function BwExe: string;
var h: string;
begin
  h := GetEnvironmentVariable('HOME');
  if FileExists(h + '/.local/bin/bw') then Exit(h + '/.local/bin/bw');
  if FileExists('/usr/local/bin/bw') then Exit('/usr/local/bin/bw');
  Result := 'bw';
end;

{ Run bw with args, stdout+stderr in Output; True on exit code 0. }
function RunBw(const args: array of string; out Output: string): Boolean;
var p: TProcess; i, n: Integer; buf: array[0..4095] of Byte; chunk: string;
begin
  Output := ''; Result := False;
  p := TProcess.Create(nil);
  try
    p.Executable := BwExe;
    for i := 0 to High(args) do p.Parameters.Add(args[i]);
    if BwSession <> '' then begin p.Parameters.Add('--session'); p.Parameters.Add(BwSession); end;
    p.Parameters.Add('--nointeraction');
    p.Options := [poUsePipes, poStderrToOutPut];
    try p.Execute; except on E: Exception do begin Output := E.Message; Exit(False); end; end;
    repeat
      n := p.Output.Read(buf, SizeOf(buf));
      if n > 0 then begin SetString(chunk, PChar(@buf[0]), n); Output := Output + chunk; end
      else if p.Running then Sleep(15);
    until (n <= 0) and not p.Running;
    Result := p.ExitStatus = 0;
  finally p.Free; end;
end;

function BwInstalled: Boolean;
var o: string;
begin
  Result := RunBw(['--version'], o);
end;

function BwUnlocked: Boolean;
var o: string; j: TJSONData;
begin
  Result := False;
  if BwSession = '' then Exit;
  if not RunBw(['status'], o) then Exit;
  try
    j := GetJSON(o);
    try Result := (j is TJSONObject) and (TJSONObject(j).Get('status', '') = 'unlocked');
    finally j.Free; end;
  except Result := False; end;
end;

function FindTerminal(out exe: string; out preArgs: string): Boolean;
begin
  Result := True;
  if FileExists('/usr/bin/gnome-terminal') then begin exe := 'gnome-terminal'; preArgs := '--title "Bitwarden unlock" --'; Exit; end;
  if FileExists('/usr/bin/konsole') then begin exe := 'konsole'; preArgs := '-e'; Exit; end;
  if FileExists('/usr/bin/xfce4-terminal') then begin exe := 'xfce4-terminal'; preArgs := '-e'; Exit; end;
  if FileExists('/usr/bin/x-terminal-emulator') then begin exe := 'x-terminal-emulator'; preArgs := '-e'; Exit; end;
  if FileExists('/usr/bin/xterm') then begin exe := 'xterm'; preArgs := '-e'; Exit; end;
  Result := False;
end;

procedure BwHandle(const req: TJSONObject); forward;

{ Poll for the unlock hand-off file (every 500 ms, up to 3 minutes). }
function OnBwUnlockPoll(data: Pointer): gboolean; cdecl;
var f: TextFile; tok: string; req: TJSONObject;
begin
  Inc(BwUnlockPolls);
  if FileExists(BwUnlockFile) then begin
    AssignFile(f, BwUnlockFile);
    try Reset(f); ReadLn(f, tok); CloseFile(f); except tok := ''; end;
    DeleteFile(BwUnlockFile); BwUnlockFile := '';
    tok := Trim(tok);
    if tok <> '' then begin
      BwSession := tok; Log('bitwarden: unlocked');
      req := BwPendingReq; BwPendingReq := nil;
      if req <> nil then begin try BwHandle(req); finally req.Free; end; end;
    end else begin
      if BwPendingReq <> nil then begin ReplyError(BwPendingReq.Get('id', ''), 'Bitwarden unlock failed'); FreeAndNil(BwPendingReq); end;
    end;
    Exit(0);
  end;
  if BwUnlockPolls > 360 then begin
    BwUnlockFile := '';
    if BwPendingReq <> nil then begin ReplyError(BwPendingReq.Get('id', ''), 'Bitwarden unlock timed out'); FreeAndNil(BwPendingReq); end;
    Exit(0);
  end;
  Result := 1;
end;

{ Open a terminal running `bw unlock --raw`; the token lands in a 0600 file. }
procedure BwStartUnlock(const req: TJSONObject);
var dir, exe, pre, cmd: string;
begin
  if BwUnlockFile <> '' then begin   { an unlock is already in progress — queue this request instead }
    if BwPendingReq <> nil then BwPendingReq.Free;
    BwPendingReq := TJSONObject(req.Clone); Exit;
  end;
  if not FindTerminal(exe, pre) then begin ReplyError(req.Get('id', ''), 'No terminal emulator found for the Bitwarden unlock'); Exit; end;
  dir := GetEnvironmentVariable('XDG_RUNTIME_DIR'); if dir = '' then dir := '/tmp';
  BwUnlockFile := dir + '/cockpit_bw_' + IntToStr(fpGetPid) + '_' + IntToStr(Random(1000000));
  BwPendingReq := TJSONObject(req.Clone); BwUnlockPolls := 0;
  cmd := 'umask 077; echo "AI Cockpit — Bitwarden unlock. Your master password goes to bw, not to Cockpit."; echo; ' +
         'bw unlock --raw > ' + QuotedStr(BwUnlockFile) + '; ' +
         'if [ -s ' + QuotedStr(BwUnlockFile) + ' ]; then echo; echo "Unlocked. This window closes in 2 s."; sleep 2; ' +
         'else echo; echo "Unlock failed (not logged in? run: bw login)."; : > ' + QuotedStr(BwUnlockFile) + '; sleep 4; fi';
  fpSystem(exe + ' ' + pre + ' bash -c ' + QuotedStr(cmd) + ' >/dev/null 2>&1 &');
  g_timeout_add(500, @OnBwUnlockPoll, nil);
end;

procedure BwHandle(const req: TJSONObject);
var id, cmd, o, q, itemId: string; rep: TJSONObject; arr, items: TJSONArray; j, it: TJSONData; i: Integer; login: TJSONObject;
begin
  id := req.Get('id', ''); cmd := req.Get('cmd', '');
  if cmd = 'bw_status' then begin
    rep := TJSONObject.Create(['id', id, 'ok', True, 'installed', BwInstalled, 'unlocked', BwUnlocked]);
    try PageReply(rep); finally rep.Free; end; Exit;
  end;
  if not BwInstalled then begin ReplyError(id, 'Bitwarden CLI (bw) is not installed'); Exit; end;
  if not BwUnlocked then begin BwSession := ''; BwStartUnlock(req); Exit; end;
  if cmd = 'bw_search' then begin
    q := req.Get('q', 'AI Cockpit');
    if not RunBw(['list', 'items', '--search', q], o) then begin ReplyError(id, 'bw list failed: ' + Copy(o, 1, 200)); Exit; end;
    items := TJSONArray.Create;
    try
      j := GetJSON(o);
      try
        if j is TJSONArray then
          for i := 0 to TJSONArray(j).Count - 1 do begin
            it := TJSONArray(j).Items[i];
            if not (it is TJSONObject) then Continue;
            if TJSONObject(it).Get('type', 0) <> 1 then Continue;   { 1 = login item }
            login := TJSONObject(TJSONObject(it).Find('login'));
            rep := TJSONObject.Create(['id', TJSONObject(it).Get('id', ''), 'name', TJSONObject(it).Get('name', '')]);
            if login <> nil then rep.Add('username', login.Get('username', '')) else rep.Add('username', '');
            items.Add(rep);
          end;
      finally j.Free; end;
    except on E: Exception do begin items.Free; ReplyError(id, 'bw output not understood'); Exit; end; end;
    rep := TJSONObject.Create(['id', id, 'ok', True]);
    rep.Add('items', items);
    try PageReply(rep); finally rep.Free; end; Exit;
  end;
  if cmd = 'bw_get' then begin
    itemId := req.Get('item', '');
    if itemId = '' then begin ReplyError(id, 'item required'); Exit; end;
    if not RunBw(['get', 'item', itemId], o) then begin ReplyError(id, 'bw get failed: ' + Copy(o, 1, 200)); Exit; end;
    try
      j := GetJSON(o);
      try
        login := nil;
        if j is TJSONObject then login := TJSONObject(TJSONObject(j).Find('login'));
        if login = nil then begin ReplyError(id, 'not a login item'); Exit; end;
        rep := TJSONObject.Create(['id', id, 'ok', True, 'name', TJSONObject(j).Get('name', ''),
                 'username', login.Get('username', ''), 'password', login.Get('password', '')]);
        try PageReply(rep); finally rep.Free; end;
      finally j.Free; end;
    except ReplyError(id, 'bw output not understood'); end;
    Exit;
  end;
  ReplyError(id, 'unknown command ' + cmd);
end;

{ ── OS keyring (libsecret: GNOME Keyring / KWallet) ───────────────────────
  kr_set {key,value} / kr_get {key} / kr_del {key}. One schema "site.ruggi.cockpit"
  with a single string attribute "key"; secrets land in the user's default
  collection ("login"), unlocked with the desktop session. Loaded lazily so a
  desktop without libsecret still runs the shell (kr_* then reply available:false). }
type
  TSecretSchemaAttribute = record name: PChar; atype: cint; end;
  TSecretSchema = record
    name: PChar;
    flags: cint;
    attributes: array[0..31] of TSecretSchemaAttribute;
    reserved: cint;
    reserved1, reserved2, reserved3, reserved4, reserved5, reserved6, reserved7: Pointer;
  end;
  T_g_hash_table_new = function(hash, equal: Pointer): Pointer; cdecl;
  T_g_hash_table_insert = procedure(t: Pointer; k, v: Pointer); cdecl;
  T_g_hash_table_unref = procedure(t: Pointer); cdecl;
  T_g_str_hash = function(v: Pointer): cuint; cdecl;
  T_g_str_equal = function(a, b: Pointer): gboolean; cdecl;
  T_secret_password_storev_sync = function(schema: Pointer; attrs: Pointer; collection, lbl, pw: PChar; cancellable: Pointer; err: PPointer): gboolean; cdecl;
  T_secret_password_lookupv_sync = function(schema: Pointer; attrs: Pointer; cancellable: Pointer; err: PPointer): PChar; cdecl;
  T_secret_password_clearv_sync = function(schema: Pointer; attrs: Pointer; cancellable: Pointer; err: PPointer): gboolean; cdecl;
  T_secret_password_free = procedure(p: PChar); cdecl;
  T_g_error_free = procedure(e: Pointer); cdecl;
var
  KrLoaded: Boolean = False; KrOK: Boolean = False;
  KrSchema: TSecretSchema;
  g_hash_table_new: T_g_hash_table_new; g_hash_table_insert: T_g_hash_table_insert; g_hash_table_unref: T_g_hash_table_unref;
  g_str_hash_p, g_str_equal_p: Pointer;
  secret_password_storev_sync: T_secret_password_storev_sync;
  secret_password_lookupv_sync: T_secret_password_lookupv_sync;
  secret_password_clearv_sync: T_secret_password_clearv_sync;
  secret_password_free: T_secret_password_free;
  g_error_free: T_g_error_free;

function KrInit: Boolean;
var h, hg: TLibHandle;
begin
  if KrLoaded then Exit(KrOK);
  KrLoaded := True; KrOK := False;
  h := LoadLibrary('libsecret-1.so.0'); if h = NilHandle then Exit(False);
  hg := LoadLibrary(GLIB); if hg = NilHandle then Exit(False);
  Pointer(g_hash_table_new) := GetProcAddress(hg, 'g_hash_table_new');
  Pointer(g_hash_table_insert) := GetProcAddress(hg, 'g_hash_table_insert');
  Pointer(g_hash_table_unref) := GetProcAddress(hg, 'g_hash_table_unref');
  g_str_hash_p := GetProcAddress(hg, 'g_str_hash'); g_str_equal_p := GetProcAddress(hg, 'g_str_equal');
  Pointer(g_error_free) := GetProcAddress(hg, 'g_error_free');
  Pointer(secret_password_storev_sync) := GetProcAddress(h, 'secret_password_storev_sync');
  Pointer(secret_password_lookupv_sync) := GetProcAddress(h, 'secret_password_lookupv_sync');
  Pointer(secret_password_clearv_sync) := GetProcAddress(h, 'secret_password_clearv_sync');
  Pointer(secret_password_free) := GetProcAddress(h, 'secret_password_free');
  if (Pointer(g_hash_table_new) = nil) or (Pointer(secret_password_storev_sync) = nil) or (Pointer(secret_password_lookupv_sync) = nil)
     or (Pointer(secret_password_clearv_sync) = nil) or (Pointer(secret_password_free) = nil) or (g_str_hash_p = nil) then Exit(False);
  FillChar(KrSchema, SizeOf(KrSchema), 0);
  KrSchema.name := 'site.ruggi.cockpit';
  KrSchema.flags := 0;                              { SECRET_SCHEMA_NONE }
  KrSchema.attributes[0].name := 'key'; KrSchema.attributes[0].atype := 0;   { SECRET_SCHEMA_ATTRIBUTE_STRING }
  KrOK := True; Result := True;
end;

function KrAttrs(const key: string): Pointer;
begin
  Result := g_hash_table_new(g_str_hash_p, g_str_equal_p);
  g_hash_table_insert(Result, PChar('key'), PChar(key));
end;

procedure KrHandle(const req: TJSONObject);
var id, cmd, key, val, s: string; attrs: Pointer; err: Pointer; p: PChar; rep: TJSONObject; ok: Boolean;
begin
  id := req.Get('id', ''); cmd := req.Get('cmd', ''); key := req.Get('key', '');
  Log('keyring: ' + cmd + ' ' + key);
  if not KrInit then begin
    Log('keyring: libsecret unavailable');
    rep := TJSONObject.Create(['id', id, 'ok', True, 'available', False]);
    try PageReply(rep); finally rep.Free; end; Exit;
  end;
  if not (Length(key) in [1..64]) then begin ReplyError(id, 'key required'); Exit; end;
  attrs := KrAttrs(key); err := nil;
  try
    if cmd = 'kr_set' then begin
      val := req.Get('value', '');
      ok := secret_password_storev_sync(@KrSchema, attrs, 'default', PChar('AI Cockpit — ' + key), PChar(val), nil, @err) <> 0;
      if err <> nil then g_error_free(err);
      rep := TJSONObject.Create(['id', id, 'ok', ok, 'available', True]);
      if not ok then rep.Add('error', 'keyring store failed');
      try PageReply(rep); finally rep.Free; end;
    end else if cmd = 'kr_get' then begin
      p := secret_password_lookupv_sync(@KrSchema, attrs, nil, @err);
      if err <> nil then g_error_free(err);
      s := ''; if p <> nil then begin s := StrPas(p); secret_password_free(p); end;
      rep := TJSONObject.Create(['id', id, 'ok', True, 'available', True, 'found', p <> nil, 'value', s]);
      try PageReply(rep); finally rep.Free; end;
    end else if cmd = 'kr_del' then begin
      secret_password_clearv_sync(@KrSchema, attrs, nil, @err);
      if err <> nil then g_error_free(err);
      rep := TJSONObject.Create(['id', id, 'ok', True, 'available', True]);
      try PageReply(rep); finally rep.Free; end;
    end else ReplyError(id, 'unknown command ' + cmd);
  finally g_hash_table_unref(attrs); end;
end;

{ ── native file paths ──────────────────────────────────────────────────────
  Browsers hide the real path of a dropped or chosen file; the shell does not.
  Drop: GTK's drag-data-received on the web view fires before WebKit turns the
  drop into a DOM event, so the URIs are read here and handed to the page as
  window.cockpitShellDrop({paths:[...]}) — the DOM drop event then follows and
  the page uses the paths instead of uploading File objects.
  pick_files {multiple,title,dir} → native GtkFileChooserNative → {paths}. }
type
  PGSList = ^TGSList;
  TGSList = record data: Pointer; next: PGSList; end;
  T_gtk_selection_data_get_uris = function(sel: Pointer): PPChar; cdecl;
  T_g_strfreev = procedure(v: PPChar); cdecl;
  T_g_filename_from_uri = function(uri: PChar; hostname: PPChar; err: PPointer): PChar; cdecl;
  T_gtk_file_chooser_native_new = function(title: PChar; parent: PGtkWidget; action: cint; accept, cancel: PChar): PGObject; cdecl;
  T_gtk_native_dialog_run = function(d: PGObject): cint; cdecl;
  T_gtk_native_dialog_destroy = procedure(d: PGObject); cdecl;
  T_gtk_file_chooser_set_select_multiple = procedure(c: PGObject; b: gboolean); cdecl;
  T_gtk_file_chooser_set_current_folder = function(c: PGObject; f: PChar): gboolean; cdecl;
  T_gtk_file_chooser_get_filenames = function(c: PGObject): PGSList; cdecl;
  T_g_slist_free_full = procedure(l: PGSList; freefn: Pointer); cdecl;
  T_g_object_unref = procedure(o: PGObject); cdecl;
var
  gtk_selection_data_get_uris: T_gtk_selection_data_get_uris;
  g_strfreev: T_g_strfreev;
  g_filename_from_uri: T_g_filename_from_uri;
  gtk_file_chooser_native_new: T_gtk_file_chooser_native_new;
  gtk_native_dialog_run: T_gtk_native_dialog_run;
  gtk_native_dialog_destroy: T_gtk_native_dialog_destroy;
  gtk_file_chooser_set_select_multiple: T_gtk_file_chooser_set_select_multiple;
  gtk_file_chooser_set_current_folder: T_gtk_file_chooser_set_current_folder;
  gtk_file_chooser_get_filenames: T_gtk_file_chooser_get_filenames;
  g_slist_free_full: T_g_slist_free_full;
  g_object_unref: T_g_object_unref;

procedure LoadFileBindings;
var h: TLibHandle;
begin
  h := LoadLibrary(GLIB);
  Bind(h, GLIB, 'g_strfreev', g_strfreev);
  Bind(h, GLIB, 'g_filename_from_uri', g_filename_from_uri);
  Bind(h, GLIB, 'g_slist_free_full', g_slist_free_full);
  h := LoadLibrary(GOBJ);
  Bind(h, GOBJ, 'g_object_unref', g_object_unref);
  h := LoadLibrary(GTK);
  Bind(h, GTK, 'gtk_selection_data_get_uris', gtk_selection_data_get_uris);
  Bind(h, GTK, 'gtk_file_chooser_native_new', gtk_file_chooser_native_new);
  Bind(h, GTK, 'gtk_native_dialog_run', gtk_native_dialog_run);
  Bind(h, GTK, 'gtk_native_dialog_destroy', gtk_native_dialog_destroy);
  Bind(h, GTK, 'gtk_file_chooser_set_select_multiple', gtk_file_chooser_set_select_multiple);
  Bind(h, GTK, 'gtk_file_chooser_set_current_folder', gtk_file_chooser_set_current_folder);
  Bind(h, GTK, 'gtk_file_chooser_get_filenames', gtk_file_chooser_get_filenames);
  Bind(h, GTK, 'gtk_window_get_size', gtk_window_get_size);
  Pointer(gtk_window_resize) := GetProcAddress(h, 'gtk_window_resize');   { optional: nil is handled }
  Bind(h, GTK, 'gtk_window_is_maximized', gtk_window_is_maximized);
  Pointer(gtk_window_get_position) := GetProcAddress(h, 'gtk_window_get_position');
  Pointer(gtk_window_move) := GetProcAddress(h, 'gtk_window_move');
  Bind(h, GTK, 'gtk_window_set_decorated', gtk_window_set_decorated);
  h := LoadLibrary(WK);
  Bind(h, WK, 'webkit_web_view_load_html', webkit_web_view_load_html);
end;

procedure JsonStringArrayReply(const id, key: string; const items: TStringList);
var rep: TJSONObject; arr: TJSONArray; i: Integer;
begin
  arr := TJSONArray.Create;
  for i := 0 to items.Count - 1 do arr.Add(items[i]);
  rep := TJSONObject.Create(['id', id, 'ok', True]); rep.Add(key, arr);
  try PageReply(rep); finally rep.Free; end;
end;

{ GTK drag-data-received on the web view: peek the URI list, keep propagating. }
procedure OnDragDataReceived(w: PGtkWidget; ctx: Pointer; x, y: cint; sel: Pointer; info, time: cuint; data: Pointer); cdecl;
var uris: PPChar; i: Integer; fn: PChar; paths: TStringList; arr: TJSONArray; obj: TJSONObject; js: string;
begin
  uris := gtk_selection_data_get_uris(sel);
  if uris = nil then Exit;
  paths := TStringList.Create;
  try
    i := 0;
    while uris[i] <> nil do begin
      fn := g_filename_from_uri(uris[i], nil, nil);
      if fn <> nil then begin paths.Add(StrPas(fn)); g_free(fn); end;
      Inc(i);
    end;
    g_strfreev(uris);
    if paths.Count = 0 then Exit;
    arr := TJSONArray.Create; for i := 0 to paths.Count - 1 do arr.Add(paths[i]);
    obj := TJSONObject.Create(['x', x, 'y', y]); obj.Add('paths', arr);
    js := 'if (window.cockpitShellDrop) window.cockpitShellDrop(' + obj.AsJSON + ');';
    obj.Free;
    webkit_web_view_run_javascript(View, PChar(js), nil, nil, nil);
    Log('drop: ' + IntToStr(paths.Count) + ' path(s)');
  finally paths.Free; end;
end;

{ pick_files: native file chooser, modal on our window. }
procedure PickFiles(const req: TJSONObject);
var dlg: PGObject; id, title, dir: string; multiple: Boolean; resp: cint; l, n: PGSList; paths: TStringList;
begin
  id := req.Get('id', ''); title := req.Get('title', 'Choose a file'); dir := req.Get('dir', '');
  multiple := req.Get('multiple', False);
  { GTK_FILE_CHOOSER_ACTION_OPEN = 0; GTK_RESPONSE_ACCEPT = -3 }
  dlg := gtk_file_chooser_native_new(PChar(title), Win, 0, '_Open', '_Cancel');
  gtk_file_chooser_set_select_multiple(dlg, Ord(multiple));
  if (dir <> '') and DirectoryExists(dir) then gtk_file_chooser_set_current_folder(dlg, PChar(dir));
  resp := gtk_native_dialog_run(dlg);
  paths := TStringList.Create;
  try
    if resp = -3 then begin
      l := gtk_file_chooser_get_filenames(dlg); n := l;
      while n <> nil do begin paths.Add(StrPas(PChar(n^.data))); n := n^.next; end;
      g_slist_free_full(l, Pointer(g_free));
    end;
    JsonStringArrayReply(id, 'paths', paths);
  finally paths.Free; gtk_native_dialog_destroy(dlg); g_object_unref(dlg); end;
end;

{ ── notifications (libnotify) and tray icon (ayatana/appindicator) ─────────
  notify {title, body, urgency} → desktop notification with an "Open" default
  action that presents the window. Tray: Show / Hide / Exit; on GNOME it needs
  the AppIndicator extension, on KDE/XFCE/Cinnamon/MATE it just appears. Both
  are optional: a missing library only disables the feature. }
type
  T_notify_init = function(app: PChar): gboolean; cdecl;
  T_notify_notification_new = function(summary, body, icon: PChar): PGObject; cdecl;
  T_notify_notification_show = function(n: PGObject; err: PPointer): gboolean; cdecl;
  T_notify_notification_set_urgency = procedure(n: PGObject; u: cint); cdecl;
  T_notify_notification_set_timeout = procedure(n: PGObject; ms: cint); cdecl;
  T_notify_notification_add_action = procedure(n: PGObject; action, lbl: PChar; cb: Pointer; data: Pointer; freefn: Pointer); cdecl;
  T_app_indicator_new = function(id, icon: PChar; category: cint): PGObject; cdecl;
  T_app_indicator_set_status = procedure(i: PGObject; status: cint); cdecl;
  T_app_indicator_set_menu = procedure(i: PGObject; menu: PGtkWidget); cdecl;
  T_app_indicator_set_icon_full = procedure(i: PGObject; icon, desc: PChar); cdecl;
  T_app_indicator_set_title = procedure(i: PGObject; t: PChar); cdecl;
  T_gtk_menu_new = function: PGtkWidget; cdecl;
  T_gtk_menu_item_new_with_label = function(l: PChar): PGtkWidget; cdecl;
  T_gtk_separator_menu_item_new = function: PGtkWidget; cdecl;
  T_gtk_menu_shell_append = procedure(m, item: PGtkWidget); cdecl;
  T_gtk_window_present = procedure(w: PGtkWidget); cdecl;
  T_gtk_window_present_with_time = procedure(w: PGtkWidget; t: cuint); cdecl;
  T_gtk_widget_hide = procedure(w: PGtkWidget); cdecl;
  T_gtk_window_iconify = procedure(w: PGtkWidget); cdecl;
  T_gtk_window_deiconify = procedure(w: PGtkWidget); cdecl;
  T_gtk_window_is_active = function(w: PGtkWidget): gboolean; cdecl;
var
  NotifyLoaded: Boolean = False; NotifyOK: Boolean = False;
  notify_init: T_notify_init; notify_notification_new: T_notify_notification_new;
  notify_notification_show: T_notify_notification_show; notify_notification_set_urgency: T_notify_notification_set_urgency;
  notify_notification_set_timeout: T_notify_notification_set_timeout; notify_notification_add_action: T_notify_notification_add_action;
  TrayInd: PGObject = nil;
  app_indicator_new: T_app_indicator_new; app_indicator_set_status: T_app_indicator_set_status;
  app_indicator_set_menu: T_app_indicator_set_menu; app_indicator_set_icon_full: T_app_indicator_set_icon_full;
  app_indicator_set_title: T_app_indicator_set_title;
  gtk_menu_new: T_gtk_menu_new; gtk_menu_item_new_with_label: T_gtk_menu_item_new_with_label;
  gtk_separator_menu_item_new: T_gtk_separator_menu_item_new; gtk_menu_shell_append: T_gtk_menu_shell_append;
  gtk_window_present: T_gtk_window_present;
  gtk_window_present_with_time: T_gtk_window_present_with_time; gtk_widget_hide: T_gtk_widget_hide;
  gtk_window_iconify: T_gtk_window_iconify; gtk_window_deiconify: T_gtk_window_deiconify;
  gtk_window_is_active: T_gtk_window_is_active;

function NotifyInit: Boolean;
var h: TLibHandle;
begin
  if NotifyLoaded then Exit(NotifyOK);
  NotifyLoaded := True; NotifyOK := False;
  h := LoadLibrary('libnotify.so.4'); if h = NilHandle then Exit(False);
  Pointer(notify_init) := GetProcAddress(h, 'notify_init');
  Pointer(notify_notification_new) := GetProcAddress(h, 'notify_notification_new');
  Pointer(notify_notification_show) := GetProcAddress(h, 'notify_notification_show');
  Pointer(notify_notification_set_urgency) := GetProcAddress(h, 'notify_notification_set_urgency');
  Pointer(notify_notification_set_timeout) := GetProcAddress(h, 'notify_notification_set_timeout');
  Pointer(notify_notification_add_action) := GetProcAddress(h, 'notify_notification_add_action');
  if (Pointer(notify_init) = nil) or (Pointer(notify_notification_new) = nil) or (Pointer(notify_notification_show) = nil) then Exit(False);
  NotifyOK := notify_init('AI Cockpit') <> 0;
  Result := NotifyOK;
end;

{ A window manager refuses to raise a window without a recent user timestamp
  (focus-stealing prevention) — the hotkey therefore passes the key event's
  time, and everything else 0 ("now"). }
procedure PresentWindowAt(t: cuint);
begin
  gtk_window_deiconify(Win); gtk_widget_show_all(Win);
  if Pointer(gtk_window_present_with_time) <> nil then gtk_window_present_with_time(Win, t)
  else gtk_window_present(Win);
end;
procedure PresentWindow;
begin
  PresentWindowAt(0);
end;

procedure OnNotifyAction(n: PGObject; action: PChar; data: Pointer); cdecl;
begin
  PresentWindow;
end;

procedure NotifyHandle(const req: TJSONObject);
var id, title, body, urg: string; n: PGObject; rep: TJSONObject; u: cint; ok: Boolean; err: Pointer;
begin
  id := req.Get('id', ''); title := req.Get('title', 'AI Cockpit'); body := req.Get('body', ''); urg := req.Get('urgency', 'normal');
  { only_if_unfocused: skip while the window is the active one (minimised counts as not active) }
  if req.Get('only_if_unfocused', False) and (Pointer(gtk_window_is_active) <> nil) and (gtk_window_is_active(Win) <> 0) then begin
    rep := TJSONObject.Create(['id', id, 'ok', True, 'available', True, 'skipped', True]);
    try PageReply(rep); finally rep.Free; end; Exit;
  end;
  if not NotifyInit then begin
    rep := TJSONObject.Create(['id', id, 'ok', True, 'available', False]);
    try PageReply(rep); finally rep.Free; end; Exit;
  end;
  if OptIcon <> '' then n := notify_notification_new(PChar(title), PChar(body), PChar(OptIcon))
  else n := notify_notification_new(PChar(title), PChar(body), 'dialog-information');
  u := 1; if urg = 'low' then u := 0 else if urg = 'critical' then u := 2;
  if Pointer(notify_notification_set_urgency) <> nil then notify_notification_set_urgency(n, u);
  if Pointer(notify_notification_set_timeout) <> nil then notify_notification_set_timeout(n, -1);
  if Pointer(notify_notification_add_action) <> nil then notify_notification_add_action(n, 'default', 'Open Cockpit', @OnNotifyAction, nil, nil);
  err := nil;
  ok := notify_notification_show(n, @err) <> 0;
  if err <> nil then g_error_free(err);
  { the notification object must outlive the action callback — not unref'd here (a few bytes per notification) }
  rep := TJSONObject.Create(['id', id, 'ok', ok, 'available', True]);
  try PageReply(rep); finally rep.Free; end;
end;

{ ── tray ── }
procedure OnTrayShow(item: PGtkWidget; data: Pointer); cdecl;
begin
  PresentWindow;
end;
procedure OnTrayHide(item: PGtkWidget; data: Pointer); cdecl;
begin
  gtk_window_iconify(Win);
end;
procedure OnTrayExit(item: PGtkWidget; data: Pointer); cdecl;
begin
  PresentWindow;
  OnDelete(Win, nil, nil);   { same path as the close button: the page's exit procedure }
end;

{ ── global hotkey (X11) ───────────────────────────────────────────────────
  One key combination grabbed on the root window, so it works from any app:
  press it and Cockpit comes to the front (press again while it is in front and
  it goes back down). X11 only — under Wayland the compositor owns hotkeys, and
  a desktop shortcut calling `cockpit-start` does the same job there.
  Grabs every lock-key variant (NumLock/CapsLock/ScrollLock) so the combination
  fires whatever the keyboard state is. --hotkey "ctrl+alt+c" | "none". }
type
  TXKeyEvent = record
    etype: cint; serial: culong; send_event: cint; display: Pointer;
    window, root, subwindow: culong; time: culong;
    x, y, x_root, y_root: cint; state, keycode: cuint; same_screen: cint;
  end;
  PXKeyEvent = ^TXKeyEvent;
  T_XStringToKeysym = function(s: PChar): culong; cdecl;
  T_XKeysymToKeycode = function(d: Pointer; k: culong): cuint; cdecl;
  T_XGrabKey = function(d: Pointer; code: cint; mods: cuint; win: culong; owner: cint; ptr_mode, kb_mode: cint): cint; cdecl;
  T_XUngrabKey = function(d: Pointer; code: cint; mods: cuint; win: culong): cint; cdecl;
  TPowerKey = record Code, Mods: cuint; Spec, Cmd: string; end;   { one Power Button hotkey: the keys and the command line it runs }
  T_XDefaultRootWindow = function(d: Pointer): culong; cdecl;
  T_XSetErrorHandler = function(h: Pointer): Pointer; cdecl;
  T_gdk_display_get_default = function: PGObject; cdecl;
  T_gdk_x11_display_get_xdisplay = function(d: PGObject): Pointer; cdecl;
  T_gdk_window_add_filter = procedure(w: Pointer; func: Pointer; data: Pointer); cdecl;
  T_XGetInputFocus = function(d: Pointer; w: pculong; revert: pcint): cint; cdecl;
  T_XQueryTree = function(d: Pointer; w: culong; root, parent: pculong; children: Pointer; n: pcuint): cint; cdecl;
  T_XFree = function(p: Pointer): cint; cdecl;
  T_gtk_widget_get_window = function(w: PGtkWidget): Pointer; cdecl;
  T_gdk_x11_window_get_xid = function(w: Pointer): culong; cdecl;
var
  XStringToKeysym: T_XStringToKeysym; XKeysymToKeycode: T_XKeysymToKeycode;
  XGrabKey: T_XGrabKey; XUngrabKey: T_XUngrabKey; XDefaultRootWindow: T_XDefaultRootWindow;
  XSetErrorHandler: T_XSetErrorHandler;
  gdk_display_get_default: T_gdk_display_get_default;
  gdk_x11_display_get_xdisplay: T_gdk_x11_display_get_xdisplay;
  gdk_window_add_filter: T_gdk_window_add_filter;
  XGetInputFocus: T_XGetInputFocus; XQueryTree: T_XQueryTree; XFree: T_XFree;
  gtk_widget_get_window: T_gtk_widget_get_window; gdk_x11_window_get_xid: T_gdk_x11_window_get_xid;
  HotkeyXDisplay: Pointer = nil;
  HotkeyCode: cuint = 0; HotkeyMods: cuint = 0; HotkeyOK: Boolean = False;
  PowerKeys: array of TPowerKey;   { the Power Button hotkeys (power_hotkeys.json, set from the Power Buttons panel) }
  HotkeyRoot: culong = 0; HotkeyBound: Boolean = False;
  WinIconified: Boolean = False;   { tracked from window-state-event }

function ShellQuote(const s: string): string; forward;
procedure PowerKeyRun(const cmd: string);
begin
  Log('power hotkey: running a button');
  fpSystem('setsid bash -c ' + ShellQuote(cmd) + ' >/dev/null 2>&1 &');
end;

function XErrorIgnore(d: Pointer; ev: Pointer): cint; cdecl;
begin
  { a grab that clashes with another app must not kill the process }
  Result := 0;
end;

{ "ctrl+alt+c" → mods + keycode. ControlMask=4 Mod1(Alt)=8 ShiftMask=1 Mod4(Super)=64 }
function ParseHotkey(const spec: string; xdisp: Pointer; out code: cuint; out mods: cuint): Boolean;
var parts: TStringList; i: Integer; k: string; sym: culong;
begin
  Result := False; code := 0; mods := 0;
  parts := TStringList.Create;
  try
    parts.Delimiter := '+'; parts.StrictDelimiter := True; parts.DelimitedText := LowerCase(spec);
    for i := 0 to parts.Count - 1 do begin
      k := Trim(parts[i]);
      if (k = 'ctrl') or (k = 'control') then mods := mods or 4
      else if (k = 'alt') or (k = 'mod1') then mods := mods or 8
      else if k = 'shift' then mods := mods or 1
      else if (k = 'super') or (k = 'win') or (k = 'meta') or (k = 'mod4') then mods := mods or 64
      else begin
        if Length(k) = 1 then sym := XStringToKeysym(PChar(k))
        else sym := XStringToKeysym(PChar(k));                 { F1, space, Escape… }
        if (sym = 0) and (Length(k) > 1) then sym := XStringToKeysym(PChar(UpCase(k[1]) + Copy(k, 2, MaxInt)));
        if sym = 0 then Exit(False);
        code := XKeysymToKeycode(xdisp, sym);
      end;
    end;
  finally parts.Free; end;
  Result := code <> 0;
end;

{ Does the X input focus sit on our window (or a child of it)? gtk_window_is_active
  proved unreliable across window managers; the focus walk is what the X server says. }
function WindowHasFocus: Boolean;
var focus, root, parent, ours: culong; rev: cint; kids: Pointer; n: cuint; guard: Integer;
begin
  Result := False;
  if (HotkeyXDisplay = nil) or (Pointer(XGetInputFocus) = nil) or (Pointer(gdk_x11_window_get_xid) = nil) then
    Exit((Pointer(gtk_window_is_active) <> nil) and (gtk_window_is_active(Win) <> 0));
  ours := gdk_x11_window_get_xid(gtk_widget_get_window(Win));
  if ours = 0 then Exit;
  focus := 0; XGetInputFocus(HotkeyXDisplay, @focus, @rev);
  guard := 0;
  while (focus > 1) and (guard < 16) do begin
    if focus = ours then Exit(True);
    kids := nil; root := 0; parent := 0; n := 0;
    if XQueryTree(HotkeyXDisplay, focus, @root, @parent, @kids, @n) = 0 then Break;
    if kids <> nil then XFree(kids);
    if (parent = 0) or (parent = root) then Break;
    focus := parent; Inc(guard);
  end;
end;

{ GDK filter: 0 = GDK_FILTER_CONTINUE, 2 = GDK_FILTER_REMOVE }
function HotkeyFilter(xevent: Pointer; event: Pointer; data: Pointer): cint; cdecl;
var ke: PXKeyEvent; pi: Integer;
begin
  Result := 0;
  ke := PXKeyEvent(xevent);
  if (ke = nil) or (ke^.etype <> 2) then Exit;                      { KeyPress }
  for pi := 0 to High(PowerKeys) do   { a Power Button's own hotkey: run its command, do not hand the key on }
    if (ke^.keycode = PowerKeys[pi].Code) and ((ke^.state and (4 or 8 or 1 or 64)) = PowerKeys[pi].Mods) then begin PowerKeyRun(PowerKeys[pi].Cmd); Result := 2; Exit; end;
  if (ke^.keycode <> HotkeyCode) then Exit;
  if ((ke^.state and (4 or 8 or 1 or 64)) <> HotkeyMods) then Exit;  { ignore lock bits }
  { in front and not minimised → put it down; anything else → bring it up }
  if (not WinIconified) and WindowHasFocus then begin
    Log('hotkey: hide'); gtk_window_iconify(Win);
  end else begin
    Log('hotkey: show'); PresentWindowAt(cuint(ke^.time));
  end;
  Result := 2;
end;

{ ── SIGHUP = hard reload ─────────────────────────────────────────────────────
  `kill -HUP <pid>` reloads the app bypassing the cache — what a deploy does to
  a running window instead of asking for F5 (next_build.sh → refresh_window.sh).
  Optional binding; without it the signal keeps its default (nothing). }
type
  T_g_unix_signal_add = function(signum: cint; handler: Pointer; data: Pointer): cuint; cdecl;
var
  g_unix_signal_add: T_g_unix_signal_add = nil;

function OnReloadSignal(data: Pointer): gboolean; cdecl;
begin
  Log('SIGHUP: reload (bypass cache)');
  if (View <> nil) and (Pointer(webkit_web_view_reload_bypass_cache) <> nil) then webkit_web_view_reload_bypass_cache(View);
  Result := 1;   { keep the source }
end;

procedure ReloadSignalInit;
var h: TLibHandle;
begin
  h := LoadLibrary(GLIB); if h = NilHandle then Exit;
  Pointer(g_unix_signal_add) := GetProcAddress(h, 'g_unix_signal_add');
  { SIGHUP, never SIGUSR1/2: WebKit's WTF suspends threads with SIGUSR1 (GC, libpas
    scavenger) — hooking it livelocked the UI process at 100% CPU after ~2 min (b69–b72). }
  if Pointer(g_unix_signal_add) <> nil then g_unix_signal_add(1 { SIGHUP }, @OnReloadSignal, nil);
end;

{ The X libraries, the display, the error handler and the key filter: once, for the main hotkey and the Power Button hotkeys alike. False on Wayland (the compositor owns shortcuts) or when a piece is missing. }
function HotkeyBind: Boolean;
var hx, hgdk: TLibHandle; xdisp: Pointer; disp: PGObject;
begin
  Result := HotkeyBound;
  if HotkeyBound then Exit;
  if GetEnvironmentVariable('WAYLAND_DISPLAY') <> '' then begin
    Log('hotkey: Wayland session — the compositor owns shortcuts, skipped'); Exit;
  end;
  hx := LoadLibrary('libX11.so.6'); if hx = NilHandle then begin Log('hotkey: no libX11'); Exit; end;
  hgdk := LoadLibrary('libgdk-3.so.0'); if hgdk = NilHandle then Exit;
  Pointer(XStringToKeysym) := GetProcAddress(hx, 'XStringToKeysym');
  Pointer(XKeysymToKeycode) := GetProcAddress(hx, 'XKeysymToKeycode');
  Pointer(XGrabKey) := GetProcAddress(hx, 'XGrabKey');
  Pointer(XUngrabKey) := GetProcAddress(hx, 'XUngrabKey');
  Pointer(XDefaultRootWindow) := GetProcAddress(hx, 'XDefaultRootWindow');
  Pointer(XSetErrorHandler) := GetProcAddress(hx, 'XSetErrorHandler');
  Pointer(gdk_display_get_default) := GetProcAddress(hgdk, 'gdk_display_get_default');
  Pointer(gdk_x11_display_get_xdisplay) := GetProcAddress(hgdk, 'gdk_x11_display_get_xdisplay');
  Pointer(gdk_window_add_filter) := GetProcAddress(hgdk, 'gdk_window_add_filter');
  Pointer(XGetInputFocus) := GetProcAddress(hx, 'XGetInputFocus');
  Pointer(XQueryTree) := GetProcAddress(hx, 'XQueryTree');
  Pointer(XFree) := GetProcAddress(hx, 'XFree');
  Pointer(gdk_x11_window_get_xid) := GetProcAddress(hgdk, 'gdk_x11_window_get_xid');
  Pointer(gtk_widget_get_window) := GetProcAddress(LoadLibrary(GTK), 'gtk_widget_get_window');
  if (Pointer(XGrabKey) = nil) or (Pointer(XUngrabKey) = nil) or (Pointer(gdk_x11_display_get_xdisplay) = nil) or (Pointer(gdk_window_add_filter) = nil) then Exit;
  disp := gdk_display_get_default();
  if disp = nil then Exit;
  xdisp := gdk_x11_display_get_xdisplay(disp);
  if xdisp = nil then Exit;
  HotkeyXDisplay := xdisp;
  if Pointer(XSetErrorHandler) <> nil then XSetErrorHandler(@XErrorIgnore);
  HotkeyRoot := XDefaultRootWindow(xdisp);
  gdk_window_add_filter(nil, @HotkeyFilter, nil);
  HotkeyBound := True; Result := True;
end;

procedure HotkeyInit(const spec: string);
var locks: array[0..3] of cuint; i: Integer;
begin
  if (spec = '') or (LowerCase(spec) = 'none') then Exit;
  if not HotkeyBind then Exit;
  if not ParseHotkey(spec, HotkeyXDisplay, HotkeyCode, HotkeyMods) then begin Log('hotkey: cannot parse "' + spec + '"'); Exit; end;
  locks[0] := 0; locks[1] := 2 {CapsLock}; locks[2] := 16 {NumLock}; locks[3] := 2 or 16;
  for i := 0 to 3 do XGrabKey(HotkeyXDisplay, cint(HotkeyCode), HotkeyMods or locks[i], HotkeyRoot, 1, 1, 1);
  HotkeyOK := True;
  Log('hotkey: ' + spec + ' grabbed');
end;

{ Power Button hotkeys: [{"key":"ctrl+alt+1","cmd":"php …/power_run \"Proofread\" …"}, …], kept in <config>/power_hotkeys.json. A key must be 1-3 modifiers (ctrl, alt, shift, super) and one letter, digit or F1-F12; the command is one line of
  at most 600 characters. Returns how many were grabbed; -1 when this session cannot grab keys (Wayland). }
function PowerKeysApply(const arr: TJSONArray): Integer;
var locks: array[0..3] of cuint; i, j, n: Integer; k: TPowerKey; spec, cmd: string; o: TJSONObject; ok: Boolean; c: Integer;
  function SpecOk(const sp: string): Boolean;
  var parts: TStringList; q, m: Integer; last: string;
  begin
    Result := False; parts := TStringList.Create;
    try
      parts.Delimiter := '+'; parts.StrictDelimiter := True; parts.DelimitedText := LowerCase(sp);
      if (parts.Count < 2) or (parts.Count > 4) then Exit;
      for q := 0 to parts.Count - 2 do if (parts[q] <> 'ctrl') and (parts[q] <> 'alt') and (parts[q] <> 'shift') and (parts[q] <> 'super') then Exit;
      last := parts[parts.Count - 1];
      if Length(last) = 1 then Result := last[1] in ['a'..'z', '0'..'9']
      else if (Length(last) >= 2) and (last[1] = 'f') then begin Val(Copy(last, 2, 2), m, c); Result := (c = 0) and (m >= 1) and (m <= 12); end;
    finally parts.Free; end;
  end;
begin
  Result := -1;
  if not HotkeyBind then Exit;
  locks[0] := 0; locks[1] := 2; locks[2] := 16; locks[3] := 2 or 16;
  for i := 0 to High(PowerKeys) do for j := 0 to 3 do XUngrabKey(HotkeyXDisplay, cint(PowerKeys[i].Code), PowerKeys[i].Mods or locks[j], HotkeyRoot);
  SetLength(PowerKeys, 0); n := 0;
  if arr <> nil then for i := 0 to arr.Count - 1 do begin
    if not (arr.Items[i] is TJSONObject) then Continue;
    o := TJSONObject(arr.Items[i]); spec := Trim(o.Get('key', '')); cmd := o.Get('cmd', '');
    if (spec = '') or (Length(spec) > 40) or not SpecOk(spec) or (cmd = '') or (Length(cmd) > 600) or (Pos(#10, cmd) > 0) or (Pos(#13, cmd) > 0) then begin Log('power hotkey: refused "' + spec + '"'); Continue; end;
    if not ParseHotkey(spec, HotkeyXDisplay, k.Code, k.Mods) then begin Log('power hotkey: cannot parse "' + spec + '"'); Continue; end;
    ok := True; for j := 0 to High(PowerKeys) do if (PowerKeys[j].Code = k.Code) and (PowerKeys[j].Mods = k.Mods) then ok := False;   { one command per key }
    if (k.Code = HotkeyCode) and (k.Mods = HotkeyMods) and HotkeyOK then ok := False;
    if not ok then begin Log('power hotkey: ' + spec + ' is already taken'); Continue; end;
    k.Spec := spec; k.Cmd := cmd; SetLength(PowerKeys, Length(PowerKeys) + 1); PowerKeys[High(PowerKeys)] := k;
    for j := 0 to 3 do XGrabKey(HotkeyXDisplay, cint(k.Code), k.Mods or locks[j], HotkeyRoot, 1, 1, 1);
    Inc(n); Log('power hotkey: ' + spec + ' grabbed');
  end;
  Result := n;
end;

procedure PowerKeysLoad;
var f: string; sl: TStringList; j: TJSONData;
begin
  f := ConfigDir + '/power_hotkeys.json'; if not FileExists(f) then Exit;
  sl := TStringList.Create;
  try
    try sl.LoadFromFile(f); j := GetJSON(sl.Text); except j := nil; end;
    if (j <> nil) and (j is TJSONArray) then PowerKeysApply(TJSONArray(j));
    j.Free;
  finally sl.Free; end;
end;

{ GdkEventWindowState: type, window, send_event, changed_mask, new_window_state;
  GDK_WINDOW_STATE_ICONIFIED = 2. }
function OnWindowState(w: PGtkWidget; ev: Pointer; data: Pointer): gboolean; cdecl;
var st: pcint;
begin
  st := pcint(PByte(ev) + 24);   { new_window_state, after type/window/send_event/changed_mask }
  WinIconified := (st^ and 2) <> 0;
  if RegFile <> '' then RegWrite;   { the window list learns of a minimise at once, not at the next tick }
  Result := 0;
end;

{ ── starting Cockpit from the window ──────────────────────────────────────
  --start CMD makes the shell self-sufficient: if the app URL does not answer,
  the window shows its own boot page (no Apache needed — the HTML is built in
  here), runs CMD once, and polls until the server answers, then loads the app.
  So the window can be launched directly (dock, autostart, the Ctrl+Alt+C
  shortcut) on a machine where nothing is running yet, and the user sees what
  is happening instead of a dead window. On timeout the page says what failed
  and offers Retry (which reloads and starts the poll again). }
function UrlAnswers(const url: string): Boolean;
var p: TProcess; buf: array[0..63] of Byte; n: Integer; s, chunk: string;
begin
  Result := False; s := '';
  p := TProcess.Create(nil);
  try
    p.Executable := 'curl';
    p.Parameters.Add('-s'); p.Parameters.Add('-o'); p.Parameters.Add('/dev/null');
    p.Parameters.Add('-m'); p.Parameters.Add('3');
    p.Parameters.Add('-w'); p.Parameters.Add('%{http_code}');
    p.Parameters.Add(url);
    p.Options := [poUsePipes, poNoConsole];
    try p.Execute; except Exit(False); end;
    repeat
      n := p.Output.Read(buf, SizeOf(buf));
      if n > 0 then begin SetString(chunk, PChar(@buf[0]), n); s := s + chunk; end
      else if p.Running then Sleep(20);
    until (n <= 0) and not p.Running;
  finally p.Free; end;
  s := Trim(s);
  Result := (s <> '') and (s[1] = '2');      { 2xx }
end;

procedure BootPage(const status: string; retry: Boolean);
var html, btn: string;
begin
  btn := '';
  if retry then btn := '<p><button onclick="window.webkit.messageHandlers.cockpit.postMessage(JSON.stringify({id:''r'',cmd:''boot_retry''}))" ' +
    'style="background:#2b6cb0;color:#fff;border:0;border-radius:4px;padding:8px 14px;font:13px system-ui;cursor:pointer">Try again</button></p>';
  html := '<html><head><meta charset="utf-8"><style>body{background:#0f141c;color:#cbd5e0;font:14px system-ui,sans-serif;' +
    'display:flex;align-items:center;justify-content:center;height:100vh;margin:0}div{max-width:520px;padding:28px;text-align:center}' +
    'h1{font-size:17px;margin:0 0 14px;color:#7ecfff;font-weight:600}p{margin:8px 0;color:#a0aec0}code{color:#7ecfff}' +
    '@keyframes b{0%,100%{opacity:.35}50%{opacity:1}}.dot{animation:b 1.4s infinite}</style></head><body><div>' +
    '<h1>AI Cockpit</h1><p id="s" class="dot">' + status + '</p>' + btn + '</div></body></html>';
  if Pointer(webkit_web_view_load_html) <> nil then webkit_web_view_load_html(View, PChar(html), 'about:blank');
end;

procedure BootStatus(const s: string);
begin
  webkit_web_view_run_javascript(View, PChar('var e=document.getElementById("s"); if(e) e.textContent=' + AnsiQuotedStr(s, '"') + ';'), nil, nil, nil);
end;

var BootTries: Integer = 0; BootStarted: Boolean = False;

{ Polls the URL once a second; runs OptStart once, on the first miss. }
function OnBootPoll(data: Pointer): gboolean; cdecl;
begin
  Inc(BootTries);
  if UrlAnswers(OptUrl) then begin
    Log('boot: server answers, loading the app');
    AppShown := True; webkit_web_view_load_uri(View, PChar(OptUrl));
    Exit(0);
  end;
  if (not BootStarted) and (OptStart <> '') then begin
    BootStarted := True;
    Log('boot: running ' + OptStart);
    BootStatus('Starting the web server and the agent sessions…');
    { COCKPIT_INVOKED_FROM_WEB=1: the start script must not open a second window }
    fpSystem('COCKPIT_INVOKED_FROM_WEB=1 setsid ' + OptStart + ' >/dev/null 2>&1 &');
  end
  else if BootTries = 8 then BootStatus('Still starting — the first launch after a reboot takes a moment…');
  if BootTries > OptStartTimeout then begin
    Log('boot: gave up after ' + IntToStr(BootTries) + 's');
    BootPage('Cockpit did not answer at ' + OptUrl + '. Is the web server installed and running? ' +
             'Try <code>cockpit-start</code> in a terminal to see what it says.', True);
    Exit(0);
  end;
  Result := 1;
end;

{ ── direct OS calls ────────────────────────────────────────────────────────
  open_path {path}      → the desktop's own handler (xdg-open), file or folder
  reveal_path {path}    → the file manager with the file selected
  open_terminal {path}  → a terminal already sitting in that directory
  open_tmux {session}   → a terminal attached to a tmux session (Tools' jobs)
  clipboard_files       → absolute paths of files currently on the clipboard
  sysinfo               → CPU load, memory, GPU/VRAM straight from /proc and
                          the GPU driver, with no web-server round trip
  All of them run as the user who owns the window, which is the point: the page
  cannot do any of this, and routing it through PHP means running desktop apps
  as www-data. }
function ShellQuote(const s: string): string;
begin
  Result := '''' + StringReplace(s, '''', '''\''''', [rfReplaceAll]) + '''';
end;

function FirstOnPath(const names: array of string): string;
var i: Integer; d: string;
begin
  for i := 0 to High(names) do
    for d in ['/usr/bin/', '/bin/', '/usr/local/bin/'] do
      if FileExists(d + names[i]) then Exit(d + names[i]);
  Result := '';
end;

function RunCapture(const cmd: string): string;
var p: TProcess; buf: array[0..4095] of Byte; n: Integer; chunk: string;
begin
  Result := '';
  p := TProcess.Create(nil);
  try
    p.Executable := '/bin/sh'; p.Parameters.Add('-c'); p.Parameters.Add(cmd);
    p.Options := [poUsePipes, poNoConsole];
    try p.Execute; except Exit(''); end;
    repeat
      n := p.Output.Read(buf, SizeOf(buf));
      if n > 0 then begin SetString(chunk, PChar(@buf[0]), n); Result := Result + chunk; end
      else if p.Running then Sleep(10);
    until (n <= 0) and not p.Running;
  finally p.Free; end;
end;

{ "MemTotal:       32762152 kB" → 32762152 }
function KbOf(const line: string): Int64;
var i: Integer; d: string;
begin
  d := '';
  for i := 1 to Length(line) do
    if line[i] in ['0'..'9'] then d := d + line[i]
    else if d <> '' then Break;
  Result := StrToInt64Def(d, 0);
end;

{ CPU load since the last call, memory, and GPU/VRAM when the driver exposes it. }
var _lastCpuIdle: Int64 = 0; _lastCpuTotal: Int64 = 0;
function SysInfoJson: TJSONObject;
var sl: TStringList; parts: TStringList; i: Integer; idle, total, v: Int64;
    memTotal, memAvail: Int64; cpuPct: Double; gpu, vram: string; card: string;
begin
  Result := TJSONObject.Create;
  sl := TStringList.Create; parts := TStringList.Create;
  try
    { CPU: /proc/stat first line }
    try sl.LoadFromFile('/proc/stat'); except sl.Clear; end;
    if sl.Count > 0 then begin
      parts.Delimiter := ' '; parts.StrictDelimiter := False; parts.DelimitedText := sl[0];
      idle := 0; total := 0;
      for i := 1 to parts.Count - 1 do begin
        v := StrToInt64Def(parts[i], 0); total := total + v;
        if i = 4 then idle := v;                       { idle column }
      end;
      if (_lastCpuTotal > 0) and (total > _lastCpuTotal) then begin
        cpuPct := 100 * (1 - (idle - _lastCpuIdle) / (total - _lastCpuTotal));
        Result.Add('cpu_pct', Round(cpuPct));
      end;
      _lastCpuIdle := idle; _lastCpuTotal := total;
    end;
    { memory }
    memTotal := 0; memAvail := 0;
    try sl.LoadFromFile('/proc/meminfo'); except sl.Clear; end;
    for i := 0 to sl.Count - 1 do begin
      if Pos('MemTotal:', sl[i]) = 1 then memTotal := KbOf(sl[i]);
      if Pos('MemAvailable:', sl[i]) = 1 then memAvail := KbOf(sl[i]);
    end;
    if memTotal > 0 then begin
      Result.Add('mem_total_mb', memTotal div 1024);
      Result.Add('mem_used_mb', (memTotal - memAvail) div 1024);
    end;
    { GPU: amdgpu/i915 expose busy percent and VRAM in sysfs; NVIDIA needs its tool }
    for card in ['/sys/class/drm/card0/device', '/sys/class/drm/card1/device'] do begin
      if not FileExists(card + '/gpu_busy_percent') then Continue;
      try sl.LoadFromFile(card + '/gpu_busy_percent'); if sl.Count > 0 then gpu := Trim(sl[0]); except end;
      if FileExists(card + '/mem_info_vram_used') then begin
        try sl.LoadFromFile(card + '/mem_info_vram_used'); if sl.Count > 0 then vram := Trim(sl[0]); except end;
        Result.Add('vram_used_mb', StrToInt64Def(vram, 0) div (1024 * 1024));
      end;
      if FileExists(card + '/mem_info_vram_total') then begin
        try sl.LoadFromFile(card + '/mem_info_vram_total'); if sl.Count > 0 then vram := Trim(sl[0]); except end;
        Result.Add('vram_total_mb', StrToInt64Def(vram, 0) div (1024 * 1024));
      end;
      if gpu <> '' then Result.Add('gpu_pct', StrToIntDef(gpu, 0));
      Break;
    end;
  finally sl.Free; parts.Free; end;
end;

{ Clipboard: file managers put URIs on the clipboard, not paths. }
function ClipboardFiles: TStringList;
var tool, out_, line: string; sl: TStringList; i: Integer;
begin
  Result := TStringList.Create;
  tool := FirstOnPath(['xclip']);
  if tool <> '' then out_ := RunCapture(tool + ' -selection clipboard -t text/uri-list -o 2>/dev/null')
  else begin
    tool := FirstOnPath(['wl-paste']);
    if tool = '' then Exit;
    out_ := RunCapture(tool + ' --type text/uri-list 2>/dev/null');
  end;
  sl := TStringList.Create;
  try
    sl.Text := out_;
    for i := 0 to sl.Count - 1 do begin
      line := Trim(sl[i]);
      if Pos('file://', line) <> 1 then Continue;
      line := StringReplace(Copy(line, 8, MaxInt), '%20', ' ', [rfReplaceAll]);
      if FileExists(line) or DirectoryExists(line) then Result.Add(line);
    end;
  finally sl.Free; end;
end;

{ ── window chrome light/dark ────────────────────────────────────────────── }
{ GTK's prefer-dark flag: WebKit turns it into prefers-color-scheme for the page,
  and the page tells us (set_dark) which way its theme went so the chrome matches. }
procedure ApplyDark(on: Boolean);
begin
  gtk_settings_set_long_property(gtk_settings_get_default(), 'gtk-application-prefer-dark-theme', Ord(on), 'cockpit_shell');
end;

{ What the desktop prefers: GNOME color-scheme, a "-dark" GTK theme name, KDE's
  kdeglobals. Read once at start so the page's first paint already knows. }
function DesktopPrefersDark: Boolean;
var o, kde: string; sl: TStringList; i: Integer;
begin
  Result := False;
  { explicit override first (testing, or a desktop that reports the wrong thing) }
  case LowerCase(GetEnvironmentVariable('COCKPIT_SHELL_THEME')) of 'dark': Exit(True); 'light': Exit(False); end;
  if Pos('dark', LowerCase(GetEnvironmentVariable('GTK_THEME'))) > 0 then Exit(True);
  if RunCommand('gsettings', ['get', 'org.gnome.desktop.interface', 'color-scheme'], o, [poNoConsole, poStderrToOutPut]) and (Pos('prefer-dark', o) > 0) then Exit(True);
  if RunCommand('gsettings', ['get', 'org.cinnamon.desktop.interface', 'gtk-theme'], o, [poNoConsole, poStderrToOutPut]) and (Pos('dark', LowerCase(o)) > 0) then Exit(True);
  if RunCommand('gsettings', ['get', 'org.gnome.desktop.interface', 'gtk-theme'], o, [poNoConsole, poStderrToOutPut]) and (Pos('dark', LowerCase(o)) > 0) then Exit(True);
  kde := GetEnvironmentVariable('HOME') + '/.config/kdeglobals';
  if FileExists(kde) then begin
    sl := TStringList.Create;
    try sl.LoadFromFile(kde); for i := 0 to sl.Count - 1 do if (Pos('ColorScheme=', sl[i]) = 1) and (Pos('dark', LowerCase(sl[i])) > 0) then Exit(True); finally sl.Free; end;
  end;
end;

{ ── frameless main window ────────────────────────────────────────────────────
  --frameless (or the page's set_frameless command): the title bar goes; the
  page draws the window controls itself (Exit already exists; it adds minimise
  and maximise) and drags the window by its header (win_drag → GTK's own move
  drag, so the WM does the moving). Only the main window — detached panels keep
  their frames. All bindings here are optional: an older GTK just ignores it. }
type
  T_gtk_window_unmaximize = procedure(w: PGtkWidget); cdecl;
  T_gtk_window_begin_move_drag = procedure(w: PGtkWidget; button: cint; root_x, root_y: cint; timestamp: cuint); cdecl;
  T_gtk_window_begin_resize_drag = procedure(w: PGtkWidget; edge: cint; button: cint; root_x, root_y: cint; timestamp: cuint); cdecl;
  T_gtk_get_current_event_time = function: cuint; cdecl;
  T_gdk_display_get_default_seat = function(d: PGObject): PGObject; cdecl;
  T_gdk_seat_get_pointer = function(s: PGObject): PGObject; cdecl;
  T_gdk_device_get_position = procedure(dev: PGObject; screen: PPointer; x, y: pcint); cdecl;
  T_gtk_widget_get_visible = function(w: PGtkWidget): gboolean; cdecl;
  T_gtk_widget_queue_resize = procedure(w: PGtkWidget); cdecl;
var
  OptFrameless: Boolean = False;
  FramelessBound: Boolean = False;
  gtk_window_unmaximize: T_gtk_window_unmaximize = nil;
  gtk_window_begin_move_drag: T_gtk_window_begin_move_drag = nil;
  gtk_window_begin_resize_drag: T_gtk_window_begin_resize_drag = nil;
  gtk_get_current_event_time: T_gtk_get_current_event_time = nil;
  gdk_display_get_default_seat: T_gdk_display_get_default_seat = nil;
  gdk_seat_get_pointer: T_gdk_seat_get_pointer = nil;
  gdk_device_get_position: T_gdk_device_get_position = nil;
  fl_gdk_display_get_default: T_gdk_display_get_default = nil;
  fl_gtk_widget_get_visible: T_gtk_widget_get_visible = nil;
  gtk_widget_queue_resize: T_gtk_widget_queue_resize = nil;

procedure FramelessBind;
var h, hg: TLibHandle;
begin
  if FramelessBound then Exit; FramelessBound := True;
  h := LoadLibrary(GTK); hg := LoadLibrary('libgdk-3.so.0');
  if h = NilHandle then Exit;
  Pointer(gtk_window_unmaximize) := GetProcAddress(h, 'gtk_window_unmaximize');
  Pointer(gtk_window_begin_move_drag) := GetProcAddress(h, 'gtk_window_begin_move_drag');
  Pointer(gtk_window_begin_resize_drag) := GetProcAddress(h, 'gtk_window_begin_resize_drag');
  Pointer(gtk_get_current_event_time) := GetProcAddress(h, 'gtk_get_current_event_time');
  Pointer(fl_gtk_widget_get_visible) := GetProcAddress(h, 'gtk_widget_get_visible');
  Pointer(gtk_widget_queue_resize) := GetProcAddress(h, 'gtk_widget_queue_resize');
  if hg <> NilHandle then begin
    Pointer(fl_gdk_display_get_default) := GetProcAddress(hg, 'gdk_display_get_default');
    Pointer(gdk_display_get_default_seat) := GetProcAddress(hg, 'gdk_display_get_default_seat');
    Pointer(gdk_seat_get_pointer) := GetProcAddress(hg, 'gdk_seat_get_pointer');
    Pointer(gdk_device_get_position) := GetProcAddress(hg, 'gdk_device_get_position');
  end;
end;

{ Where the pointer is, in root coordinates — what begin_move_drag wants. }
function PointerRoot(out x, y: cint): Boolean;
var d, seat, dev: PGObject;
begin
  Result := False; x := 0; y := 0;
  if (Pointer(fl_gdk_display_get_default) = nil) or (Pointer(gdk_display_get_default_seat) = nil)
     or (Pointer(gdk_seat_get_pointer) = nil) or (Pointer(gdk_device_get_position) = nil) then Exit;
  d := fl_gdk_display_get_default(); if d = nil then Exit;
  seat := gdk_display_get_default_seat(d); if seat = nil then Exit;
  dev := gdk_seat_get_pointer(seat); if dev = nil then Exit;
  gdk_device_get_position(dev, nil, @x, @y); Result := True;
end;

{ ── border strips for the frameless windows that show somebody else's page ───────────────────────────────────────────────────────────────────────────
  The main Cockpit window draws its own handles in the page. The Cockpit Browser and the web worker's login window show other people's sites, which cannot, and a frameless window
  has no edges the window manager could grab. So the shell lays eight thin transparent strips (four sides, four corners) over the page edge, plus a MOVE strip in the middle of each
  side. A press hands the drag to the window manager (begin_resize_drag / begin_move_drag). They live in the shell, not in the page: a site never sees them and cannot talk to them. }
type
  TGdkEventButton = record
    etype: cint; window: Pointer; send_event: cint8; time: cuint32; x, y: Double; axes: Pointer; state: cuint; button: cuint; device: Pointer; x_root, y_root: Double;
  end;
  PGdkEventButton = ^TGdkEventButton;
  T_gtk_overlay_new = function: PGtkWidget; cdecl;
  T_gtk_overlay_add_overlay = procedure(o, w: PGtkWidget); cdecl;
  T_gtk_event_box_new = function: PGtkWidget; cdecl;
  T_gtk_event_box_set_visible_window = procedure(w: PGtkWidget; b: gboolean); cdecl;
  T_gtk_widget_set_align = procedure(w: PGtkWidget; a: cint); cdecl;
  T_gtk_widget_set_size_request = procedure(w: PGtkWidget; x, y: cint); cdecl;
  T_gtk_widget_set_margin = procedure(w: PGtkWidget; m: cint); cdecl;
  T_gtk_widget_add_events = procedure(w: PGtkWidget; ev: cint); cdecl;
  T_gtk_widget_reparent2 = procedure(w, np: PGtkWidget); cdecl;
  T_gdk_cursor_new_from_name = function(display: PGObject; name: PChar): PGObject; cdecl;
  T_gdk_window_set_cursor = procedure(w, c: PGObject); cdecl;
type
  T_gtk_button_new_with_label = function(l: PChar): PGtkWidget; cdecl;
  T_gtk_box_new = function(orient, spacing: cint): PGtkWidget; cdecl;
  T_gtk_widget_set_no_show_all = procedure(w: PGtkWidget; b: gboolean); cdecl;
  T_gtk_widget_show1 = procedure(w: PGtkWidget); cdecl;
  T_gtk_button_set_label = procedure(w: PGtkWidget; l: PChar); cdecl;
  T_gtk_widget_get_allocation = procedure(w: PGtkWidget; a: Pointer); cdecl;
  T_gtk_widget_translate_coordinates = function(src, dest: PGtkWidget; sx, sy: cint; dx, dy: pcint): gboolean; cdecl;
const
  GRIP_MOVE = 8; GRIP_CORNER = 10; GRIP_SIDE = 4; GRIP_MOVEW = 8; GRIP_MOVELEN = 140;
  GTK_ALIGN_FILL = 0; GTK_ALIGN_START = 1; GTK_ALIGN_END = 2; GTK_ALIGN_CENTER = 3;
  GDK_BUTTON_PRESS_MASK = 256;
var
  CtlBox, CtlMaxBtn: PGtkWidget; CtlShown: Boolean = False; CtlOutside: Integer = 0; CtlLogged: Boolean = False; CtlBtns: array[0..2] of PGtkWidget;
  ctl_get_alloc: T_gtk_widget_get_allocation = nil; ctl_translate: T_gtk_widget_translate_coordinates = nil;
  ctl_button_new: T_gtk_button_new_with_label = nil; ctl_box_new: T_gtk_box_new = nil; ctl_no_show_all: T_gtk_widget_set_no_show_all = nil;
  ctl_show: T_gtk_widget_show1 = nil; ctl_hide: T_gtk_widget_show1 = nil; ctl_iconify: T_gtk_widget_show1 = nil; ctl_set_label: T_gtk_button_set_label = nil;
  GripsOverlay: PGtkWidget = nil;
  GripNames: array[0..8] of AnsiString = ('nwse-resize', 'ns-resize', 'nesw-resize', 'ew-resize', 'ew-resize', 'nesw-resize', 'ns-resize', 'nwse-resize', 'move');
  gtk_overlay_new: T_gtk_overlay_new = nil; gtk_overlay_add_overlay: T_gtk_overlay_add_overlay = nil;
  gtk_event_box_new: T_gtk_event_box_new = nil; gtk_event_box_set_visible_window: T_gtk_event_box_set_visible_window = nil;
  gtk_widget_set_halign: T_gtk_widget_set_align = nil; gtk_widget_set_valign: T_gtk_widget_set_align = nil;
  gtk_widget_set_size_request: T_gtk_widget_set_size_request = nil; gtk_widget_set_margin_start: T_gtk_widget_set_margin = nil; gtk_widget_set_margin_end: T_gtk_widget_set_margin = nil;
  gtk_widget_set_margin_top: T_gtk_widget_set_margin = nil; gtk_widget_set_margin_bottom: T_gtk_widget_set_margin = nil; gtk_widget_add_events: T_gtk_widget_add_events = nil;
  grip_reparent: T_gtk_widget_reparent2 = nil; gdk_cursor_new_from_name: T_gdk_cursor_new_from_name = nil; gdk_window_set_cursor: T_gdk_window_set_cursor = nil;

function OnGripPress(w: PGtkWidget; ev: PGdkEventButton; data: Pointer): gboolean; cdecl;
var edge: PtrInt;
begin
  Result := 1; edge := PtrInt(data);
  Log('grip press: edge ' + IntToStr(edge) + ', button ' + IntToStr(ev^.button) + ' at ' + IntToStr(Round(ev^.x_root)) + ',' + IntToStr(Round(ev^.y_root)));
  if ev^.button <> 1 then Exit;
  if (Pointer(gtk_window_is_maximized) <> nil) and (gtk_window_is_maximized(Win) <> 0) then Exit;   { a maximised window is neither resized nor moved by its border }
  if edge = GRIP_MOVE then begin
    if Pointer(gtk_window_begin_move_drag) <> nil then gtk_window_begin_move_drag(Win, 1, Round(ev^.x_root), Round(ev^.y_root), ev^.time);
  end else if Pointer(gtk_window_begin_resize_drag) <> nil then gtk_window_begin_resize_drag(Win, edge, 1, Round(ev^.x_root), Round(ev^.y_root), ev^.time);
end;

procedure OnGripRealize(w: PGtkWidget; data: Pointer); cdecl;
var gw, cur, disp: PGObject;
begin
  if (Pointer(gtk_widget_get_window) = nil) or (Pointer(gdk_cursor_new_from_name) = nil) or (Pointer(gdk_window_set_cursor) = nil) or (Pointer(fl_gdk_display_get_default) = nil) then Exit;
  gw := gtk_widget_get_window(w); disp := fl_gdk_display_get_default(); if (gw = nil) or (disp = nil) then Exit;
  cur := gdk_cursor_new_from_name(disp, PChar(GripNames[PtrInt(data)])); if cur <> nil then gdk_window_set_cursor(gw, cur);
end;

{ Window buttons (minimise, maximise / restore, close) for the same frameless windows: the page cannot draw them and there is no title bar. They appear when the pointer reaches the
  top-right corner of the window and go again when it leaves (polled every 150 ms against the pointer's place on the screen: no event bookkeeping, nothing a page can see). }
procedure CtlSync;
begin
  if (CtlMaxBtn <> nil) and (Pointer(ctl_set_label) <> nil) and (Pointer(gtk_window_is_maximized) <> nil) then
    if gtk_window_is_maximized(Win) <> 0 then ctl_set_label(CtlMaxBtn, PChar('❐')) else ctl_set_label(CtlMaxBtn, PChar('□'));
end;

procedure OnCtlClick(b: PGtkWidget; data: Pointer); cdecl;
begin
  Log('window button ' + IntToStr(PtrInt(data)) + ' clicked');
  case PtrInt(data) of
    0: if Pointer(ctl_iconify) <> nil then ctl_iconify(Win);
    1: if (Pointer(gtk_window_is_maximized) <> nil) and (gtk_window_is_maximized(Win) <> 0) then begin if Pointer(gtk_window_unmaximize) <> nil then gtk_window_unmaximize(Win); end else gtk_window_maximize(Win);
    2: if OptWorker <> '' then WorkerHide else if OptBrowser then QuitApp else OnDelete(Win, nil, nil);   { the main window: the page's own exit procedure, as for the WM's close button }
  end;
  CtlSync;
end;

function OnCtlPoll(data: Pointer): gboolean; cdecl;
var px, py, wx, wy, ww, wh: cint; inside: Boolean; i: Integer; al: array[0..3] of cint; tx, ty: cint;
begin
  Result := 1;
  if CtlBox = nil then Exit;
  if (OptWorker <> '') and not WorkerShown then begin if CtlShown then begin ctl_hide(CtlBox); CtlShown := False; end; Exit; end;
  if (Pointer(gtk_window_get_position) = nil) or (Pointer(gtk_window_get_size) = nil) or not PointerRoot(px, py) then Exit;
  wx := 0; wy := 0; ww := 0; wh := 0; gtk_window_get_position(Win, @wx, @wy); gtk_window_get_size(Win, @ww, @wh);
  if OptBrowser then inside := (px >= wx + ww - 180) and (px <= wx + ww) and (py >= wy) and (py <= wy + 48)
  else begin
    { the main window: its page already fills that corner (the Settings buttons), so the buttons come up only when the pointer reaches the empty strip along the right edge, and stay while the pointer is on them }
    if not FramelessApplied then inside := False
    else inside := ((px >= wx + ww - 14) and (px <= wx + ww) and (py >= wy) and (py <= wy + 44)) or (CtlShown and (px >= wx + ww - 172) and (px <= wx + ww) and (py >= wy) and (py <= wy + 52));
  end;
  if CtlShown and (not CtlLogged) and (Pointer(ctl_get_alloc) <> nil) then begin
    CtlLogged := True;
    { each overlay child has its own sub-window, so allocations are relative to it: ask GTK for the place in the WINDOW }
    for i := 0 to 2 do begin
      FillChar(al, SizeOf(al), 0); ctl_get_alloc(CtlBtns[i], @al); tx := 0; ty := 0;
      if (Pointer(ctl_translate) <> nil) and (ctl_translate(CtlBtns[i], Win, 0, 0, @tx, @ty) <> 0) then Log('window button ' + IntToStr(i) + ' at ' + IntToStr(tx) + ',' + IntToStr(ty) + ' size ' + IntToStr(al[2]) + 'x' + IntToStr(al[3]));
    end;
  end;
  if inside then begin
    CtlOutside := 0;
    if not CtlShown then begin ctl_show(CtlBox); CtlShown := True; CtlSync; Log('window buttons shown'); end;
  end else if CtlShown then begin
    Inc(CtlOutside); if CtlOutside >= 3 then begin ctl_hide(CtlBox); CtlShown := False; CtlLogged := False; end;
  end;
end;

{ The ⚡ menu of a Browser window: the Power Buttons that work on what is selected (the list is written by Cockpit to <config>/power_menu.json). Picking one runs its command line, which
  reads the X selection (the text selected in this page is the PRIMARY selection) and puts the answer where that button says. }
var PowerMenuCmds: array of string; PowerBtn: PGtkWidget = nil;

procedure OnPowerPick(item: PGtkWidget; data: Pointer); cdecl;
var i: PtrInt;
begin
  i := PtrInt(data);
  if (i >= 0) and (i <= High(PowerMenuCmds)) then begin Log('power menu: running item ' + IntToStr(i)); fpSystem('setsid bash -c ' + ShellQuote(PowerMenuCmds[i]) + ' >/dev/null 2>&1 &'); end;
end;

procedure OnPowerClick(b: PGtkWidget; data: Pointer); cdecl;
type
  T_menu_new = function: PGtkWidget; cdecl; T_item_new = function(l: PChar): PGtkWidget; cdecl; T_append = procedure(m, it: PGtkWidget); cdecl;
  T_popup = procedure(m, w: PGtkWidget; wa, ma: cint; ev: Pointer); cdecl; T_sens = procedure(w: PGtkWidget; s: cint); cdecl;
var h: TLibHandle; mnew: T_menu_new; inew: T_item_new; app: T_append; pop: T_popup; sens: T_sens; menu, it: PGtkWidget; sl: TStringList; j: TJSONData; a: TJSONArray; o: TJSONObject; i, n: Integer; nm, cmd: string;
begin
  h := LoadLibrary(GTK); if h = NilHandle then Exit;
  Pointer(mnew) := GetProcAddress(h, 'gtk_menu_new'); Pointer(inew) := GetProcAddress(h, 'gtk_menu_item_new_with_label'); Pointer(app) := GetProcAddress(h, 'gtk_menu_shell_append');
  Pointer(pop) := GetProcAddress(h, 'gtk_menu_popup_at_widget'); Pointer(sens) := GetProcAddress(h, 'gtk_widget_set_sensitive');
  if (Pointer(mnew) = nil) or (Pointer(inew) = nil) or (Pointer(app) = nil) or (Pointer(pop) = nil) or (Pointer(sens) = nil) then Exit;
  SetLength(PowerMenuCmds, 0); menu := mnew(); n := 0; j := nil;
  if FileExists(ConfigDir + '/power_menu.json') then begin
    sl := TStringList.Create;
    try try sl.LoadFromFile(ConfigDir + '/power_menu.json'); j := GetJSON(sl.Text); except j := nil; end; finally sl.Free; end;
  end;
  if (j <> nil) and (j is TJSONArray) then begin
    a := TJSONArray(j);
    for i := 0 to a.Count - 1 do if a.Items[i] is TJSONObject then begin
      o := TJSONObject(a.Items[i]); nm := o.Get('name', ''); cmd := o.Get('cmd', '');
      if (nm = '') or (cmd = '') or (Length(cmd) > 600) or (Pos(#10, cmd) > 0) or (n >= 30) then Continue;
      SetLength(PowerMenuCmds, n + 1); PowerMenuCmds[n] := cmd;
      it := inew(PChar(nm)); app(menu, it); g_signal_connect_data(it, 'activate', @OnPowerPick, Pointer(PtrInt(n)), nil, 0); Inc(n);
    end;
  end;
  j.Free;
  if n = 0 then begin it := inew(PChar('No Power Buttons yet: add some in Cockpit')); sens(it, 0); app(menu, it); end;
  gtk_widget_show_all(menu);
  pop(menu, b, 6 {south west of the button}, 5 {north west of the menu}, nil);
  Log('power menu opened with ' + IntToStr(n) + ' items');
end;

{ Put the page inside an overlay that carries the strips. Returns False (and changes nothing) when this GTK lacks a piece. }
function GripsInstall(WithStrips: Boolean): Boolean;
var h: TLibHandle; i: Integer; gripBtn: PGtkWidget;
  function Strip(edge: Integer; ha, va, w, hh, ms, me, mt, mb: Integer): PGtkWidget;
  begin
    Result := gtk_event_box_new();
    gtk_event_box_set_visible_window(Result, 0); gtk_widget_set_halign(Result, ha); gtk_widget_set_valign(Result, va);
    gtk_widget_set_size_request(Result, w, hh);
    gtk_widget_set_margin_start(Result, ms); gtk_widget_set_margin_end(Result, me); gtk_widget_set_margin_top(Result, mt); gtk_widget_set_margin_bottom(Result, mb);
    gtk_widget_add_events(Result, GDK_BUTTON_PRESS_MASK);
    g_signal_connect_data(Result, 'button-press-event', @OnGripPress, Pointer(PtrInt(edge)), nil, 0);
    g_signal_connect_data(Result, 'realize', @OnGripRealize, Pointer(PtrInt(edge)), nil, 0);
    gtk_overlay_add_overlay(GripsOverlay, Result);
  end;
begin
  Result := False; if GripsOverlay <> nil then Exit(True);
  FramelessBind; h := LoadLibrary(GTK); if h = NilHandle then Exit;
  Pointer(gtk_overlay_new) := GetProcAddress(h, 'gtk_overlay_new'); Pointer(gtk_overlay_add_overlay) := GetProcAddress(h, 'gtk_overlay_add_overlay');
  Pointer(gtk_event_box_new) := GetProcAddress(h, 'gtk_event_box_new'); Pointer(gtk_event_box_set_visible_window) := GetProcAddress(h, 'gtk_event_box_set_visible_window');
  Pointer(gtk_widget_set_halign) := GetProcAddress(h, 'gtk_widget_set_halign'); Pointer(gtk_widget_set_valign) := GetProcAddress(h, 'gtk_widget_set_valign');
  Pointer(gtk_widget_set_size_request) := GetProcAddress(h, 'gtk_widget_set_size_request');
  Pointer(gtk_widget_set_margin_start) := GetProcAddress(h, 'gtk_widget_set_margin_start'); Pointer(gtk_widget_set_margin_end) := GetProcAddress(h, 'gtk_widget_set_margin_end');
  Pointer(gtk_widget_set_margin_top) := GetProcAddress(h, 'gtk_widget_set_margin_top'); Pointer(gtk_widget_set_margin_bottom) := GetProcAddress(h, 'gtk_widget_set_margin_bottom');
  Pointer(gtk_widget_add_events) := GetProcAddress(h, 'gtk_widget_add_events'); Pointer(grip_reparent) := GetProcAddress(h, 'gtk_widget_reparent');
  if Pointer(gtk_widget_get_window) = nil then Pointer(gtk_widget_get_window) := GetProcAddress(h, 'gtk_widget_get_window');
  Pointer(gdk_cursor_new_from_name) := GetProcAddress(LoadLibrary('libgdk-3.so.0'), 'gdk_cursor_new_from_name'); Pointer(gdk_window_set_cursor) := GetProcAddress(LoadLibrary('libgdk-3.so.0'), 'gdk_window_set_cursor');
  if (Pointer(gtk_overlay_new) = nil) or (Pointer(gtk_overlay_add_overlay) = nil) or (Pointer(gtk_event_box_new) = nil) or (Pointer(gtk_event_box_set_visible_window) = nil)
     or (Pointer(gtk_widget_set_halign) = nil) or (Pointer(gtk_widget_set_valign) = nil) or (Pointer(gtk_widget_set_size_request) = nil) or (Pointer(gtk_widget_set_margin_start) = nil)
     or (Pointer(gtk_widget_set_margin_end) = nil) or (Pointer(gtk_widget_set_margin_top) = nil) or (Pointer(gtk_widget_set_margin_bottom) = nil) or (Pointer(gtk_widget_add_events) = nil)
     or (Pointer(grip_reparent) = nil) or (Pointer(gtk_window_begin_resize_drag) = nil) then begin Log('border strips: this GTK lacks a piece, the window stays without them'); Exit; end;
  GripsOverlay := gtk_overlay_new();
  grip_reparent(View, GripsOverlay);   { out of the window, in as the overlay's main child }
  gtk_container_add(Win, GripsOverlay);
  ViewHost := GripsOverlay;
  if WithStrips then begin   { the main window draws its own handles in the page: it gets the overlay and the buttons only }
  { the four sides first (full length, leaving the corners), then the corners, then the MOVE strip over the middle of each side }
  Strip(1, GTK_ALIGN_FILL, GTK_ALIGN_START, -1, GRIP_SIDE, GRIP_CORNER, GRIP_CORNER, 0, 0);
  Strip(6, GTK_ALIGN_FILL, GTK_ALIGN_END, -1, GRIP_SIDE, GRIP_CORNER, GRIP_CORNER, 0, 0);
  Strip(3, GTK_ALIGN_START, GTK_ALIGN_FILL, GRIP_SIDE, -1, 0, 0, GRIP_CORNER, GRIP_CORNER);
  Strip(4, GTK_ALIGN_END, GTK_ALIGN_FILL, GRIP_SIDE, -1, 0, 0, GRIP_CORNER, GRIP_CORNER);
  Strip(0, GTK_ALIGN_START, GTK_ALIGN_START, GRIP_CORNER, GRIP_CORNER, 0, 0, 0, 0);
  Strip(2, GTK_ALIGN_END, GTK_ALIGN_START, GRIP_CORNER, GRIP_CORNER, 0, 0, 0, 0);
  Strip(5, GTK_ALIGN_START, GTK_ALIGN_END, GRIP_CORNER, GRIP_CORNER, 0, 0, 0, 0);
  Strip(7, GTK_ALIGN_END, GTK_ALIGN_END, GRIP_CORNER, GRIP_CORNER, 0, 0, 0, 0);
  Strip(GRIP_MOVE, GTK_ALIGN_CENTER, GTK_ALIGN_START, GRIP_MOVELEN, GRIP_MOVEW, 0, 0, 0, 0);
  Strip(GRIP_MOVE, GTK_ALIGN_CENTER, GTK_ALIGN_END, GRIP_MOVELEN, GRIP_MOVEW, 0, 0, 0, 0);
  Strip(GRIP_MOVE, GTK_ALIGN_START, GTK_ALIGN_CENTER, GRIP_MOVEW, GRIP_MOVELEN, 0, 0, 0, 0);
  Strip(GRIP_MOVE, GTK_ALIGN_END, GTK_ALIGN_CENTER, GRIP_MOVEW, GRIP_MOVELEN, 0, 0, 0, 0);
  end;
  { the window buttons: hidden until the pointer reaches the top-right corner }
  h := LoadLibrary(GTK);
  Pointer(ctl_button_new) := GetProcAddress(h, 'gtk_button_new_with_label'); Pointer(ctl_box_new) := GetProcAddress(h, 'gtk_box_new'); Pointer(ctl_no_show_all) := GetProcAddress(h, 'gtk_widget_set_no_show_all');
  Pointer(ctl_show) := GetProcAddress(h, 'gtk_widget_show'); Pointer(ctl_hide) := GetProcAddress(h, 'gtk_widget_hide'); Pointer(ctl_iconify) := GetProcAddress(h, 'gtk_window_iconify');
  Pointer(ctl_set_label) := GetProcAddress(h, 'gtk_button_set_label'); Pointer(ctl_get_alloc) := GetProcAddress(h, 'gtk_widget_get_allocation'); Pointer(ctl_translate) := GetProcAddress(h, 'gtk_widget_translate_coordinates');
  if (Pointer(ctl_button_new) <> nil) and (Pointer(ctl_box_new) <> nil) and (Pointer(ctl_no_show_all) <> nil) and (Pointer(ctl_show) <> nil) and (Pointer(ctl_hide) <> nil) and (Pointer(ctl_iconify) <> nil) and (Pointer(ctl_set_label) <> nil) then begin
    CtlBox := ctl_box_new(0, 2);
    gtk_widget_set_halign(CtlBox, GTK_ALIGN_END); gtk_widget_set_valign(CtlBox, GTK_ALIGN_START);
    gtk_widget_set_margin_end(CtlBox, 8); gtk_widget_set_margin_top(CtlBox, 6);
    if OptBrowser then begin   { a Browser window also gets the ⚡ Power Buttons menu, first in the row }
      PowerBtn := ctl_button_new(PChar('⚡')); gtk_widget_set_size_request(PowerBtn, 30, 24);
      g_signal_connect_data(PowerBtn, 'clicked', @OnPowerClick, nil, nil, 0); gtk_container_add(CtlBox, PowerBtn); ctl_show(PowerBtn);
    end;
    for i := 0 to 2 do begin
      case i of 0: gripBtn := ctl_button_new(PChar('–')); 1: begin gripBtn := ctl_button_new(PChar('□')); CtlMaxBtn := gripBtn; end; else gripBtn := ctl_button_new(PChar('×')); end;
      CtlBtns[i] := gripBtn;
      gtk_widget_set_size_request(gripBtn, 30, 24);
      g_signal_connect_data(gripBtn, 'clicked', @OnCtlClick, Pointer(PtrInt(i)), nil, 0);
      gtk_container_add(CtlBox, gripBtn);
      ctl_show(gripBtn);   { each button is shown now; only the box stays hidden until the pointer reaches the corner }
    end;
    ctl_no_show_all(CtlBox, 1);   { show_all of the window must not bring them up: the poll does }
    gtk_overlay_add_overlay(GripsOverlay, CtlBox);
    g_timeout_add(150, @OnCtlPoll, nil);
  end;
  Result := True; Log(BoolToStr(WithStrips, 'border strips installed', 'window buttons installed (main window)'));
end;

procedure FramelessSave(on: Boolean);
var f: TextFile;
begin
  try ForceDirectories(ConfigDir); AssignFile(f, ConfigDir + '/frameless'); Rewrite(f); writeln(f, BoolToStr(on, 'on', 'off')); CloseFile(f); except end;
end;

{ The saved choice (Settings → Window); --frameless on the command line wins for that run. }
function FramelessSaved: Boolean;
var f: TextFile; s: string;
begin
  Result := False;
  if not FileExists(ConfigDir + '/frameless') then Exit;
  try AssignFile(f, ConfigDir + '/frameless'); Reset(f); readln(f, s); CloseFile(f); Result := Trim(s) = 'on'; except end;
end;


procedure ApplyFrameless(on: Boolean);
var NudgeW, NudgeH: cint;
begin
  OptFrameless := on; FramelessSave(on);
  if Pointer(gtk_window_set_decorated) = nil then Exit;
  { Wayland: the compositor settles decorations when the window is first mapped
    (KWin kept its title bar on the Manjaro VM) — save only, the note says Reopen. }
  if (GetEnvironmentVariable('WAYLAND_DISPLAY') <> '') and (LowerCase(GetEnvironmentVariable('GDK_BACKEND')) <> 'x11') then begin
    Log('frameless: ' + BoolToStr(on, 'on', 'off') + ' (Wayland: applies on reopen)'); Exit;
  end;
  { Live: set the hint and let the WM re-frame (Mutter/Cinnamon/KWin do), then ask
    for a relayout. No hide/show — re-mapping left WebKit's surface unpainted.
    (The 100% CPU that followed the toggle in b70–b72 was the SIGUSR1 livelock,
    not this.) Where a WM does not re-frame a mapped window: Reopen. }
  gtk_window_set_decorated(Win, Ord(not on));
  if Pointer(gtk_widget_queue_resize) <> nil then gtk_widget_queue_resize(Win);
  { queue_resize alone was not enough on the FIRST toggle: the frame changed but
    WebKit kept presenting its old surface, so the page looked frozen until you
    toggled back (and the second toggle then worked, because by then the surface
    had been recreated). Reported 2026-09-26. A one-pixel size change forces the
    compositor to hand WebKit a new surface; it is set back immediately, so
    nothing moves on screen and the saved geometry is untouched. }
  if (Pointer(gtk_window_get_size) <> nil) and (Pointer(gtk_window_resize) <> nil) then begin
    gtk_window_get_size(Win, @NudgeW, @NudgeH);
    if (NudgeW > 1) and (NudgeH > 1) then begin
      gtk_window_resize(Win, NudgeW + 1, NudgeH);
      gtk_window_resize(Win, NudgeW, NudgeH);
    end;
  end;
  FramelessApplied := on;
  Log('frameless: ' + BoolToStr(on, 'on', 'off'));
end;

{ Page commands: set_frameless {on} · win_minimize · win_maximize (toggle) ·
  win_drag · win_resize {edge: 0..7 as GdkWindowEdge, default south-east=7}. }
function OnReopenQuit(data: Pointer): gboolean; cdecl;
begin
  Log('win_reopen: closing; cockpit_start reopens'); gtk_main_quit; Result := 0;
end;

{ ── the window list ────────────────────────────────────────────────────────
  Every Cockpit Browser window (own process) keeps one small file, <pid>.json, in a folder only its owner can enter (title, address, minimised or not), and obeys <pid>.cmd
  ("restore" or "close"). The main window lists the minimised ones in its status bar and writes those commands. Nothing leaves the machine and no page can reach it:
  the files are written by the shell, never by a page. A file whose process is gone is deleted when it is seen. }
function RegDir: string;
var d: string;
begin
  d := GetEnvironmentVariable('XDG_RUNTIME_DIR'); if (d = '') or not DirectoryExists(d) then d := '/tmp';
  Result := d + '/cockpit-windows-' + IntToStr(fpGetUID);
  if not DirectoryExists(Result) then begin ForceDirectories(Result); FpChmod(Result, &700); end;
end;

{ The time of the X server: a window that asks to be shown with a time the window manager knows is recent is obeyed; with time 0 (a timer, no key press behind it) mutter leaves it minimised. }
function XServerTime: cuint;
var gst: function(w: Pointer): cuint; cdecl; gww: T_gtk_widget_get_window; h: TLibHandle;
begin
  Result := 0; Pointer(gst) := nil; Pointer(gww) := nil;
  h := LoadLibrary('libgdk-3.so.0'); if h <> 0 then Pointer(gst) := GetProcAddress(h, 'gdk_x11_get_server_time');
  h := LoadLibrary(GTK); if h <> 0 then Pointer(gww) := GetProcAddress(h, 'gtk_widget_get_window');
  if (Pointer(gst) <> nil) and (Pointer(gww) <> nil) then Result := gst(gww(Win));
end;

procedure RegWrite;
var o: TJSONObject; s: string; sl: TStringList; t, u: PChar;
begin
  t := webkit_web_view_get_title(View); u := webkit_web_view_get_uri(View);
  o := TJSONObject.Create(['pid', Integer(GetProcessID), 'title', StrPas(t), 'url', StrPas(u), 'min', WinIconified]);
  s := o.AsJSON; o.Free;
  if s <> RegLast then begin
    sl := TStringList.Create;
    try sl.Text := s; try sl.SaveToFile(RegFile + '.tmp'); FpChmod(RegFile + '.tmp', &600); RenameFile(RegFile + '.tmp', RegFile); RegLast := s; except end; finally sl.Free; end;
  end;
end;

function OnRegPoll(data: Pointer): gboolean; cdecl;
var cf, act: string; sl: TStringList;
begin
  Result := 1;
  RegWrite;
  cf := ChangeFileExt(RegFile, '.cmd');
  if FileExists(cf) then begin
    act := '';
    sl := TStringList.Create;
    try try sl.LoadFromFile(cf); act := Trim(sl.Text); except end; finally sl.Free; end;
    DeleteFile(cf);
    FramelessBind;
    if act = 'restore' then begin if Pointer(gtk_window_deiconify) <> nil then gtk_window_deiconify(Win); if Pointer(gtk_window_present_with_time) = nil then Pointer(gtk_window_present_with_time) := GetProcAddress(LoadLibrary(GTK), 'gtk_window_present_with_time');
      if Pointer(gtk_window_present_with_time) <> nil then gtk_window_present_with_time(Win, XServerTime) else if Pointer(gtk_window_present) <> nil then gtk_window_present(Win); Log('window list: restored'); end
    else if act = 'close' then begin Log('window list: closed'); QuitApp; end;
  end;
end;

procedure WinListHandle(const id: string);
var sr: TSearchRec; arr: TJSONArray; j: TJSONData; sl: TStringList; fn: string; pid: Integer; rep: TJSONObject;
begin
  arr := TJSONArray.Create;
  if FindFirst(RegDir + '/*.json', faAnyFile, sr) = 0 then begin
    repeat
      fn := RegDir + '/' + sr.Name; j := nil;
      sl := TStringList.Create;
      try try sl.LoadFromFile(fn); j := GetJSON(sl.Text); except j := nil; end; finally sl.Free; end;
      if (j = nil) or not (j is TJSONObject) then begin j.Free; Continue; end;
      pid := TJSONObject(j).Get('pid', 0);
      if (pid <= 0) or ((FpKill(pid, 0) <> 0) and (fpgeterrno <> ESysEPERM)) then begin DeleteFile(fn); DeleteFile(ChangeFileExt(fn, '.cmd')); j.Free; Continue; end;
      if TJSONObject(j).Get('min', False) then arr.Add(j) else j.Free;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  rep := TJSONObject.Create(['id', id, 'ok', True, 'wins', arr]);
  try PageReply(rep); finally rep.Free; end;
end;

procedure WinCmdHandle(const req: TJSONObject);
var pid: Integer; act, p: string; sl: TStringList; rep: TJSONObject;
begin
  pid := req.Get('pid', 0); act := req.Get('action', '');
  p := RegDir + '/' + IntToStr(pid);
  if (pid > 0) and ((act = 'restore') or (act = 'close')) and FileExists(p + '.json') then begin
    sl := TStringList.Create;
    try sl.Text := act; try sl.SaveToFile(p + '.cmd'); FpChmod(p + '.cmd', &600); except end; finally sl.Free; end;
    rep := TJSONObject.Create(['id', req.Get('id', ''), 'ok', True]);
  end else rep := TJSONObject.Create(['id', req.Get('id', ''), 'ok', False, 'error', 'no such window']);
  try PageReply(rep); finally rep.Free; end;
end;

function FramelessHandle(const req: TJSONObject): Boolean;
var id, cmd: string; rep: TJSONObject; x, y: cint; t: cuint; edge: Integer;
begin
  Result := True; id := req.Get('id', ''); cmd := req.Get('cmd', '');
  FramelessBind;
  t := 0; if Pointer(gtk_get_current_event_time) <> nil then t := gtk_get_current_event_time();
  if cmd = 'set_frameless' then ApplyFrameless(req.Get('on', True))
  else if cmd = 'win_minimize' then begin if Pointer(gtk_window_iconify) <> nil then gtk_window_iconify(Win); end
  else if cmd = 'win_maximize' then begin
    if (Pointer(gtk_window_is_maximized) <> nil) and (gtk_window_is_maximized(Win) <> 0) then begin
      if Pointer(gtk_window_unmaximize) <> nil then gtk_window_unmaximize(Win);
    end else gtk_window_maximize(Win);
  end
  else if cmd = 'win_drag' then begin
    if (Pointer(gtk_window_begin_move_drag) <> nil) and PointerRoot(x, y) then gtk_window_begin_move_drag(Win, 1, x, y, t);
  end
  else if cmd = 'win_resize' then begin
    edge := req.Get('edge', 7);
    if (Pointer(gtk_window_begin_resize_drag) <> nil) and PointerRoot(x, y) then gtk_window_begin_resize_drag(Win, edge, 1, x, y, t);
  end
  else if cmd = 'win_list' then begin WinListHandle(id); Exit; end
  else if cmd = 'win_cmd' then begin WinCmdHandle(req); Exit; end
  else if cmd = 'win_state' then begin end   { just the reply: frameless? maximized? }
  else if cmd = 'win_reload_hard' then begin
    rep := TJSONObject.Create(['id', id, 'ok', True]); try PageReply(rep); finally rep.Free; end;
    if (View <> nil) and (Pointer(webkit_web_view_reload_bypass_cache) <> nil) then webkit_web_view_reload_bypass_cache(View);
    Exit;
  end
  else if cmd = 'win_reopen' then begin
    { the window restarts itself: cockpit_start (--start CMD) opens a new one once this is gone; sessions untouched }
    { Spawned from inside a GTK process the child inherits its open fds (GLib wakeup
      pipes, X and D-Bus sockets) — the reopened window then spun at 100% CPU (b70,
      the rig). Close every fd above 2 before the new cockpit_start runs. }
    { wait for THIS process to be gone first: started 0.7 s in, cockpit_start still saw the dying window, raised it and exited — nothing came back (b81) }
    if OptStart <> '' then fpSystem('setsid bash -c ' + ShellQuote('for fd in $(ls /proc/$$/fd); do [ "$fd" -gt 2 ] && eval "exec $fd>&-"; done 2>/dev/null; while kill -0 ' + IntToStr(GetProcessID) + ' 2>/dev/null; do sleep 0.2; done; exec ' + OptStart) + ' >/dev/null 2>&1 < /dev/null &');
    rep := TJSONObject.Create(['id', id, 'ok', True]); try PageReply(rep); finally rep.Free; end;
    g_timeout_add(300, @OnReopenQuit, nil); Exit;
  end
  else begin Result := False; Exit; end;
  rep := TJSONObject.Create(['id', id, 'ok', True, 'frameless', FramelessApplied, 'wanted', OptFrameless, 'pending', OptFrameless <> FramelessApplied,
           'maximized', (Pointer(gtk_window_is_maximized) <> nil) and (gtk_window_is_maximized(Win) <> 0)]);
  try PageReply(rep); finally rep.Free; end;
end;

{ a name that matches a pattern (no regex unit in this build: the few shapes used are checked by hand) }
function NameOk(const nm, pat: string): Boolean;
var i: Integer; okc: Boolean; pre: string;
begin
  Result := False;
  if (nm = '') or (Length(nm) > 90) or (Pos('/', nm) > 0) or (Pos('..', nm) > 0) or (nm[1] = '.') then Exit;
  if Pos('desktop', pat) > 0 then begin
    if (Pos('cockpit-power-', nm) <> 1) or (RightStr(nm, 8) <> '.desktop') or (Length(nm) < 23) then Exit;
    for i := 15 to Length(nm) - 8 do begin okc := nm[i] in ['a'..'z', '0'..'9', '_', '-']; if not okc then Exit; end; Result := True;
  end else begin
    pre := 'Cockpit - '; if (Pos(pre, nm) <> 1) or (Length(nm) = Length(pre)) then Exit;
    for i := Length(pre) + 1 to Length(nm) do begin okc := nm[i] in ['a'..'z', 'A'..'Z', '0'..'9', ' ', '.', '_', '(', ')', '-']; if not okc then Exit; end; Result := True;
  end;
end;

procedure OsHandle(const req: TJSONObject);
var id, cmd, path, term, sess, dir, kind, fname, body: string; rep: TJSONObject; files: TStringList; j: TJSONData; n: Integer; sl: TStringList; mode: cint;
begin
  id := req.Get('id', ''); cmd := req.Get('cmd', ''); path := req.Get('path', '');
  { set_dark {on}: the page applied a dark/light theme — the window chrome follows }
  if cmd = 'set_dark' then begin
    ApplyDark(req.Get('on', True));
    rep := TJSONObject.Create(['id', id, 'ok', True]); try PageReply(rep); finally rep.Free; end; Exit;
  end;
  if cmd = 'sysinfo' then begin
    rep := SysInfoJson; rep.Add('id', id); rep.Add('ok', True);
    try PageReply(rep); finally rep.Free; end; Exit;
  end;
  if cmd = 'clipboard_files' then begin
    files := ClipboardFiles;
    try JsonStringArrayReply(id, 'paths', files); finally files.Free; end; Exit;
  end;
  if (cmd = 'open_path') or (cmd = 'reveal_path') or (cmd = 'open_terminal') then begin
    if (path = '') or ((not FileExists(path)) and (not DirectoryExists(path))) then begin ReplyError(id, 'path not found'); Exit; end;
    if cmd = 'open_path' then fpSystem('xdg-open ' + ShellQuote(path) + ' >/dev/null 2>&1 &')
    else if cmd = 'reveal_path' then begin
      term := FirstOnPath(['nemo', 'nautilus', 'dolphin', 'thunar', 'caja', 'pcmanfm']);
      if term = '' then fpSystem('xdg-open ' + ShellQuote(ExtractFileDir(path)) + ' >/dev/null 2>&1 &')
      else fpSystem(term + ' ' + ShellQuote(path) + ' >/dev/null 2>&1 &');   { these select the file }
    end else begin
      dir := path; if not DirectoryExists(dir) then dir := ExtractFileDir(dir);
      term := FirstOnPath(['gnome-terminal', 'konsole', 'xfce4-terminal', 'mate-terminal', 'tilix', 'kitty', 'alacritty', 'xterm']);
      if term = '' then begin ReplyError(id, 'no terminal emulator found'); Exit; end;
      if Pos('gnome-terminal', term) > 0 then fpSystem(term + ' --working-directory=' + ShellQuote(dir) + ' >/dev/null 2>&1 &')
      else if Pos('konsole', term) > 0 then fpSystem(term + ' --workdir ' + ShellQuote(dir) + ' >/dev/null 2>&1 &')
      else if Pos('xfce4-terminal', term) > 0 then fpSystem(term + ' --working-directory=' + ShellQuote(dir) + ' >/dev/null 2>&1 &')
      else fpSystem('cd ' + ShellQuote(dir) + ' && ' + term + ' >/dev/null 2>&1 &');
    end;
    rep := TJSONObject.Create(['id', id, 'ok', True]);
    try PageReply(rep); finally rep.Free; end; Exit;
  end;
  { power_hotkeys_set {hotkeys:[{key,cmd}], menu:[{name,cmd}]}: the Power Buttons panel hands over what to grab globally and what the ⚡ menu of Browser windows lists }
  if cmd = 'open_power_sync' then begin
    j := req.Find('hotkeys'); n := -2;
    try
      ForceDirectories(ConfigDir);
      if (j <> nil) and (j is TJSONArray) then begin
        sl := TStringList.Create; try sl.Text := j.AsJSON; sl.SaveToFile(ConfigDir + '/power_hotkeys.json'); finally sl.Free; end;
        n := PowerKeysApply(TJSONArray(j));
      end;
      j := req.Find('menu');
      if (j <> nil) and (j is TJSONArray) then begin sl := TStringList.Create; try sl.Text := j.AsJSON; sl.SaveToFile(ConfigDir + '/power_menu.json'); finally sl.Free; end; end;
    except on E: Exception do begin ReplyError(id, 'could not save: ' + E.Message); Exit; end; end;
    rep := TJSONObject.Create(['id', id, 'ok', True, 'grabbed', n, 'wayland', GetEnvironmentVariable('WAYLAND_DISPLAY') <> '']);
    try PageReply(rep); finally rep.Free; end; Exit;
  end;
  { open_install_file {kind, name, content}: a launcher, a file-manager action or the cockpit-run tool, written only where that kind belongs and only under a fixed name pattern }
  if cmd = 'open_install_file' then begin
    kind := req.Get('kind', ''); fname := req.Get('name', ''); body := req.Get('content', ''); dir := ''; mode := &755;
    if (Length(body) = 0) or (Length(body) > 20000) or (Pos(#0, body) > 0) then begin ReplyError(id, 'the file is empty or too big'); Exit; end;
    if (kind = 'launcher') or (kind = 'desktop_icon') then begin
      if not NameOk(fname, '^cockpit-power-[a-z0-9_-]{1,48}\.desktop$') then begin ReplyError(id, 'bad launcher name'); Exit; end;
      if kind = 'launcher' then dir := GetEnvironmentVariable('HOME') + '/.local/share/applications'
      else begin dir := Trim(RunCapture('xdg-user-dir DESKTOP')); if dir = '' then dir := GetEnvironmentVariable('HOME') + '/Desktop'; end;
    end else if kind = 'nautilus' then begin
      if not NameOk(fname, '^Cockpit - [A-Za-z0-9 ._()-]{1,60}$') then begin ReplyError(id, 'bad script name'); Exit; end; dir := GetEnvironmentVariable('HOME') + '/.local/share/nautilus/scripts';
    end else if kind = 'dolphin' then begin
      if fname <> 'cockpit-power.desktop' then begin ReplyError(id, 'bad menu name'); Exit; end; dir := GetEnvironmentVariable('HOME') + '/.local/share/kio/servicemenus';
    end else if kind = 'cli' then begin
      if fname <> 'cockpit-run' then begin ReplyError(id, 'bad tool name'); Exit; end; dir := GetEnvironmentVariable('HOME') + '/.local/bin';
    end else begin ReplyError(id, 'unknown kind'); Exit; end;
    try
      ForceDirectories(dir); sl := TStringList.Create;
      try sl.Text := body; sl.SaveToFile(dir + '/' + fname); finally sl.Free; end;
      fpChmod(dir + '/' + fname, mode);
      if kind = 'desktop_icon' then fpSystem('gio set ' + ShellQuote(dir + '/' + fname) + ' metadata::trusted true >/dev/null 2>&1');
    except on E: Exception do begin ReplyError(id, 'could not write: ' + E.Message); Exit; end; end;
    Log('installed ' + kind + ': ' + dir + '/' + fname);
    rep := TJSONObject.Create(['id', id, 'ok', True, 'path', dir + '/' + fname]);
    try PageReply(rep); finally rep.Free; end; Exit;
  end;
  if cmd = 'open_tmux' then begin
    sess := req.Get('session', 'cockpit_tools'); path := req.Get('socket', '');
    term := FirstOnPath(['gnome-terminal', 'konsole', 'xfce4-terminal', 'mate-terminal', 'tilix', 'kitty', 'alacritty', 'xterm']);
    if term = '' then begin ReplyError(id, 'no terminal emulator found'); Exit; end;
    { the new window is started by a background process, so the window manager opens it behind the maximised Cockpit window
      (it looks minimised): the terminal raises itself first, as its own first command }
    dir := 'sleep 0.4; (command -v wmctrl >/dev/null 2>&1 && wmctrl -a ' + ShellQuote(sess) + '; command -v xdotool >/dev/null 2>&1 && xdotool search --name ' + ShellQuote(sess) + ' windowactivate) >/dev/null 2>&1; tmux ' + IfThen(path <> '', '-S ' + ShellQuote(path), '') + ' attach -t ' + ShellQuote(sess);
    if Pos('gnome-terminal', term) > 0 then fpSystem(term + ' --title=' + ShellQuote(sess) + ' -- bash -c ' + ShellQuote(dir + '; exec bash') + ' >/dev/null 2>&1 &')
    else fpSystem(term + ' -e bash -c ' + ShellQuote(dir + '; exec bash') + ' >/dev/null 2>&1 &');
    rep := TJSONObject.Create(['id', id, 'ok', True]);
    try PageReply(rep); finally rep.Free; end; Exit;
  end;
  ReplyError(id, 'unknown command ' + cmd);
end;

{ ── extra windows ─────────────────────────────────────────────────────────
  open_window {url,title,w,h} gives the page a second real window on the same
  app: a panel put on the other monitor, the preview beside the chat. Only the
  app's own origin is allowed (the URL is rebuilt from the main one's scheme and
  host, so the page cannot use this to open anything else). The extra window is
  independent: closing it closes nothing else, Ctrl+W and Escape close it, and
  the exit procedure lives in the main window alone. }
type
  T_gtk_widget_destroy = procedure(w: PGtkWidget); cdecl;
var
  gtk_widget_destroy: T_gtk_widget_destroy;
  ExtraWindows: Integer = 0;

procedure OnExtraLoad(v: PGtkWidget; event: cint; data: Pointer); cdecl;
begin
  Log('extra load event ' + IntToStr(event));
end;


function OnExtraKey(w: PGtkWidget; ev: PGdkEventKey; data: Pointer): gboolean; cdecl;
begin
  Result := 0;
  if (ev^.keyval = GDK_KEY_F11) then Exit(0);
  if (ev^.keyval = $FF1B) or                                   { Escape }
     (((ev^.state and GDK_CONTROL_MASK) <> 0) and ((ev^.keyval = Ord('w')) or (ev^.keyval = Ord('W')))) then begin
    if Pointer(gtk_widget_destroy) <> nil then gtk_widget_destroy(w);
    Exit(1);
  end;
end;

function OnExtraDelete(w: PGtkWidget; ev: Pointer; data: Pointer): gboolean; cdecl;
begin
  Dec(ExtraWindows);
  Result := 0;     { let it close — only the main window asks the page }
end;

{ Same scheme+host as the app, whatever the page asked for. }
function SameOriginUrl(const want: string): string;
var base, tail, rest: string; p: Integer;
begin
  base := OptUrl;
  p := Pos('://', base);
  if p = 0 then Exit('');
  rest := Copy(base, p + 3, MaxInt);
  p := Pos('/', rest);
  if p > 0 then base := Copy(OptUrl, 1, Length(OptUrl) - Length(rest) + p - 1) else base := OptUrl;
  { a relative path is joined to the app's origin; an absolute URL must match it }
  if Pos('://', want) = 0 then begin
    tail := want;
    if (tail <> '') and (tail[1] <> '/') then tail := '/' + tail;
    Exit(base + tail);
  end;
  if Pos(base, want) = 1 then Exit(want);
  Result := '';
end;

procedure OpenExtraWindow(const req: TJSONObject);
var id, url, title: string; w, h: cint; win, view: PGtkWidget; rep: TJSONObject; settings: PGObject;
begin
  id := req.Get('id', ''); url := SameOriginUrl(req.Get('url', ''));
  title := req.Get('title', OptTitle); w := req.Get('w', 900); h := req.Get('h', 700);
  if url = '' then begin ReplyError(id, 'only the app''s own pages can be opened'); Exit; end;
  if ExtraWindows >= 6 then begin ReplyError(id, 'too many windows open'); Exit; end;
  if (w < 320) or (w > 10000) then w := 900;
  if (h < 240) or (h > 10000) then h := 700;
  win := gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(win, PChar(title));
  gtk_window_set_default_size(win, w, h);
  if (OptIcon <> '') and FileExists(OptIcon) then gtk_window_set_icon_from_file(win, PChar(OptIcon), nil);
  { same message channel as the main window, so a detached panel can call the
    shell too (open a terminal, a file, the keyring) }
  view := webkit_web_view_new_with_user_content_manager(UCM);
  settings := webkit_web_view_get_settings(view);
  if OptWorker = '' then webkit_settings_set_user_agent_with_application_details(settings, 'AICockpitShell', SHELL_VERSION);   { a worker looks like the plain browser it is }
  webkit_settings_set_enable_developer_extras(settings, 1);   { detached windows always allow Inspect — they are the hard ones to debug }
  { WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER = 2: a second accelerated view in
    the same process painted nothing on X11 without a compositor (the DOM was
    right, the window stayed black). These panels are text — software is fine. }
  if Pointer(webkit_settings_set_hardware_acceleration_policy) <> nil then
    webkit_settings_set_hardware_acceleration_policy(settings, 2);
  gtk_container_add(win, view);
  g_signal_connect_data(win, 'key-press-event', @OnExtraKey, nil, nil, 0);
  g_signal_connect_data(win, 'delete-event', @OnExtraDelete, nil, nil, 0);
  g_signal_connect_data(view, 'load-changed', @OnExtraLoad, nil, nil, 0);
  g_signal_connect_data(view, 'load-failed', @OnLoadFailed, nil, nil, 0);
  gtk_widget_show_all(win);        { realize before loading — an unrealized view can stay blank }
  webkit_web_view_load_uri(view, PChar(url));
  Inc(ExtraWindows);
  Log('extra window: ' + url);
  rep := TJSONObject.Create(['id', id, 'ok', True]);
  try PageReply(rep); finally rep.Free; end;
end;

procedure TrayInit;
var h, hg: TLibHandle; menu, it: PGtkWidget;
begin
  hg := LoadLibrary(GTK);
  Pointer(gtk_window_present) := GetProcAddress(hg, 'gtk_window_present');
  Pointer(gtk_widget_destroy) := GetProcAddress(hg, 'gtk_widget_destroy');
  Pointer(gtk_window_present_with_time) := GetProcAddress(hg, 'gtk_window_present_with_time');
  Pointer(gtk_widget_hide) := GetProcAddress(hg, 'gtk_widget_hide');
  Pointer(gtk_window_iconify) := GetProcAddress(hg, 'gtk_window_iconify');
  Pointer(gtk_window_deiconify) := GetProcAddress(hg, 'gtk_window_deiconify');
  Pointer(gtk_window_is_active) := GetProcAddress(hg, 'gtk_window_is_active');
  h := LoadLibrary('libayatana-appindicator3.so.1');
  if h = NilHandle then h := LoadLibrary('libappindicator3.so.1');
  if h = NilHandle then begin Log('tray: no appindicator library — skipped'); Exit; end;
  Pointer(app_indicator_new) := GetProcAddress(h, 'app_indicator_new');
  Pointer(app_indicator_set_status) := GetProcAddress(h, 'app_indicator_set_status');
  Pointer(app_indicator_set_menu) := GetProcAddress(h, 'app_indicator_set_menu');
  Pointer(app_indicator_set_icon_full) := GetProcAddress(h, 'app_indicator_set_icon_full');
  Pointer(app_indicator_set_title) := GetProcAddress(h, 'app_indicator_set_title');
  Pointer(gtk_menu_new) := GetProcAddress(hg, 'gtk_menu_new');
  Pointer(gtk_menu_item_new_with_label) := GetProcAddress(hg, 'gtk_menu_item_new_with_label');
  Pointer(gtk_separator_menu_item_new) := GetProcAddress(hg, 'gtk_separator_menu_item_new');
  Pointer(gtk_menu_shell_append) := GetProcAddress(hg, 'gtk_menu_shell_append');
  if (Pointer(app_indicator_new) = nil) or (Pointer(app_indicator_set_menu) = nil) or (Pointer(gtk_menu_new) = nil) then Exit;
  { APP_INDICATOR_CATEGORY_APPLICATION_STATUS = 0; APP_INDICATOR_STATUS_ACTIVE = 1 }
  TrayInd := app_indicator_new('ai-cockpit', 'ai-cockpit', 0);
  if (OptIcon <> '') and (Pointer(app_indicator_set_icon_full) <> nil) then app_indicator_set_icon_full(TrayInd, PChar(OptIcon), 'AI Cockpit');
  if Pointer(app_indicator_set_title) <> nil then app_indicator_set_title(TrayInd, PChar(OptTitle + ' — click for Show / Minimise / Exit'));   { the panel shows this on hover where it supports it }
  menu := gtk_menu_new();
  it := gtk_menu_item_new_with_label('Show Cockpit'); g_signal_connect_data(it, 'activate', @OnTrayShow, nil, nil, 0); gtk_menu_shell_append(menu, it);
  it := gtk_menu_item_new_with_label('Minimise'); g_signal_connect_data(it, 'activate', @OnTrayHide, nil, nil, 0); gtk_menu_shell_append(menu, it);
  if Pointer(gtk_separator_menu_item_new) <> nil then gtk_menu_shell_append(menu, gtk_separator_menu_item_new());
  it := gtk_menu_item_new_with_label('Exit Cockpit…'); g_signal_connect_data(it, 'activate', @OnTrayExit, nil, nil, 0); gtk_menu_shell_append(menu, it);
  gtk_widget_show_all(menu);
  app_indicator_set_menu(TrayInd, menu);
  app_indicator_set_status(TrayInd, 1);
  Log('tray: indicator up');
end;

procedure OnScriptMessage(m: PGObject; res: PGObject; data: Pointer); cdecl;
var v: PGObject; p: PChar; s: string; j: TJSONData; req: TJSONObject;
begin
  v := webkit_javascript_result_get_js_value(res);
  p := jsc_value_to_string(v); s := StrPas(p); g_free(p);
  try j := GetJSON(s); except Exit; end;
  try
    if not (j is TJSONObject) then Exit;
    req := TJSONObject(j);
    if req.Get('cmd', '') = 'quit' then begin Log('page asked to quit (message)'); QuitApp; Exit; end;
    if req.Get('cmd', '') = 'boot_retry' then begin BootTries := 0; BootStarted := False; BootPage('Starting Cockpit…', False); g_timeout_add(1000, @OnBootPoll, nil); Exit; end
    else if req.Get('cmd', '') = 'open_window' then OpenExtraWindow(req)
    else if req.Get('cmd', '') = 'pick_files' then PickFiles(req)
    else if (req.Get('cmd', '') = 'sysinfo') or (req.Get('cmd', '') = 'clipboard_files') or (req.Get('cmd', '') = 'set_dark')
         or (Pos('open_', req.Get('cmd', '')) = 1) or (req.Get('cmd', '') = 'reveal_path') then OsHandle(req)
    else if (req.Get('cmd', '') = 'set_frameless') or (Pos('win_', req.Get('cmd', '')) = 1) then FramelessHandle(req)
    else if req.Get('cmd', '') = 'notify' then NotifyHandle(req)
    else if req.Get('cmd', '') = 'present' then begin PresentWindow; ReplyError(req.Get('id', ''), ''); end
    else if Pos('kr_', req.Get('cmd', '')) = 1 then KrHandle(req) else BwHandle(req);
  finally j.Free; end;
end;

{ ── web worker mode ────────────────────────────────────────────────────────
  cockpit_shell --worker DIR --url URL [--title T] : a page nobody sits in front of. Cockpit drives it through files in DIR:
    DIR/cmd.<n>.json   written by Cockpit (rename into place), read and deleted here every 150 ms:
                       {"cmd":"eval","js":"…"} | {"cmd":"show"} | {"cmd":"hide"} | {"cmd":"load","url":"…"} | {"cmd":"reload"} | {"cmd":"status","id":"…"} | {"cmd":"quit"}
    DIR/events.ndjson  one JSON object per line, appended here: what the page posts with window.webkit.messageHandlers.cockpit.postMessage(JSON.stringify({…})),
                       plus {"t":"ready"} at start, {"t":"loaded","url":…} after each load, {"t":"status",…}.
    DIR/alive          rewritten every poll: its age says whether this process is running.
    DIR/profile/       the cookie jar (a login survives restarts); the window starts off-screen, not in the task bar, and "show" brings it where a person can log in.
  The window is kept MAPPED (just off-screen) because a page that is hidden or minimised throttles itself and may not render the answer. }
var OffWin: PGtkWidget = nil;     { where the page lives while nobody looks at it: a GtkOffscreenWindow draws nothing on any screen }
    gtk_offscreen_window_new: function: PGtkWidget; cdecl = nil;
    gtk_widget_reparent: procedure(w, np: PGtkWidget); cdecl = nil;
    gtk_window_set_skip_taskbar_hint: procedure(w: PGtkWidget; b: gboolean); cdecl = nil;

procedure WorkerEvent(const line: string);
var f: TextFile; p: string;
begin
  p := OptWorker + '/events.ndjson';
  try
    AssignFile(f, p);
    if FileExists(p) then Append(f) else Rewrite(f);
    writeln(f, line);
    CloseFile(f);
    FpChmod(p, &666);   { the server that reads this may be another user; do not depend on the umask we were started with }
  except end;
end;

procedure WorkerHide;
begin
  if (OffWin = nil) or not WorkerShown then Exit;
  gtk_widget_reparent(View, OffWin);   { the page goes back behind the screen, still running and still laid out }
  if Pointer(gtk_widget_hide) <> nil then gtk_widget_hide(Win);
  WorkerShown := False;
end;

procedure WorkerShow;
begin
  if (OffWin = nil) or WorkerShown then Exit;
  if ViewHost <> nil then gtk_widget_reparent(View, ViewHost) else gtk_widget_reparent(View, Win);
  gtk_widget_show_all(Win);
  if Pointer(gtk_window_present) <> nil then gtk_window_present(Win);
  WorkerShown := True;
end;

procedure WorkerInit;
var h: TLibHandle;
begin
  h := LoadLibrary(GTK);
  Pointer(gtk_offscreen_window_new) := GetProcAddress(h, 'gtk_offscreen_window_new');
  Pointer(gtk_widget_reparent) := GetProcAddress(h, 'gtk_widget_reparent');
  if Pointer(gtk_widget_hide) = nil then Pointer(gtk_widget_hide) := GetProcAddress(h, 'gtk_widget_hide');
  if Pointer(gtk_window_present) = nil then Pointer(gtk_window_present) := GetProcAddress(h, 'gtk_window_present');
  if (Pointer(gtk_offscreen_window_new) = nil) or (Pointer(gtk_widget_reparent) = nil) then begin Log('worker: no offscreen window in this GTK'); Halt(3); end;
  OffWin := gtk_offscreen_window_new();
  gtk_window_set_default_size(OffWin, 1100, 800);
  gtk_widget_reparent(View, OffWin);
  gtk_widget_show_all(OffWin);
end;

procedure WorkerLoaded(v: PGtkWidget);
var o: TJSONObject; u: PChar;
begin
  o := TJSONObject.Create; u := webkit_web_view_get_uri(v);
  o.Add('t', 'loaded'); if u <> nil then o.Add('url', StrPas(u)) else o.Add('url', '');
  WorkerEvent(o.AsJSON); o.Free;
end;

procedure OnWorkerMessage(m: PGObject; res: PGObject; data: Pointer); cdecl;
var v: PGObject; p: PChar; s: string;
begin
  v := webkit_javascript_result_get_js_value(res);
  p := jsc_value_to_string(v); s := Trim(StrPas(p)); g_free(p);
  { the page posts JSON.stringify(...): already one line, UTF-8, newlines inside text escaped. Passed on as it is: parsing and writing it again here mangles non-ASCII text. }
  if (s <> '') and (s[1] = '{') and (Pos(#10, s) = 0) and (Pos(#13, s) = 0) then WorkerEvent(s);
end;

function OnWorkerPoll(data: Pointer): gboolean; cdecl;
var sr: TSearchRec; names: TStringList; i: Integer; sl: TStringList; j: TJSONData; req: TJSONObject; cmd, fn: string; o: TJSONObject; t: PChar; u: PChar; fh: THandle;
begin
  fh := FileCreate(OptWorker + '/alive'); if fh <> THandle(-1) then begin FileClose(fh); FpChmod(OptWorker + '/alive', &666); end;
  names := TStringList.Create;
  try
    if FindFirst(OptWorker + '/cmd.*.json', faAnyFile, sr) = 0 then begin
      repeat names.Add(sr.Name); until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    names.Sort;
    for i := 0 to names.Count - 1 do begin
      fn := OptWorker + '/' + names[i];
      sl := TStringList.Create;
      try
        try sl.LoadFromFile(fn); except sl.Text := ''; end;
      finally end;
      DeleteFile(fn);
      try j := GetJSON(sl.Text); except j := nil; end;
      sl.Free;
      if (j = nil) or not (j is TJSONObject) then begin j.Free; Continue; end;
      req := TJSONObject(j);
      try
        cmd := req.Get('cmd', '');
        if cmd = 'eval' then webkit_web_view_run_javascript(View, PChar(req.Get('js', '')), nil, nil, nil)
        else if cmd = 'show' then WorkerShow
        else if cmd = 'hide' then WorkerHide
        else if cmd = 'load' then webkit_web_view_load_uri(View, PChar(req.Get('url', 'about:blank')))
        else if cmd = 'reload' then webkit_web_view_reload(View)
        else if cmd = 'quit' then begin DeleteFile(OptWorker + '/alive'); QuitApp; end
        else if cmd = 'status' then begin
          o := TJSONObject.Create; u := webkit_web_view_get_uri(View); t := webkit_web_view_get_title(View);
          o.Add('t', 'status'); o.Add('id', req.Get('id', ''));
          if u <> nil then o.Add('url', StrPas(u)) else o.Add('url', '');
          if t <> nil then o.Add('title', StrPas(t)) else o.Add('title', '');
          o.Add('shown', WorkerShown);
          WorkerEvent(o.AsJSON); o.Free;
        end;
      finally j.Free; end;
    end;
  finally names.Free; end;
  Result := 1;
end;
function OnMaximizeAgain(data: Pointer): gboolean; cdecl;
begin
  gtk_window_maximize(Win);
  Result := 0;
end;

{ ── args ──────────────────────────────────────────────────────────────────── }
procedure ParseArgs;
var i: Integer; a: string;
  function Next: string; begin Inc(i); if i <= ParamCount then Result := ParamStr(i) else Result := ''; end;
begin
  OptTitle := 'AI Cockpit';
  i := 1;
  while i <= ParamCount do begin
    a := ParamStr(i);
    if a = '--url' then OptUrl := Next
    else if a = '--worker' then OptWorker := Next
    else if a = '--title' then OptTitle := Next
    else if a = '--icon' then OptIcon := Next
    else if a = '--splash' then OptSplash := Next
    else if a = '--ready' then OptReady := Next
    else if a = '--width' then OptW := StrToIntDef(Next, OptW)
    else if a = '--height' then OptH := StrToIntDef(Next, OptH)
    else if a = '--devtools' then OptDevTools := True
    else if a = '--check' then OptCheck := True
    else if a = '--eval' then OptEval := Next
    else if a = '--kiosk' then OptKiosk := True
    else if a = '--browser' then OptBrowser := True
    else if a = '--frameless' then OptFrameless := True
    else if a = '--hotkey' then OptHotkey := Next
    else if a = '--start' then OptStart := Next
    else if a = '--start-timeout' then OptStartTimeout := StrToIntDef(Next, OptStartTimeout)
    else if a = '--verify' then OptVerify := Next
    else if a = '--no-verify' then OptVerify := ''
    else if (a = '--version') or (a = '-V') then begin writeln('cockpit_shell ', SHELL_VERSION); Halt(0); end
    else if (a = '--help') or (a = '-h') then begin
      writeln('cockpit_shell --url URL [--title T] [--icon PNG] [--splash FILE --ready FILE] [--width W --height H] [--devtools] [--check] [--kiosk] [--frameless] [--verify DIR] [--hotkey ctrl+alt+c] [--start CMD]');
      Halt(0);
    end;
    Inc(i);
  end;
  if (OptUrl = '') and not OptCheck then begin writeln(stderr, 'cockpit_shell: --url is required'); Halt(2); end;
end;

var
  argc: cint; argv: PPChar; settings: PGObject; dataDir: string;
  GeoW, GeoH: cint; GeoMax: Boolean; vChanged, vMissing: Integer; vMsg: string;
begin
  { C libraries expect FPU exceptions masked; FPC unmasks them by default and
    WebKit's layout maths then raises EZeroDivide inside the library. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  ParseArgs;
  if OptWorker <> '' then begin OptBrowser := True; OptVerify := ''; ForceDirectories(OptWorker); end;
  LoadBindings;
  LoadFileBindings;
  if OptCheck then begin writeln('cockpit_shell ', SHELL_VERSION, ': runtime libraries OK'); Halt(0); end;
  g_set_prgname('ai-cockpit');      { WM_CLASS → matches ai-cockpit.desktop (dock icon, grouping) }
  argc := 0; argv := nil;
  gtk_init(@argc, @argv);
  ApplyDark(DesktopPrefersDark);   { the page's first paint sees the desktop's prefers-color-scheme }

  Win := gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(Win, PChar(OptTitle));
  GeometryLoad(GeoW, GeoH, GeoMax);
  if OptWorker <> '' then begin GeoW := 1100; GeoH := 800; GeoMax := False; GeoX := -1; GeoY := -1; end;
  gtk_window_set_default_size(Win, GeoW, GeoH);
  { back where it was — same monitor — before the first map }
  if (GeoX >= 0) and (GeoY >= 0) and (Pointer(gtk_window_move) <> nil) then gtk_window_move(Win, GeoX, GeoY);
  if (OptIcon <> '') and FileExists(OptIcon) then gtk_window_set_icon_from_file(Win, PChar(OptIcon), nil);

  { Cookies (the app's login session) survive restarts: SQLite jar under
    $XDG_DATA_HOME/ai-cockpit — the same place WebKit keeps localStorage for
    this program name. WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE = 1. }
  dataDir := GetEnvironmentVariable('XDG_DATA_HOME');
  if dataDir = '' then dataDir := GetEnvironmentVariable('HOME') + '/.local/share';
  dataDir := dataDir + '/ai-cockpit';
  if OptWorker <> '' then dataDir := OptWorker + '/profile';   { one cookie jar per worker }
  ForceDirectories(dataDir);
  webkit_cookie_manager_set_persistent_storage(
    webkit_web_context_get_cookie_manager(webkit_web_context_get_default()),
    PChar(dataDir + '/cookies.sqlite'), 1);

  UCM := webkit_user_content_manager_new();
  webkit_user_content_manager_register_script_message_handler(UCM, 'cockpit');
  if OptWorker <> '' then g_signal_connect_data(UCM, 'script-message-received::cockpit', @OnWorkerMessage, nil, nil, 0)
  else g_signal_connect_data(UCM, 'script-message-received::cockpit', @OnScriptMessage, nil, nil, 0);
  View := webkit_web_view_new_with_user_content_manager(UCM);
  settings := webkit_web_view_get_settings(View);
  if OptWorker = '' then webkit_settings_set_user_agent_with_application_details(settings, 'AICockpitShell', SHELL_VERSION);   { a worker looks like the plain browser it is }
  webkit_settings_set_enable_developer_extras(settings, Ord(OptDevTools));
  webkit_settings_set_javascript_can_open_windows_automatically(settings, 1);
  webkit_settings_set_enable_media_stream(settings, 1);
  gtk_container_add(Win, View);

  g_signal_connect_data(Win,  'delete-event',       @OnDelete,       nil, nil, 0);
  g_signal_connect_data(Win,  'key-press-event',    @OnKey,          nil, nil, 0);
  g_signal_connect_data(Win,  'window-state-event', @OnWindowState,  nil, nil, 0);
  g_signal_connect_data(View, 'notify::title',      @OnTitle,        nil, nil, 0);
  g_signal_connect_data(View, 'load-changed',       @OnLoadChanged,  nil, nil, 0);
  g_signal_connect_data(View, 'load-failed',        @OnLoadFailed,   nil, nil, 0);
  g_signal_connect_data(View, 'decide-policy',      @OnDecidePolicy, nil, nil, 0);
  g_signal_connect_data(View, 'create',             @OnCreate,       nil, nil, 0);
  g_signal_connect_data(View, 'permission-request', @OnPermission,   nil, nil, 0);
  g_signal_connect_data(View, 'drag-data-received', @OnDragDataReceived, nil, nil, 0);

  if (OptVerify <> '') and not OptBrowser then begin
    vMsg := VerifyTree(OptVerify, vChanged, vMissing);
    if vMsg <> '' then begin
      Log('verify FAILED: ' + vMsg);
      OptEval := '';   { nothing from the command line runs on the refusal page }
      AppShown := True; PageLoaded := False;
      gtk_widget_show_all(Win);
      ShowVerifyFailure(vMsg);
      gtk_main; Exit;
    end;
    Log('verify ok (' + IntToStr(vMissing) + ' file(s) not present, e.g. scripts on another host)');
  end;

  if (OptSplash <> '') and FileExists(OptSplash) then begin
    webkit_web_view_load_uri(View, PChar('file://' + OptSplash));
    g_timeout_add(300, @OnReadyPoll, nil);
  end else if (OptStart <> '') and not UrlAnswers(OptUrl) then begin
    { nothing is up: the window says so and starts everything itself }
    BootPage('Starting Cockpit…', False);
    g_timeout_add(1000, @OnBootPoll, nil);
  end else begin
    AppShown := True;
    webkit_web_view_load_uri(View, PChar(OptUrl));
  end;

  if OptKiosk then begin
    if Pointer(gtk_window_set_decorated) <> nil then gtk_window_set_decorated(Win, 0);
    gtk_window_fullscreen(Win); IsFullscreen := True;
  end else if GeoMax then gtk_window_maximize(Win);
  if not OptFrameless then OptFrameless := FramelessSaved;
  if OptBrowser and (OptWorker = '') then begin RegFile := RegDir + '/' + IntToStr(GetProcessID) + '.json'; g_timeout_add(300, @OnRegPoll, nil); end;
  if OptFrameless and (Pointer(gtk_window_set_decorated) <> nil) then begin gtk_window_set_decorated(Win, 0); FramelessApplied := True; if OptBrowser then GripsInstall(True); end;
  if (not OptBrowser) and (not OptKiosk) and (OptWorker = '') then GripsInstall(False);   { the main window: the overlay that carries the Min / Max / Close buttons (shown only while frameless) }   { frameless: the page draws the controls }
  if OptWorker = '' then gtk_widget_show_all(Win);
  if OptWorker <> '' then begin
    WorkerInit;
    WorkerEvent('{"t":"ready"}');
    g_timeout_add(150, @OnWorkerPoll, nil);
  end;
  gtk_widget_grab_focus(View);
  { Some WMs place a window asked to maximize before it is mapped slightly off
    (seen once: 1927px wide at x=-7 on a 1920 screen) — ask again once mapped. }
  if GeoMax and not OptKiosk then g_timeout_add(400, @OnMaximizeAgain, nil);
  if not OptBrowser then TrayInit;
  if not OptBrowser then begin HotkeyInit(OptHotkey); PowerKeysLoad; end;
  ReloadSignalInit;
  gtk_main;
  if OptWorker = '' then GeometrySave;
  Log('bye');
end.
