(* =============================================================================
  aic_fs — the file manager's operations, with the permission model of Cockpit's file window:

    ZONES     a request names the zones it may touch:  [{"name":"public","path":"/…/Public","rw":true},{"name":"home","path":"/home/u","rw":false}]
              Paths in a request are  "<zone>:<relative path>".
    PUBLIC    the one read-write zone (created if missing, owned by whoever runs this program). Everything works there:
              list, stat, new folder, new file, rename, move, copy, upload (write), download (read), delete.
    AREAS     every other zone is read-only: list, stat, read, and COPY INTO a read-write zone. Nothing else. An area must be owned by
              the user running this program ("user-owned areas"); anything else is refused, not shown.
    TRASH     delete in Public moves to Public/.trash; delete inside .trash is permanent.

  CONFINEMENT  a zone's folder is opened once, then every path component is opened relative to the previous one with O_NOFOLLOW, and each
  action is an *at() call on that folder's descriptor. A symbolic link is never followed, so a link inside a zone cannot lead out of it, and
  swapping a folder for a link between the check and the action is not possible (there is no separate check). ".." and empty names are refused.

  Every action that changes something (and `open`) is appended to the audit log (JSON lines).
  Pure functions over a request object, so tests drive them directly:  aicengine fs --request-file F  prints the response.
  ============================================================================= *)
unit aic_fs;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, BaseUnix, fpjson;

{ One request, one response. Request: {"op":..., ...,"zones":[...],"user":"name","audit":"/path/audit.jsonl"} }
function FsHandle(Req: TJSONObject): TJSONObject;

{ for the command sandbox (aic_exec): the zones of a request, the real path of a link-free folder, the audit line }
procedure FsLoadZones(Req: TJSONObject);
function FsRoots(RW: Boolean): TStringList;
function FsResolveDir(const P: string; out RWZone: Boolean): string;
procedure FsAudit(Req: TJSONObject; const Op: string; Resp: TJSONObject);

const
  FS_MAX_LIST = 5000;
  FS_MAX_READ = 4 * 1024 * 1024;           // per read call
  FS_MAX_FILE = 512 * 1024 * 1024;         // largest file an upload may reach
  FS_MAX_COPY_FILES = 20000;
  FS_MAX_COPY_BYTES = Int64(2) * 1024 * 1024 * 1024;

implementation

uses
  base64, DateUtils, aic_proc;

{$IFDEF CPUAARCH64}
const O_DIRECTORY_ = $4000; O_NOFOLLOW_ = $8000;
{$ELSE}
const O_DIRECTORY_ = $10000; O_NOFOLLOW_ = $20000;
{$ENDIF}
const
  O_CLOEXEC_ = $80000;
  AT_SYMLINK_NOFOLLOW_ = $100;
  AT_REMOVEDIR_ = $200;
  RENAME_NOREPLACE_ = 1;

function c_openat(dirfd: cint; path: PChar; flags: cint; mode: cuint): cint; cdecl; external 'c' name 'openat';
function c_mkdirat(dirfd: cint; path: PChar; mode: cuint): cint; cdecl; external 'c' name 'mkdirat';
function c_unlinkat(dirfd: cint; path: PChar; flags: cint): cint; cdecl; external 'c' name 'unlinkat';
function c_renameat2(od: cint; op: PChar; nd: cint; np: PChar; flags: cuint): cint; cdecl; external 'c' name 'renameat2';
function c_fstatat(dirfd: cint; path: PChar; var st: Stat; flags: cint): cint; cdecl; external 'c' name 'fstatat';
function c_readlinkat(dirfd: cint; path: PChar; buf: PChar; sz: PtrUInt): PtrInt; cdecl; external 'c' name 'readlinkat';
function c_fdopendir(fd: cint): Pointer; cdecl; external 'c' name 'fdopendir';
function c_readdir(d: Pointer): PDirent; cdecl; external 'c' name 'readdir';
function c_closedir(d: Pointer): cint; cdecl; external 'c' name 'closedir';
function c_pread(fd: cint; buf: Pointer; n: PtrUInt; off: Int64): PtrInt; cdecl; external 'c' name 'pread';
function c_pwrite(fd: cint; buf: Pointer; n: PtrUInt; off: Int64): PtrInt; cdecl; external 'c' name 'pwrite';
function c_realpath(path, resolved: PChar): PChar; cdecl; external 'c' name 'realpath';
function c_ftruncate(fd: cint; len: Int64): cint; cdecl; external 'c' name 'ftruncate';
{$IFDEF DARWIN}
function c_errno_loc: PCInt; cdecl; external 'c' name '__error';
{$ELSE}
function c_errno_loc: PCInt; cdecl; external 'c' name '__errno_location';
{$ENDIF}

type
  EFs = class(Exception);
  TZone = record
    Name, Root: string;
    RW: Boolean;
  end;
  TZones = array of TZone;

var
  GZones: TZones;

procedure Fail(const Msg: string);
begin
  raise EFs.Create(Msg);
