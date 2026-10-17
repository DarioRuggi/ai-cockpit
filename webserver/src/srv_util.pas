(* =============================================================================
  srv_util — pure helpers for the web server: URL path handling, glob matching, MIME types, HTTP dates,
  ETags and Range parsing.  No sockets, no files: everything here is unit-tested with fixed inputs.

  The URL path normaliser is the security-critical part.  It turns the raw request target into a clean,
  absolute, decoded path — or REFUSES it:
    * the path is percent-decoded exactly ONCE;  "%2e%2e" is ".." and is resolved/refused like "..";
      a literal "%252e" stays the harmless text "%2e" (no second decoding, so no double-encoding tricks);
    * a decoded "/" or "\" that came from %2F / %5C is refused (an encoded slash would let a path say two
      different things to two different layers);
    * NUL and other control characters are refused (a NUL ends a C string early: "x.php%00.txt");
    * a backslash anywhere is refused;
    * "." and empty segments are dropped, ".." removes the previous segment, and a ".." that would climb
      above the root is refused — never silently clamped.
  ============================================================================= *)
unit srv_util;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils;

type
  TRangeKind = (rkNone, rkOk, rkUnsatisfiable, rkIgnore);

function HexVal(c: Char): Integer;
{ Raw request target ("/a/b%20c?x=1") -> clean decoded path and the untouched query.  False = refuse (Err says why). }
function NormalizeTarget(const Target: string; out CleanPath, Query, Err: string): Boolean;
{ Percent-decode a query component or header value; '+' stays '+' unless PlusIsSpace. Invalid escapes are kept. }
function SoftDecode(const S: string; PlusIsSpace: Boolean = False): string;
function GlobMatch(const Pattern, S: string; CaseInsensitive: Boolean = False): Boolean;
function MimeFor(const FileName: string): string;
function HttpDate(T: TDateTime): string;                 // T is UTC
function ParseHttpDate(const S: string; out T: TDateTime): Boolean;
function ETagFor(Size: Int64; MTime: Int64): string;      // weak validator W/"size-mtime"
function ParseRange(const Hdr: string; Size: Int64; out First, Last: Int64): TRangeKind;
function HtmlEscape(const S: string): string;
function StatusText(Code: Integer): string;
{ The real path of an existing file or directory (symbolic links resolved), or '' }
function RealPathOf(const P: string): string;

implementation

function c_realpath(path, resolved: PChar): PChar; cdecl; external 'c' name 'realpath';

function RealPathOf(const P: string): string;
var
  buf: array[0..4095] of Char;
begin
  FillChar(buf, SizeOf(buf), 0);
  if c_realpath(PChar(P), @buf[0]) = nil then Result := '' else Result := StrPas(@buf[0]);
end;

function HexVal(c: Char): Integer;
begin
  case c of
    '0'..'9': Result := Ord(c) - 48;
    'a'..'f': Result := Ord(c) - 87;
    'A'..'F': Result := Ord(c) - 55;
  else
    Result := -1;
  end;
end;

function NormalizeTarget(const Target: string; out CleanPath, Query, Err: string): Boolean;
var
  p, i, h, l: Integer;
  raw, dec: string;
  c: Char;
  segs: TStringList;
  seg: string;
  trailing: Boolean;
