(* =============================================================================
  sup_util — small shared helpers: variable expansion, atomic file writes, a size-capped log, time stamps.
  ============================================================================= *)
unit sup_util;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, StrUtils, Classes, BaseUnix, DateUtils;

{ ${NAME} -> value from Vars (NAME=VALUE lines); ${ENV:NAME} -> environment variable; unknown names stay empty. }
function ExpandVars(const S: string; Vars: TStrings): string;

{ Write a whole file atomically (temp + rename): a reader never sees half a file. }
procedure WriteFileAtomic(const Path, Data: string; Mode: Integer = &644);
function ReadFileString(const Path: string): string;

{ Append one timestamped line to a log, rotating at MaxKB (keeping Path.1 .. Path.Keep). }
procedure LogLine(const Path: string; const Msg: string; MaxKB: Integer = 1024; Keep: Integer = 3);

{ Rotate a log file that a CHILD is writing to (we hold no handle): call before starting the child. }
procedure RotateFile(const Path: string; MaxKB, Keep: Integer);

function NowStamp: string;                 // yyyy-mm-dd hh:nn:ss (local)
function UnixNow: Int64;
function SafeName(const S: string): string; // for file names derived from config names

implementation

function ExpandVars(const S: string; Vars: TStrings): string;
var
  i, j: Integer;
  name, val: string;
begin
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    if (S[i] = '$') and (i < Length(S)) and (S[i + 1] = '{') then
    begin
      j := PosEx('}', S, i + 2);
      if j > 0 then
      begin
        name := Copy(S, i + 2, j - i - 2);
        if Copy(name, 1, 4) = 'ENV:' then val := GetEnvironmentVariable(Copy(name, 5, MaxInt))
        else if Assigned(Vars) then val := Vars.Values[name]
        else val := '';
        Result := Result + val;
        i := j + 1;
        Continue;
      end;
    end;
    Result := Result + S[i];
    Inc(i);
  end;
end;

procedure WriteFileAtomic(const Path, Data: string; Mode: Integer);
var
  tmp: string;
  fs: TFileStream;
begin
  tmp := Path + '.' + IntToStr(fpGetpid) + '.tmp';
  fs := TFileStream.Create(tmp, fmCreate);
  try
    if Data <> '' then fs.WriteBuffer(Data[1], Length(Data));
  finally
    fs.Free;
  end;
  fpChmod(tmp, Mode);
  RenameFile(tmp, Path);
end;

function ReadFileString(const Path: string): string;
var
  fs: TFileStream;
begin
  Result := '';
  if not FileExists(Path) then Exit;
  fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[1], fs.Size);
  finally
    fs.Free;
  end;
end;

procedure RotateFile(const Path: string; MaxKB, Keep: Integer);
var
  i: Integer;
  sr: TSearchRec;
  sz: Int64;
begin
  if (MaxKB <= 0) or not FileExists(Path) then Exit;
  sz := 0;
  if FindFirst(Path, faAnyFile, sr) = 0 then begin sz := sr.Size; FindClose(sr); end;
  if sz <= Int64(MaxKB) * 1024 then Exit;
  DeleteFile(Path + '.' + IntToStr(Keep));
  for i := Keep - 1 downto 1 do
    if FileExists(Path + '.' + IntToStr(i)) then RenameFile(Path + '.' + IntToStr(i), Path + '.' + IntToStr(i + 1));
  RenameFile(Path, Path + '.1');
end;

procedure LogLine(const Path: string; const Msg: string; MaxKB: Integer; Keep: Integer);
var
  f: TextFile;
begin
  try
    ForceDirectories(ExtractFilePath(Path));
    RotateFile(Path, MaxKB, Keep);
    AssignFile(f, Path);
    if FileExists(Path) then Append(f) else Rewrite(f);
    try
      WriteLn(f, NowStamp, '  ', Msg);
    finally
      CloseFile(f);
    end;
  except
    // a log that cannot be written must never take the supervisor down
  end;
end;

function NowStamp: string;
begin
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);
end;

function UnixNow: Int64;
begin
  Result := DateTimeToUnix(Now, False);          // Now is LOCAL time: convert to the true Unix epoch
end;

function SafeName(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    if S[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-', '.'] then Result := Result + S[i] else Result := Result + '_';
end;

end.