end;

function OctStr(V: Integer; Digits: Integer): string;
begin
  Result := '';
  while V > 0 do begin Result := Chr(48 + (V and 7)) + Result; V := V shr 3; end;
  while Length(Result) < Digits do Result := '0' + Result;
end;

function ErrText(const What: string): string;
begin
  case c_errno_loc^ of          // the C library's errno: the calls above are libc's, and FPC's own errno does not see their errors
    ESysENOENT: Result := 'not found';
    ESysEEXIST: Result := 'already exists';
    ESysENOTDIR: Result := 'not a folder';
    ESysELOOP: Result := 'a symbolic link is in the way (links are not followed)';
    ESysEACCES, ESysEPERM: Result := 'permission denied';
    ESysENOTEMPTY: Result := 'folder is not empty';
    ESysEINVAL: Result := 'not possible (for example a folder into itself)';
    ESysEXDEV: Result := 'cannot move across file systems';
    ESysENOSPC: Result := 'no space left';
    ESysEISDIR: Result := 'is a folder';
  else Result := 'error ' + IntToStr(c_errno_loc^);
  end;
  Result := What + ': ' + Result;
end;

function RealPathOf(const P: string): string;
var
  buf: array[0..4095] of Char;
begin
  FillChar(buf, SizeOf(buf), 0);
  if c_realpath(PChar(P), @buf[0]) = nil then Result := '' else Result := StrPas(@buf[0]);
end;

function ZoneByName(const N: string): TZone;
var
  i: Integer;
begin
  for i := 0 to High(GZones) do if GZones[i].Name = N then Exit(GZones[i]);
  Fail('unknown zone: ' + N);
end;

{ "zone:rel/path" -> zone, list of components (no empty, '.' or '..') }
procedure SplitPath(const P: string; out Z: TZone; Comps: TStringList);
var
  c: Integer;
  rel, part: string;
  i: Integer;