begin
  Result := False;
  CleanPath := ''; Query := ''; Err := '';
  raw := Target;
  // an absolute-form target ("http://host/path") is accepted for proxies' sake only as its path
  if (Copy(raw, 1, 7) = 'http://') or (Copy(raw, 1, 8) = 'https://') then
  begin
    p := Pos('//', raw);
    raw := Copy(raw, p + 2, MaxInt);
    p := Pos('/', raw);
    if p = 0 then raw := '/' else raw := Copy(raw, p, MaxInt);
  end;
  if (raw = '') or (raw[1] <> '/') then begin Err := 'target must start with /'; Exit; end;
  p := Pos('#', raw);
  if p > 0 then raw := Copy(raw, 1, p - 1);                       // fragments are never sent; ignore if present
  p := Pos('?', raw);
  if p > 0 then begin Query := Copy(raw, p + 1, MaxInt); raw := Copy(raw, 1, p - 1); end;

  // ---- decode ONCE ----
  dec := '';
  i := 1;
  while i <= Length(raw) do
  begin
    c := raw[i];
    if c = '%' then
    begin
      if i + 2 > Length(raw) then begin Err := 'truncated percent escape'; Exit; end;
      h := HexVal(raw[i + 1]); l := HexVal(raw[i + 2]);
      if (h < 0) or (l < 0) then begin Err := 'bad percent escape'; Exit; end;
      c := Chr(h * 16 + l);
      if (c = '/') or (c = '\') then begin Err := 'encoded slash'; Exit; end;
      Inc(i, 3);
    end
    else Inc(i);
    if (Ord(c) < 32) or (Ord(c) = 127) then begin Err := 'control character in path'; Exit; end;
    if c = '\' then begin Err := 'backslash in path'; Exit; end;
    dec := dec + c;
  end;

  // ---- resolve . and .. lexically ----
  trailing := (dec <> '') and (dec[Length(dec)] = '/');
  segs := TStringList.Create;
  try
    seg := '';
    for i := 1 to Length(dec) + 1 do
    begin
      if (i > Length(dec)) or (dec[i] = '/') then
      begin
        if (seg = '') or (seg = '.') then
        begin
          // dropped
        end
        else if seg = '..' then
        begin
          if segs.Count = 0 then begin Err := 'path climbs above the root'; Exit; end;
          segs.Delete(segs.Count - 1);
        end
        else segs.Add(seg);
        seg := '';
      end
      else seg := seg + dec[i];
    end;
    // a final "." or ".." segment also means "a directory"
    if (Length(dec) > 0) then
    begin
      i := Length(dec);
      if (Copy(dec, Length(dec) - 1, 2) = '/.') or (Copy(dec, Length(dec) - 2, 3) = '/..') then trailing := True;
    end;
    CleanPath := '';
    for i := 0 to segs.Count - 1 do CleanPath := CleanPath + '/' + segs[i];
    if CleanPath = '' then CleanPath := '/'
    else if trailing then CleanPath := CleanPath + '/';
  finally
    segs.Free;
  end;
  Result := True;
end;

function SoftDecode(const S: string; PlusIsSpace: Boolean): string;
var
  i, h, l: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    if (S[i] = '%') and (i + 2 <= Length(S)) then
    begin
      h := HexVal(S[i + 1]); l := HexVal(S[i + 2]);
      if (h >= 0) and (l >= 0) then begin Result := Result + Chr(h * 16 + l); Inc(i, 3); Continue; end;
    end;
    if PlusIsSpace and (S[i] = '+') then Result := Result + ' ' else Result := Result + S[i];
    Inc(i);
  end;
end;

function GlobRec(const P, S: string; pi, si: Integer; ci: Boolean): Boolean;
var
  a, b: Char;
begin
  while pi <= Length(P) do
  begin
    case P[pi] of
      '*':
        begin
          while (pi <= Length(P)) and (P[pi] = '*') do Inc(pi);
          if pi > Length(P) then Exit(True);
          while si <= Length(S) + 1 do
          begin
            if GlobRec(P, S, pi, si, ci) then Exit(True);
            Inc(si);
          end;
          Exit(False);
        end;
      '?':
        begin
          if si > Length(S) then Exit(False);
          Inc(pi); Inc(si);
        end;
    else
      begin
        if si > Length(S) then Exit(False);
        a := P[pi]; b := S[si];
        if ci then begin if a in ['A'..'Z'] then a := Chr(Ord(a) + 32); if b in ['A'..'Z'] then b := Chr(Ord(b) + 32); end;
        if a <> b then Exit(False);
        Inc(pi); Inc(si);
      end;
    end;
  end;
  Result := si > Length(S);
end;

function GlobMatch(const Pattern, S: string; CaseInsensitive: Boolean): Boolean;
begin
  Result := GlobRec(Pattern, S, 1, 1, CaseInsensitive);
end;

function MimeFor(const FileName: string): string;
var
  e: string;
begin
  e := LowerCase(ExtractFileExt(FileName));
  if e = '.html' then Result := 'text/html; charset=utf-8'
  else if e = '.htm' then Result := 'text/html; charset=utf-8'
  else if e = '.css' then Result := 'text/css; charset=utf-8'
  else if e = '.js' then Result := 'text/javascript; charset=utf-8'
  else if e = '.mjs' then Result := 'text/javascript; charset=utf-8'
  else if e = '.json' then Result := 'application/json; charset=utf-8'
  else if e = '.txt' then Result := 'text/plain; charset=utf-8'
  else if e = '.md' then Result := 'text/markdown; charset=utf-8'
  else if e = '.xml' then Result := 'application/xml; charset=utf-8'
  else if e = '.svg' then Result := 'image/svg+xml'
  else if e = '.png' then Result := 'image/png'
  else if (e = '.jpg') or (e = '.jpeg') then Result := 'image/jpeg'
  else if e = '.gif' then Result := 'image/gif'
  else if e = '.webp' then Result := 'image/webp'
  else if e = '.ico' then Result := 'image/vnd.microsoft.icon'
  else if e = '.woff2' then Result := 'font/woff2'
  else if e = '.woff' then Result := 'font/woff'
  else if e = '.ttf' then Result := 'font/ttf'
  else if e = '.pdf' then Result := 'application/pdf'
  else if e = '.zip' then Result := 'application/zip'
  else if e = '.gz' then Result := 'application/gzip'
  else if e = '.wasm' then Result := 'application/wasm'
  else if e = '.mp3' then Result := 'audio/mpeg'
  else if e = '.wav' then Result := 'audio/wav'
  else if e = '.ogg' then Result := 'audio/ogg'
  else if e = '.m4a' then Result := 'audio/mp4'
  else if e = '.flac' then Result := 'audio/flac'
  else if e = '.mp4' then Result := 'video/mp4'
  else if e = '.webm' then Result := 'video/webm'
  else if e = '.mkv' then Result := 'video/x-matroska'
  else if e = '.srt' then Result := 'text/plain; charset=utf-8'
  else if e = '.vtt' then Result := 'text/vtt; charset=utf-8'
  else Result := 'application/octet-stream';
end;

const
  Days: array[1..7] of string = ('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun');
  Months: array[1..12] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');

function HttpDate(T: TDateTime): string;
var
  y, m, d: Word;
begin
  DecodeDate(T, y, m, d);
  Result := Format('%s, %.2d %s %d %.2d:%.2d:%.2d GMT', [Days[DayOfTheWeek(T)], d, Months[m], y, HourOf(T), MinuteOf(T), SecondOf(T)]);
end;

function ParseHttpDate(const S: string; out T: TDateTime): Boolean;
var
  p: TStringList;
  i, m, d, y, hh, mm, ss: Integer;
  tm: string;
begin
  Result := False;
  T := 0;
  p := TStringList.Create;
  try
    p.Delimiter := ' '; p.StrictDelimiter := False;
    p.DelimitedText := StringReplace(S, ',', ' ', [rfReplaceAll]);
    if p.Count < 6 then Exit;                    // Sun, 06 Nov 1994 08:49:37 GMT   (the only format we emit and accept)
    d := StrToIntDef(p[1], 0);
    m := 0;
    for i := 1 to 12 do if SameText(p[2], Months[i]) then m := i;
    y := StrToIntDef(p[3], 0);
    tm := p[4];
    hh := StrToIntDef(Copy(tm, 1, 2), -1); mm := StrToIntDef(Copy(tm, 4, 2), -1); ss := StrToIntDef(Copy(tm, 7, 2), -1);
    if (d < 1) or (m = 0) or (y < 1970) or (hh < 0) or (mm < 0) or (ss < 0) then Exit;
    if not TryEncodeDate(y, m, d, T) then Exit;
    T := T + EncodeTime(hh, mm, ss, 0);
    Result := True;
  finally
    p.Free;
  end;
end;

function ETagFor(Size: Int64; MTime: Int64): string;
begin
  Result := 'W/"' + LowerCase(IntToHex(Size, 1)) + '-' + LowerCase(IntToHex(MTime, 1)) + '"';
end;

{ "bytes=0-99" | "bytes=100-" | "bytes=-50".  More than one range -> rkIgnore (we answer with the whole file,
  which a client must accept).  Not a bytes range -> rkIgnore.  Start beyond the end -> rkUnsatisfiable (416). }
function ParseRange(const Hdr: string; Size: Int64; out First, Last: Int64): TRangeKind;
var
  s, a, b: string;
  p: Integer;
  n1, n2: Int64;
begin
  First := 0; Last := Size - 1;
  s := LowerCase(Trim(Hdr));
  if s = '' then Exit(rkNone);
  if Copy(s, 1, 6) <> 'bytes=' then Exit(rkIgnore);
  s := Trim(Copy(s, 7, MaxInt));
  if Pos(',', s) > 0 then Exit(rkIgnore);
  p := Pos('-', s);
  if p = 0 then Exit(rkIgnore);
  a := Trim(Copy(s, 1, p - 1)); b := Trim(Copy(s, p + 1, MaxInt));
  if (a = '') and (b = '') then Exit(rkIgnore);
  if a = '' then
  begin
    n2 := StrToInt64Def(b, -1);                                 // suffix: the last n bytes
    if n2 < 0 then Exit(rkIgnore);
    if n2 = 0 then Exit(rkUnsatisfiable);
    if n2 > Size then n2 := Size;
    First := Size - n2; Last := Size - 1;
    if Size = 0 then Exit(rkUnsatisfiable);
    Exit(rkOk);
  end;
  n1 := StrToInt64Def(a, -1);
  if n1 < 0 then Exit(rkIgnore);
  if b = '' then n2 := Size - 1 else n2 := StrToInt64Def(b, -1);
  if n2 < 0 then Exit(rkIgnore);
  if (b <> '') and (n2 < n1) then Exit(rkIgnore);           // "9-5" is syntactically invalid: ignore the header
  if n1 >= Size then Exit(rkUnsatisfiable);
  if n2 >= Size then n2 := Size - 1;
  First := n1; Last := n2;
  Result := rkOk;
end;

function HtmlEscape(const S: string): string;
begin
  Result := StringReplace(StringReplace(StringReplace(StringReplace(S, '&', '&amp;', [rfReplaceAll]), '<', '&lt;', [rfReplaceAll]), '>', '&gt;', [rfReplaceAll]), '"', '&quot;', [rfReplaceAll]);
end;

function StatusText(Code: Integer): string;
begin
  case Code of
    200: Result := 'OK'; 201: Result := 'Created'; 204: Result := 'No Content'; 206: Result := 'Partial Content';
    301: Result := 'Moved Permanently'; 302: Result := 'Found'; 303: Result := 'See Other'; 304: Result := 'Not Modified';
    307: Result := 'Temporary Redirect'; 308: Result := 'Permanent Redirect';
    400: Result := 'Bad Request'; 401: Result := 'Unauthorized'; 403: Result := 'Forbidden'; 404: Result := 'Not Found';
    405: Result := 'Method Not Allowed'; 408: Result := 'Request Timeout'; 411: Result := 'Length Required';
    413: Result := 'Content Too Large'; 414: Result := 'URI Too Long'; 416: Result := 'Range Not Satisfiable';
    417: Result := 'Expectation Failed'; 421: Result := 'Misdirected Request'; 431: Result := 'Request Header Fields Too Large';
    500: Result := 'Internal Server Error'; 501: Result := 'Not Implemented'; 502: Result := 'Bad Gateway';
    503: Result := 'Service Unavailable'; 504: Result := 'Gateway Timeout'; 505: Result := 'HTTP Version Not Supported';
  else
    Result := 'Status';
  end;
end;

end.
