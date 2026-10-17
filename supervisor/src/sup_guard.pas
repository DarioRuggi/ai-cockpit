(* =============================================================================
  sup_guard — keeps the files Cockpit shipped as they were shipped.

  Replaces cockpit_guard.sh (an inotifywait loop under systemd).  A manifest (integrity.json:
  {"files": {"relative/path": "sha256", ...}}) says what every shipped file must hash to.  Every
  interval_s the guard compares each listed file with it:

    * a file whose size / mtime / inode have not changed since it last verified OK is NOT re-hashed
      (a stat per file: a thousand files cost about a millisecond), so polling is cheap;
    * a file that differs or is missing is a VIOLATION: a dated line goes to the guard log, a flag file
      is written (the app shows its integrity warning on its next poll), and, when restore=copy, the
      shipped copy is put back from restore_from — but ONLY if that source copy itself hashes to the
      manifest value (a tampered backup is never used), written through a temp file + rename so a
      reader never sees half a file.  The restore is verified again afterwards.
    * files NOT in the manifest are none of its business; the manifest itself is re-read when it changes
      (a deploy replaces it), and a path with ".." or a leading "/" in the manifest is ignored.

  Why polling and not inotify: inotify is Linux-only; polling behaves the same on macOS and Windows and
  its worst case is one interval of delay.  (The old guard also could not PREVENT a change; neither can
  this one: it makes a change a logged, flagged, self-healed event.)
  ============================================================================= *)
unit sup_guard;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, BaseUnix, fgl, fpjson, jsonparser, sup_util, sup_config, sup_sha256;

type
  { string -> string, kept sorted: a lookup is a binary search (a thousand files must not cost a million string compares) }
  TStrMap = specialize TFPGMap<string, string>;

  TGuardRunner = class
  private
    FDef: TGuardDef;
    FManifestSig: string;
    FFiles: TStrMap;                // rel -> sha256
    FVerified: TStrMap;             // rel -> signature of the last state that hashed OK
    FReported: TStrMap;             // rel -> signature already logged as a violation (log once per distinct state)
    FNextCheck: QWord;
    FManifestMissingLogged: Boolean;
    procedure LoadManifest;
    function Signature(const Path: string): string;
    function Restore(const Rel, Want: string): Boolean;
    procedure Violation(const Rel, What, Have, Want, Sig: string);
  public
    Checks, FilesCount, Violations, Restored: Integer;
    LastCheckAt: Int64;
    LastViolation: string;
    constructor Create(ADef: TGuardDef);
    destructor Destroy; override;
    { Do a pass when it is time; returns True when a pass ran. }
    function Tick(NowMs: QWord): Boolean;
    function Pass: Integer;         // one pass right now; returns the number of violations seen
    property Def: TGuardDef read FDef;
  end;

implementation

function MGet(M: TStrMap; const K: string): string;
var
  i: Integer;
begin
  i := M.IndexOf(K);
  if i < 0 then Result := '' else Result := M.Data[i];
end;

procedure MPut(M: TStrMap; const K, V: string);
var
  i: Integer;
begin
  i := M.IndexOf(K);
  if i >= 0 then M.Data[i] := V else M.Add(K, V);
end;

constructor TGuardRunner.Create(ADef: TGuardDef);
begin
  inherited Create;
  FDef := ADef;
  FFiles := TStrMap.Create; FFiles.Sorted := True;
  FVerified := TStrMap.Create; FVerified.Sorted := True;
  FReported := TStrMap.Create; FReported.Sorted := True;
  FNextCheck := 0;
end;

destructor TGuardRunner.Destroy;
begin
  FFiles.Free; FVerified.Free; FReported.Free;
  FDef.Free;                       // the runner owns the definition the loader parsed
  inherited Destroy;
end;

function TGuardRunner.Signature(const Path: string): string;
var
  st: Stat;
begin
  if fpStat(Path, st) <> 0 then Exit('');
  Result := IntToStr(st.st_size) + ':' + IntToStr(st.st_mtime) + ':' + IntToStr(st.st_ino);
  {$IFDEF LINUX}
  Result := Result + ':' + IntToStr(st.st_mtime_nsec);
  {$ENDIF}
end;

procedure TGuardRunner.LoadManifest;
var
  st: Stat;
  sig: string;
  d: TJSONData;
  f: TJSONData;
  o: TJSONObject;
  i: Integer;
  rel: string;
begin
  if fpStat(FDef.Manifest, st) <> 0 then
  begin
    if not FManifestMissingLogged then
    begin
      LogLine(FDef.LogFile, '[' + FDef.Name + '] manifest not found: ' + FDef.Manifest + ' (nothing is checked until it exists)');
      FManifestMissingLogged := True;
    end;
    FFiles.Clear; FilesCount := 0; FManifestSig := '';
    Exit;
  end;
  FManifestMissingLogged := False;
  sig := IntToStr(st.st_size) + ':' + IntToStr(st.st_mtime) + ':' + IntToStr(st.st_ino);
  if sig = FManifestSig then Exit;                   // unchanged since the last read
  try
    d := GetJSON(ReadFileString(FDef.Manifest));
  except
    on E: Exception do begin LogLine(FDef.LogFile, '[' + FDef.Name + '] manifest is not valid JSON: ' + E.Message); FManifestSig := sig; Exit; end;
  end;
  try
    FFiles.Clear;
    FVerified.Clear; FReported.Clear;                // a new manifest means everything is checked afresh
    if (d.JSONType = jtObject) then
    begin
      f := TJSONObject(d).Find('files');
      if (f <> nil) and (f.JSONType = jtObject) then o := TJSONObject(f) else o := TJSONObject(d);
      for i := 0 to o.Count - 1 do
      begin
        rel := o.Names[i];
        if (rel = '') or (rel[1] = '/') or (Pos('..', rel) > 0) then Continue;            // never leave the root
        if o.Items[i].JSONType <> jtString then Continue;
        MPut(FFiles, rel, LowerCase(o.Items[i].AsString));
      end;
    end;
    FilesCount := FFiles.Count;
    FManifestSig := sig;
    LogLine(FDef.LogFile, '[' + FDef.Name + '] manifest loaded: ' + IntToStr(FilesCount) + ' files, root ' + FDef.Root + ', restore=' + FDef.Restore);
  finally
    d.Free;
  end;