begin
  c := Pos(':', P);
  if c < 2 then Fail('a path looks like zone:folder/file');
  Z := ZoneByName(Copy(P, 1, c - 1));
  rel := Copy(P, c + 1, MaxInt);
  if Pos(#0, rel) > 0 then Fail('bad path');
  Comps.Clear;
  part := '';
  for i := 1 to Length(rel) + 1 do
  begin
    if (i > Length(rel)) or (rel[i] = '/') then
    begin
      if part = '..' then Fail('".." is not allowed in a path');
      if (part <> '') and (part <> '.') then Comps.Add(part);
      part := '';
    end
    else part := part + rel[i];
  end;
end;

procedure CheckName(const N: string);
begin
  if (N = '') or (N = '.') or (N = '..') or (Pos('/', N) > 0) or (Pos(#0, N) > 0) or (Length(N) > 255) then Fail('not a valid name: ' + N);
end;

function OpenRoot(const Z: TZone): cint;
begin
  Result := c_openat(-100, PChar(Z.Root), O_RDONLY or O_DIRECTORY_ or O_CLOEXEC_, 0);
  if Result < 0 then Fail(ErrText('cannot open ' + Z.Name));
end;

{ opens the folder holding the last component (all earlier ones without following links); Leaf = the last component ('' for the zone root) }
function OpenParent(const Z: TZone; Comps: TStringList; out Leaf: string): cint;
var
  fd, nfd, i: Integer;
begin
  fd := OpenRoot(Z);
  if Comps.Count = 0 then begin Leaf := ''; Exit(fd); end;
  for i := 0 to Comps.Count - 2 do
  begin
    nfd := c_openat(fd, PChar(Comps[i]), O_RDONLY or O_DIRECTORY_ or O_NOFOLLOW_ or O_CLOEXEC_, 0);
    fpClose(fd);
    if nfd < 0 then Fail(ErrText(Comps[i]));
    fd := nfd;
  end;
  Leaf := Comps[Comps.Count - 1];
  Result := fd;
end;

{ opens a FOLDER by its zone path (root included) }
function OpenDirPath(const P: string; out Z: TZone): cint;
var
  comps: TStringList;
  leaf: string;
  pfd, fd: cint;
begin
  comps := TStringList.Create;
  try
    SplitPath(P, Z, comps);
    pfd := OpenParent(Z, comps, leaf);
    if leaf = '' then Exit(pfd);
    fd := c_openat(pfd, PChar(leaf), O_RDONLY or O_DIRECTORY_ or O_NOFOLLOW_ or O_CLOEXEC_, 0);
    fpClose(pfd);
    if fd < 0 then Fail(ErrText(leaf));
    Result := fd;
  finally
    comps.Free;
  end;
end;

procedure NeedRW(const Z: TZone);
begin
  if not Z.RW then Fail('"' + Z.Name + '" is read-only: you can look at it and copy from it, nothing else');
end;

function TypeOf(const st: Stat): string;
begin
  if fpS_ISDIR(st.st_mode) then Result := 'dir'
  else if fpS_ISREG(st.st_mode) then Result := 'file'
  else if fpS_ISLNK(st.st_mode) then Result := 'link'
  else Result := 'other';
end;

function StatJson(const Name: string; const st: Stat; pfd: cint): TJSONObject;
var
  buf: array[0..4095] of Char;
  n: PtrInt;
begin
  Result := TJSONObject.Create;
  Result.Add('name', Name); Result.Add('type', TypeOf(st)); Result.Add('size', Int64(st.st_size));
  Result.Add('mtime', Int64(st.st_mtime)); Result.Add('mode', OctStr(st.st_mode and $FFF, 3));
  if fpS_ISLNK(st.st_mode) and (pfd >= 0) then
  begin
    n := c_readlinkat(pfd, PChar(Name), @buf[0], SizeOf(buf) - 1);
    if n > 0 then begin buf[n] := #0; Result.Add('link', StrPas(@buf[0])); end;
  end;
end;

function LStatAt(pfd: cint; const Name: string; out st: Stat): Boolean;
begin
  Result := c_fstatat(pfd, PChar(Name), st, AT_SYMLINK_NOFOLLOW_) = 0;
end;

{ ---- operations --------------------------------------------------------------------------------------------------------------------- }

function OpList(R: TJSONObject): TJSONObject;
var
  Z: TZone;
  fd: cint;
  d: Pointer;
  e: PDirent;
  names: TStringList;
  arr: TJSONArray;
  st: Stat;
  i: Integer;
  nm: string;
  items: TList;
  o: TJSONObject;
  truncated: Boolean;
begin
  fd := OpenDirPath(R.Get('path', ''), Z);
  d := c_fdopendir(fd);
  if d = nil then begin fpClose(fd); Fail(ErrText('cannot list')); end;
  names := TStringList.Create;
  arr := TJSONArray.Create;
  truncated := False;
  try
    try
      repeat
        e := c_readdir(d);
        if e = nil then Break;
        nm := StrPas(PChar(@e^.d_name[0]));
        if (nm = '.') or (nm = '..') then Continue;
        if names.Count >= FS_MAX_LIST then begin truncated := True; Break; end;
        names.Add(nm);
      until False;
      // c_closedir closes fd; stat entries through a fresh descriptor of the same folder
    finally
      c_closedir(d);
    end;
    fd := OpenDirPath(R.Get('path', ''), Z);
    names.CaseSensitive := False;
    items := TList.Create;
    try
      for i := 0 to names.Count - 1 do
      begin
        if not LStatAt(fd, names[i], st) then Continue;
        o := StatJson(names[i], st, fd);
        arr.Add(o);
      end;
    finally
      items.Free;
      fpClose(fd);
    end;
  finally
    names.Free;
  end;
  Result := TJSONObject.Create(['ok', True, 'entries', arr, 'truncated', truncated, 'rw', Z.RW]);
end;

function OpStat(R: TJSONObject): TJSONObject;
var
  Z: TZone;
  comps: TStringList;
  leaf: string;
  pfd: cint;
  st: Stat;
begin
  comps := TStringList.Create;
  try
    SplitPath(R.Get('path', ''), Z, comps);
    pfd := OpenParent(Z, comps, leaf);
    try
      if leaf = '' then
      begin
        if fpFStat(pfd, st) <> 0 then Fail(ErrText('stat'));
        Result := TJSONObject.Create(['ok', True, 'stat', StatJson(Z.Name, st, -1), 'rw', Z.RW]);
      end
      else
      begin
        if not LStatAt(pfd, leaf, st) then Fail(ErrText(leaf));
        Result := TJSONObject.Create(['ok', True, 'stat', StatJson(leaf, st, pfd), 'rw', Z.RW]);
      end;
    finally
      fpClose(pfd);
    end;
  finally
    comps.Free;
  end;
end;

function OpMkdir(R: TJSONObject): TJSONObject;
var
  Z: TZone;
  comps: TStringList;
  leaf: string;
  pfd: cint;
begin
  comps := TStringList.Create;
  try
    SplitPath(R.Get('path', ''), Z, comps); NeedRW(Z);
    if comps.Count = 0 then Fail('give the new folder a name');
    pfd := OpenParent(Z, comps, leaf);
    try
      CheckName(leaf);
      if c_mkdirat(pfd, PChar(leaf), &755) <> 0 then Fail(ErrText(leaf));
    finally
      fpClose(pfd);
    end;
  finally
    comps.Free;
  end;
  Result := TJSONObject.Create(['ok', True]);
end;

function OpNewFile(R: TJSONObject): TJSONObject;
var
  Z: TZone;
  comps: TStringList;
  leaf: string;
  pfd, fd: cint;
begin
  comps := TStringList.Create;
  try
    SplitPath(R.Get('path', ''), Z, comps); NeedRW(Z);
    if comps.Count = 0 then Fail('give the new file a name');
    pfd := OpenParent(Z, comps, leaf);
    try
      CheckName(leaf);
      fd := c_openat(pfd, PChar(leaf), O_WRONLY or O_CREAT or O_EXCL or O_NOFOLLOW_ or O_CLOEXEC_, &644);
      if fd < 0 then Fail(ErrText(leaf));
      fpClose(fd);
    finally
      fpClose(pfd);
    end;
  finally
    comps.Free;
  end;
  Result := TJSONObject.Create(['ok', True]);
end;

function OpRename(R: TJSONObject): TJSONObject;
var
  Z: TZone;
  comps: TStringList;
  leaf, newName: string;
  pfd: cint;
begin
  comps := TStringList.Create;
  try
    SplitPath(R.Get('path', ''), Z, comps); NeedRW(Z);
    if comps.Count = 0 then Fail('the top folder cannot be renamed');
    newName := R.Get('name', '');
    CheckName(newName);
    pfd := OpenParent(Z, comps, leaf);
    try
      if c_renameat2(pfd, PChar(leaf), pfd, PChar(newName), RENAME_NOREPLACE_) <> 0 then Fail(ErrText('rename'));
    finally
      fpClose(pfd);
    end;
  finally
    comps.Free;
  end;
  Result := TJSONObject.Create(['ok', True]);
end;

function OpMove(R: TJSONObject): TJSONObject;
var
  Z, Z2: TZone;
  comps, comps2: TStringList;
  leaf, leaf2: string;
  pfd, dfd: cint;
begin
  comps := TStringList.Create; comps2 := TStringList.Create;
  try
    SplitPath(R.Get('path', ''), Z, comps); NeedRW(Z);
    SplitPath(R.Get('to_dir', ''), Z2, comps2); NeedRW(Z2);
    if Z.Name <> Z2.Name then Fail('move works inside one zone; use copy to bring something in');
    if comps.Count = 0 then Fail('the top folder cannot be moved');
    pfd := OpenParent(Z, comps, leaf);
    try
      dfd := OpenDirPath(R.Get('to_dir', ''), Z2);
      try
        if c_renameat2(pfd, PChar(leaf), dfd, PChar(leaf), RENAME_NOREPLACE_) <> 0 then Fail(ErrText('move'));
      finally
        fpClose(dfd);
      end;
    finally
      fpClose(pfd);
    end;
    leaf2 := '';
  finally
    comps.Free; comps2.Free;
  end;
  Result := TJSONObject.Create(['ok', True]);
end;

procedure RemoveTree(pfd: cint; const Name: string; var Count: Integer);
var
  st: Stat;
  fd: cint;
  d: Pointer;
  e: PDirent;
  kids: TStringList;
  i: Integer;
  nm: string;
begin
  if not LStatAt(pfd, Name, st) then Fail(ErrText(Name));
  Inc(Count);
  if Count > 200000 then Fail('too many items to delete in one go');
  if fpS_ISDIR(st.st_mode) then
  begin
    fd := c_openat(pfd, PChar(Name), O_RDONLY or O_DIRECTORY_ or O_NOFOLLOW_ or O_CLOEXEC_, 0);
    if fd < 0 then Fail(ErrText(Name));
    kids := TStringList.Create;
    try
      d := c_fdopendir(fd);
      if d = nil then begin fpClose(fd); Fail(ErrText(Name)); end;
      repeat
        e := c_readdir(d);
        if e = nil then Break;
        nm := StrPas(PChar(@e^.d_name[0]));
        if (nm <> '.') and (nm <> '..') then kids.Add(nm);
      until False;
      c_closedir(d);
      fd := c_openat(pfd, PChar(Name), O_RDONLY or O_DIRECTORY_ or O_NOFOLLOW_ or O_CLOEXEC_, 0);
      if fd < 0 then Fail(ErrText(Name));
      try
        for i := 0 to kids.Count - 1 do RemoveTree(fd, kids[i], Count);
      finally
        fpClose(fd);
      end;
    finally
      kids.Free;
    end;
    if c_unlinkat(pfd, PChar(Name), AT_REMOVEDIR_) <> 0 then Fail(ErrText(Name));
  end
  else if c_unlinkat(pfd, PChar(Name), 0) <> 0 then Fail(ErrText(Name));
end;

function OpDelete(R: TJSONObject): TJSONObject;
var
  Z: TZone;
  comps: TStringList;
  leaf, tname: string;
  pfd, rfd, tfd: cint;
  cnt: Integer;
  inTrash: Boolean;
  st: Stat;
begin
  comps := TStringList.Create;
  try
    SplitPath(R.Get('path', ''), Z, comps); NeedRW(Z);
    if comps.Count = 0 then Fail('the top folder cannot be deleted');
    inTrash := (comps[0] = '.trash') and (comps.Count > 1);
    if (comps[0] = '.trash') and (comps.Count = 1) then Fail('use "empty the trash" for the trash itself');
    pfd := OpenParent(Z, comps, leaf);
    try
      if inTrash then
      begin
        cnt := 0;
        RemoveTree(pfd, leaf, cnt);
        Result := TJSONObject.Create(['ok', True, 'permanent', True]);
      end
      else
      begin
        rfd := OpenRoot(Z);
        try
          if not LStatAt(rfd, '.trash', st) then
            if c_mkdirat(rfd, '.trash', &700) <> 0 then Fail(ErrText('trash'));
          tname := IntToStr(DateTimeToUnix(Now)) + '-' + leaf;
          tname := Copy(tname, 1, 255);
          // rename into the trash folder through its descriptor (same file system: the zone is one folder tree)
          tfd := c_openat(rfd, '.trash', O_RDONLY or O_DIRECTORY_ or O_NOFOLLOW_ or O_CLOEXEC_, 0);
          if tfd < 0 then Fail(ErrText('trash'));
          try
            if c_renameat2(pfd, PChar(leaf), tfd, PChar(tname), RENAME_NOREPLACE_) <> 0 then Fail(ErrText('delete'));
          finally
            fpClose(tfd);
          end;
        finally
          fpClose(rfd);
        end;
        Result := TJSONObject.Create(['ok', True, 'permanent', False, 'trashed_as', tname]);
      end;
    finally
      fpClose(pfd);
    end;
  finally
    comps.Free;
  end;
end;

function OpEmptyTrash(R: TJSONObject): TJSONObject;
var
  Z: TZone;
  rfd, tfd: cint;
  d: Pointer;
  e: PDirent;
  kids: TStringList;
  i, cnt: Integer;
  nm: string;
  st: Stat;
begin
  Z := ZoneByName(R.Get('zone', 'public')); NeedRW(Z);
  rfd := OpenRoot(Z);
  kids := TStringList.Create;
  try
    if not LStatAt(rfd, '.trash', st) then Exit(TJSONObject.Create(['ok', True, 'removed', 0]));
    tfd := c_openat(rfd, '.trash', O_RDONLY or O_DIRECTORY_ or O_NOFOLLOW_ or O_CLOEXEC_, 0);
    if tfd < 0 then Fail(ErrText('trash'));
    d := c_fdopendir(tfd);
    if d = nil then begin fpClose(tfd); Fail(ErrText('trash')); end;
    repeat
      e := c_readdir(d);
      if e = nil then Break;
      nm := StrPas(PChar(@e^.d_name[0]));
      if (nm <> '.') and (nm <> '..') then kids.Add(nm);
    until False;
    c_closedir(d);
    tfd := c_openat(rfd, '.trash', O_RDONLY or O_DIRECTORY_ or O_NOFOLLOW_ or O_CLOEXEC_, 0);
    cnt := 0;
    try
      for i := 0 to kids.Count - 1 do RemoveTree(tfd, kids[i], cnt);
    finally
      fpClose(tfd);
    end;
  finally
    kids.Free;
    fpClose(rfd);
  end;
  Result := TJSONObject.Create(['ok', True, 'removed', cnt]);
end;

function OpRead(R: TJSONObject): TJSONObject;
var
  Z: TZone;
  comps: TStringList;
  leaf: string;
  pfd, fd: cint;
  off: Int64;
  want, n: Integer;
  buf: string;
  st: Stat;
begin
  comps := TStringList.Create;
  try
    SplitPath(R.Get('path', ''), Z, comps);
    if comps.Count = 0 then Fail('that is a folder');
    pfd := OpenParent(Z, comps, leaf);
    try
      fd := c_openat(pfd, PChar(leaf), O_RDONLY or O_NOFOLLOW_ or O_CLOEXEC_, 0);
      if fd < 0 then Fail(ErrText(leaf));
      try
        if fpFStat(fd, st) <> 0 then Fail(ErrText(leaf));
        if not fpS_ISREG(st.st_mode) then Fail('not a regular file');
        off := R.Get('offset', Int64(0));
        want := R.Get('length', 65536);
        if want > FS_MAX_READ then want := FS_MAX_READ;
        if want < 0 then want := 0;
        SetLength(buf, want);
        n := 0;
        if want > 0 then n := c_pread(fd, @buf[1], want, off);
        if n < 0 then Fail(ErrText(leaf));
        SetLength(buf, n);
      finally
        fpClose(fd);
      end;
    finally
      fpClose(pfd);
    end;
  finally
    comps.Free;
  end;
  Result := TJSONObject.Create(['ok', True, 'data_b64', EncodeStringBase64(buf), 'size', Int64(st.st_size), 'offset', off, 'eof', (off + n) >= st.st_size]);
end;

function OpWrite(R: TJSONObject): TJSONObject;
var
  Z: TZone;
  comps: TStringList;
  leaf, data: string;
  pfd, fd: cint;
  off: Int64;
  n: PtrInt;
  flags: cint;
begin
  comps := TStringList.Create;
  try
    SplitPath(R.Get('path', ''), Z, comps); NeedRW(Z);
    if comps.Count = 0 then Fail('give the file a name');
    data := DecodeStringBase64(R.Get('data_b64', ''));
    off := R.Get('offset', Int64(0));
    if off + Length(data) > FS_MAX_FILE then Fail('the file would be larger than the limit');
    pfd := OpenParent(Z, comps, leaf);
    try
      CheckName(leaf);
      flags := O_WRONLY or O_CREAT or O_NOFOLLOW_ or O_CLOEXEC_;
      if R.Get('create_only', False) then flags := flags or O_EXCL;
      fd := c_openat(pfd, PChar(leaf), flags, &644);
      if fd < 0 then Fail(ErrText(leaf));
      try
        if (off = 0) and R.Get('truncate', True) then c_ftruncate(fd, 0);
        if Length(data) > 0 then
        begin
          n := c_pwrite(fd, @data[1], Length(data), off);
          if n <> Length(data) then Fail(ErrText('write'));
        end;
      finally
        fpClose(fd);
      end;
    finally
      fpClose(pfd);
    end;
  finally
    comps.Free;
  end;
  Result := TJSONObject.Create(['ok', True, 'written', Length(data)]);
end;

var
  CopyFiles: Integer;
  CopyBytes: Int64;

procedure CopyEntry(sfd: cint; const Name: string; dfd: cint; const DName: string);
var
  st: Stat;
  s, d, nsub, ndsub: cint;
  buf: array[0..65535] of Byte;
  n: PtrInt;
  dir: Pointer;
  e: PDirent;
  kids: TStringList;
  i: Integer;
  nm: string;
begin
  if not LStatAt(sfd, Name, st) then Fail(ErrText(Name));
  Inc(CopyFiles);
  if CopyFiles > FS_MAX_COPY_FILES then Fail('too many items to copy in one go');
  if fpS_ISLNK(st.st_mode) or not (fpS_ISREG(st.st_mode) or fpS_ISDIR(st.st_mode)) then Exit;       // links and devices are not copied
  if fpS_ISDIR(st.st_mode) then
  begin
    if c_mkdirat(dfd, PChar(DName), &755) <> 0 then Fail(ErrText(DName));
    s := c_openat(sfd, PChar(Name), O_RDONLY or O_DIRECTORY_ or O_NOFOLLOW_ or O_CLOEXEC_, 0);
    if s < 0 then Fail(ErrText(Name));
    kids := TStringList.Create;
    try
      dir := c_fdopendir(s);
      if dir = nil then begin fpClose(s); Fail(ErrText(Name)); end;
      repeat
        e := c_readdir(dir);
        if e = nil then Break;
        nm := StrPas(PChar(@e^.d_name[0]));
        if (nm <> '.') and (nm <> '..') then kids.Add(nm);
      until False;
      c_closedir(dir);
      nsub := c_openat(sfd, PChar(Name), O_RDONLY or O_DIRECTORY_ or O_NOFOLLOW_ or O_CLOEXEC_, 0);
      ndsub := c_openat(dfd, PChar(DName), O_RDONLY or O_DIRECTORY_ or O_NOFOLLOW_ or O_CLOEXEC_, 0);
      if (nsub < 0) or (ndsub < 0) then begin if nsub >= 0 then fpClose(nsub); if ndsub >= 0 then fpClose(ndsub); Fail(ErrText(Name)); end;
      try
        for i := 0 to kids.Count - 1 do CopyEntry(nsub, kids[i], ndsub, kids[i]);
      finally
        fpClose(nsub); fpClose(ndsub);
      end;
    finally
      kids.Free;
    end;
    Exit;
  end;
  s := c_openat(sfd, PChar(Name), O_RDONLY or O_NOFOLLOW_ or O_CLOEXEC_, 0);
  if s < 0 then Fail(ErrText(Name));
  try
    d := c_openat(dfd, PChar(DName), O_WRONLY or O_CREAT or O_EXCL or O_NOFOLLOW_ or O_CLOEXEC_, &644);
    if d < 0 then Fail(ErrText(DName));
    try
      repeat
        n := fpRead(s, buf, SizeOf(buf));
        if n < 0 then Fail(ErrText(Name));
        if n = 0 then Break;
        Inc(CopyBytes, n);
        if CopyBytes > FS_MAX_COPY_BYTES then Fail('too much data to copy in one go');
        if fpWrite(d, buf, n) <> n then Fail(ErrText('write'));
      until False;
    finally
      fpClose(d);
    end;
  finally
    fpClose(s);
  end;
end;

function FreeName(dfd: cint; const Name: string): string;
var
  st: Stat;
  i: Integer;
  base, ext: string;
begin
  Result := Name;
  if not LStatAt(dfd, Result, st) then Exit;
  ext := ExtractFileExt(Name); base := Copy(Name, 1, Length(Name) - Length(ext));
  for i := 2 to 999 do
  begin
    Result := base + ' (' + IntToStr(i) + ')' + ext;
    if not LStatAt(dfd, Result, st) then Exit;
  end;
  Fail('too many copies with that name');
end;

function OpCopy(R: TJSONObject): TJSONObject;
var
  Z, Z2: TZone;
  comps, comps2: TStringList;
  leaf, dname: string;
  pfd, dfd: cint;
begin
  comps := TStringList.Create; comps2 := TStringList.Create;
  try
    SplitPath(R.Get('path', ''), Z, comps);
    SplitPath(R.Get('to_dir', ''), Z2, comps2); NeedRW(Z2);
    if comps.Count = 0 then Fail('copy a file or a folder, not a whole zone');
    pfd := OpenParent(Z, comps, leaf);
    try
      dfd := OpenDirPath(R.Get('to_dir', ''), Z2);
      try
        dname := FreeName(dfd, leaf);
        CopyFiles := 0; CopyBytes := 0;
        CopyEntry(pfd, leaf, dfd, dname);
      finally
        fpClose(dfd);
      end;
    finally
      fpClose(pfd);
    end;
  finally
    comps.Free; comps2.Free;
  end;
  Result := TJSONObject.Create(['ok', True, 'name', dname, 'files', CopyFiles, 'bytes', CopyBytes]);
end;

{ the real path of a zone item for handing to the system's default application; every component is checked for links first }
{ Start a desktop program for good: a double fork (no zombie, no pipe shared with this service), a new session, stdio on /dev/null.
  The old way (RunProcess) waited for the program's output pipes to close and killed it after 6 s - a GUI program was gone before it was seen. }
procedure LaunchDetached(const Exe, Arg, Display: string);
var
  pid, pid2: TPid;
  st: cint;
  fd: cint;
  envs: TStringList;
  argv, envp: array of PChar;
  i: Integer;
  xa, home: string;
begin
  envs := TStringList.Create;
  try
    home := GetEnvironmentVariable('HOME');
    envs.Add('PATH=' + GetEnvironmentVariable('PATH')); envs.Add('HOME=' + home);
    if Display <> '' then envs.Add('DISPLAY=' + Display);
    xa := GetEnvironmentVariable('XAUTHORITY');
    if (xa = '') and FileExists(home + '/.Xauthority') then xa := home + '/.Xauthority';
    if xa <> '' then envs.Add('XAUTHORITY=' + xa);
    if GetEnvironmentVariable('XDG_RUNTIME_DIR') <> '' then envs.Add('XDG_RUNTIME_DIR=' + GetEnvironmentVariable('XDG_RUNTIME_DIR'));
    if GetEnvironmentVariable('DBUS_SESSION_BUS_ADDRESS') <> '' then envs.Add('DBUS_SESSION_BUS_ADDRESS=' + GetEnvironmentVariable('DBUS_SESSION_BUS_ADDRESS'));
    envs.Add('LANG=C.UTF-8');
    SetLength(argv, 3); argv[0] := PChar(Exe); argv[1] := PChar(Arg); argv[2] := nil;
    SetLength(envp, envs.Count + 1);
    for i := 0 to envs.Count - 1 do envp[i] := PChar(envs[i]);
    envp[envs.Count] := nil;
    pid := fpFork;
    if pid < 0 then Exit;
    if pid = 0 then
    begin
      fpSetsid;
      pid2 := fpFork;
      if pid2 <> 0 then fpExit(0);
      fd := fpOpen('/dev/null', O_RDWR);
      if fd >= 0 then begin fpDup2(fd, 0); fpDup2(fd, 1); fpDup2(fd, 2); if fd > 2 then fpClose(fd); end;
      fpExecve(Exe, PPChar(@argv[0]), PPChar(@envp[0]));
      fpExit(127);
    end;
    st := 0;
    fpWaitPid(pid, @st, 0);
  finally
    envs.Free;
  end;
end;

function OpOpen(R: TJSONObject): TJSONObject;
var
  Z: TZone;
  comps: TStringList;
  leaf, real: string;
  pfd: cint;
  st: Stat;
  args: TStringList;
  rr: TProcResult;
  env: TStringList;
  opener: string;
begin
  comps := TStringList.Create;
  try
    SplitPath(R.Get('path', ''), Z, comps);
    if comps.Count = 0 then real := Z.Root
    else
    begin
      pfd := OpenParent(Z, comps, leaf);
      try
        if not LStatAt(pfd, leaf, st) then Fail(ErrText(leaf));
        if fpS_ISLNK(st.st_mode) then Fail('a symbolic link is not opened');
      finally
        fpClose(pfd);
      end;
      real := Z.Root + '/' + StringReplace(comps.Text, #10, '/', [rfReplaceAll]);
      while (real <> '') and (real[Length(real)] = '/') do SetLength(real, Length(real) - 1);
    end;
  finally
    comps.Free;
  end;
  opener := FindInPath('xdg-open', GetEnvironmentVariable('PATH'));
  if opener = '' then opener := FindInPath('open', GetEnvironmentVariable('PATH'));
  if opener = '' then Fail('no desktop opener (xdg-open) on this machine');
  LaunchDetached(opener, real, R.Get('display', ''));
  Result := TJSONObject.Create(['ok', True]);
end;

{ ---- zones, dispatch, audit ---------------------------------------------------------------------------------------------------------- }

procedure LoadZones(R: TJSONObject);
var
  a: TJSONArray;
  i, n: Integer;
  o: TJSONObject;
  p: string;
  st: Stat;
  rfd: cint;
begin
  SetLength(GZones, 0);
  a := R.Get('zones', TJSONArray(nil));
  if a = nil then Fail('no zones in the request');
  for i := 0 to a.Count - 1 do
  begin
    if a.Items[i].JSONType <> jtObject then Continue;
    o := TJSONObject(a.Items[i]);
    p := o.Get('path', '');
    if (p = '') or (o.Get('name', '') = '') then Continue;
    if o.Get('rw', False) then
    begin
      if not DirectoryExists(p) then ForceDirectories(p);             // the Public folder is created on first use, owned by this account
      fpChmod(p, &755);
    end;
    p := RealPathOf(p);
    if (p = '') or (fpStat(p, st) <> 0) or not fpS_ISDIR(st.st_mode) then Continue;
    if not o.Get('rw', False) then
      if st.st_uid <> fpGetUid then Continue;                          // read-only areas: only what this account owns
    n := Length(GZones); SetLength(GZones, n + 1);
    GZones[n].Name := o.Get('name', ''); GZones[n].Root := p; GZones[n].RW := o.Get('rw', False);
  end;
  rfd := 0;
  if rfd = 1 then;
end;

procedure Audit(R: TJSONObject; const Op: string; Resp: TJSONObject);
var
  f: TextFile;
  ap: string;
  o: TJSONObject;
begin
  ap := R.Get('audit', '');
  if ap = '' then Exit;
  o := TJSONObject.Create;
  try
    o.Add('ts', FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"', Now));
    o.Add('user', R.Get('user', ''));
    o.Add('op', Op);
    if R.Find('path') <> nil then o.Add('path', R.Get('path', ''));
    if R.Find('to_dir') <> nil then o.Add('to_dir', R.Get('to_dir', ''));
    if R.Find('name') <> nil then o.Add('name', R.Get('name', ''));
    if R.Find('cmd_logged') <> nil then o.Add('cmd', R.Get('cmd_logged', ''));
    o.Add('ok', Resp.Get('ok', False));
    if not Resp.Get('ok', False) then o.Add('error', Resp.Get('error', ''));
    try
      AssignFile(f, ap);
      if FileExists(ap) then Append(f) else Rewrite(f);
      WriteLn(f, o.FormatJSON([foSingleLineArray, foSingleLineObject, foSkipWhiteSpace], 0));
      CloseFile(f);
    except
    end;
  finally
    o.Free;
  end;
end;

procedure FsLoadZones(Req: TJSONObject);
begin
  LoadZones(Req);
end;

function FsRoots(RW: Boolean): TStringList;
var
  i: Integer;
begin
  Result := TStringList.Create;
  for i := 0 to High(GZones) do if GZones[i].RW = RW then Result.Add(GZones[i].Root);
end;

function FsResolveDir(const P: string; out RWZone: Boolean): string;
var
  Z: TZone;
  fd: cint;
begin
  fd := OpenDirPath(P, Z);               // every component without following links
  try
    RWZone := Z.RW;
    Result := RealPathOf('/proc/self/fd/' + IntToStr(fd));
  finally
    fpClose(fd);
  end;
end;

procedure FsAudit(Req: TJSONObject; const Op: string; Resp: TJSONObject);
begin
  Audit(Req, Op, Resp);
end;

function FsHandle(Req: TJSONObject): TJSONObject;
var
  op: string;
begin
  op := Req.Get('fsop', Req.Get('op', ''));       // the service's own request already uses "op" for the service (fs / exec)
  try
    LoadZones(Req);
    if op = 'zones' then
    begin
      Result := TJSONObject.Create(['ok', True]);
      Exit;
    end
    else if op = 'list' then Result := OpList(Req)
    else if op = 'stat' then Result := OpStat(Req)
    else if op = 'read' then Result := OpRead(Req)
    else if op = 'mkdir' then Result := OpMkdir(Req)
    else if op = 'newfile' then Result := OpNewFile(Req)
    else if op = 'rename' then Result := OpRename(Req)
    else if op = 'move' then Result := OpMove(Req)
    else if op = 'copy' then Result := OpCopy(Req)
    else if op = 'write' then Result := OpWrite(Req)
    else if op = 'delete' then Result := OpDelete(Req)
    else if op = 'empty_trash' then Result := OpEmptyTrash(Req)
    else if op = 'open' then Result := OpOpen(Req)
    else Fail('unknown file operation: ' + op);
  except
    on E: Exception do Result := TJSONObject.Create(['ok', False, 'error', E.Message]);
  end;
  if (op <> 'list') and (op <> 'stat') and (op <> 'read') and (op <> 'zones') then Audit(Req, op, Result);
end;

end.