end;

function CopyFileAtomic(const Src, Dst: string): Boolean;
var
  st: Stat;
  data: string;
begin
  Result := False;
  if not FileExists(Src) then Exit;
  data := ReadFileString(Src);
  ForceDirectories(ExtractFilePath(Dst));
  if fpStat(Src, st) <> 0 then st.st_mode := &644;
  WriteFileAtomic(Dst, data, st.st_mode and &7777);
  Result := True;
end;

function TGuardRunner.Restore(const Rel, Want: string): Boolean;
var
  src, dst, h: string;
begin
  Result := False;
  if FDef.Restore <> 'copy' then Exit;
  src := IncludeTrailingPathDelimiter(FDef.RestoreFrom) + Rel;
  dst := IncludeTrailingPathDelimiter(FDef.Root) + Rel;
  if not Sha256File(src, h) then
  begin
    LogLine(FDef.LogFile, '[' + FDef.Name + '] RESTORE FAILED ' + Rel + ': no kept copy at ' + src);
    Exit;
  end;
  if h <> Want then
  begin
    LogLine(FDef.LogFile, '[' + FDef.Name + '] RESTORE REFUSED ' + Rel + ': the kept copy does not match the manifest (' + Copy(h, 1, 12) + ' vs ' + Copy(Want, 1, 12) + ')');
    Exit;
  end;
  if not CopyFileAtomic(src, dst) then begin LogLine(FDef.LogFile, '[' + FDef.Name + '] RESTORE FAILED ' + Rel + ': could not write ' + dst); Exit; end;
  if Sha256File(dst, h) and (h = Want) then
  begin
    Result := True;
    LogLine(FDef.LogFile, '[' + FDef.Name + '] RESTORED ' + Rel);
  end
  else LogLine(FDef.LogFile, '[' + FDef.Name + '] RESTORE FAILED ' + Rel + ': the written file does not verify');
end;

procedure TGuardRunner.Violation(const Rel, What, Have, Want, Sig: string);
var
  didRestore: Boolean;
begin
  if MGet(FReported, Rel) = Sig then Exit;          // already reported this exact state
  MPut(FReported, Rel, Sig);
  Inc(Violations);
  LastViolation := What + ' ' + Rel;
  LogLine(FDef.LogFile, '[' + FDef.Name + '] ' + What + '  ' + Rel + '  sha=' + Copy(Have, 1, 12) + '  expected=' + Copy(Want, 1, 12));
  didRestore := Restore(Rel, Want);
  if didRestore then
  begin
    Inc(Restored);
    MPut(FReported, Rel, '');
    MPut(FVerified, Rel, Signature(IncludeTrailingPathDelimiter(FDef.Root) + Rel));
  end;
  WriteFileAtomic(FDef.FlagFile,
    '{"changed_at":"' + FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now) + '","guard":"' + FDef.Name + '","file":"' + StringReplace(Rel, '"', '\"', [rfReplaceAll]) +
    '","event":"' + What + '","restored":' + LowerCase(BoolToStr(didRestore, 'true', 'false')) + '}' + #10);
end;

function TGuardRunner.Pass: Integer;
var
  i: Integer;
  rel, want, path, sig, have: string;
begin
  Result := 0;
  LoadManifest;
  for i := 0 to FFiles.Count - 1 do
  begin
    rel := FFiles.Keys[i];
    want := FFiles.Data[i];
    path := IncludeTrailingPathDelimiter(FDef.Root) + rel;
    sig := Signature(path);
    if sig = '' then
    begin
      MPut(FVerified, rel, '');
      Violation(rel, 'MISSING', 'missing', want, 'missing');
      if FileExists(path) then Continue;
      Inc(Result);
      Continue;
    end;
    if MGet(FVerified, rel) = sig then Continue;                 // untouched since it last verified OK
    if Sha256File(path, have) and (have = want) then
    begin
      MPut(FVerified, rel, sig);
      MPut(FReported, rel, '');
      Continue;
    end;
    Inc(Result);
    Violation(rel, 'CHANGED', have, want, sig);
  end;
  Inc(Checks);
  LastCheckAt := UnixNow;
end;

function TGuardRunner.Tick(NowMs: QWord): Boolean;
begin
  Result := False;
  if (not FDef.Enabled) or (NowMs < FNextCheck) then Exit;
  FNextCheck := NowMs + QWord(FDef.IntervalS) * 1000;
  Pass;
  Result := True;
end;

end.
