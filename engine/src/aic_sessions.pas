(* =============================================================================
  aic_sessions — which agent conversation belongs to which Cockpit chat.

  A CLI agent keeps its own conversation under a session id (Claude Code's --resume ID, Gemini's -r ...).
  Cockpit chats are named by Cockpit.  This small store remembers   adapter + chat  ->  session id, so a
  request that carries a `chat` name and no explicit `session` resumes the right conversation, and the
  id the agent reports at the end of a run is saved for the next turn.

  Many runs finish at the same moment (each is its own process), so every read-modify-write holds an
  exclusive flock on a lock file and replaces the data file atomically (write a temp file, rename it).
  A crash can therefore never leave half a JSON file behind.
  ============================================================================= *)
unit aic_sessions;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, BaseUnix, Unix, fpjson, jsonparser;

type
  TSessionStore = class
  private
    FFile, FLock: string;
    FLockFd: cint;
    procedure Lock;
    procedure Unlock;
    function Load: TJSONObject;
    procedure Save(Doc: TJSONObject);
  public
    constructor Create(const AFile: string);
    function Get(const Adapter, Chat: string): string;
    procedure Put(const Adapter, Chat, SessionId: string);
    procedure Clear(const Adapter, Chat: string);       // either may be '' = all
    function AsJson: string;
  end;

implementation

constructor TSessionStore.Create(const AFile: string);
begin
  inherited Create;
  FFile := AFile;
  FLock := AFile + '.lock';
  FLockFd := -1;
end;

procedure TSessionStore.Lock;
begin
  FLockFd := fpOpen(FLock, O_WRONLY or O_CREAT, &600);
  if FLockFd >= 0 then fpFlock(FLockFd, LOCK_EX);
end;

procedure TSessionStore.Unlock;
begin
  if FLockFd >= 0 then begin fpFlock(FLockFd, LOCK_UN); fpClose(FLockFd); FLockFd := -1; end;
end;

function TSessionStore.Load: TJSONObject;
var
  sl: TStringList;
  d: TJSONData;
begin
  Result := nil;
  if FileExists(FFile) then
  begin
    sl := TStringList.Create;
    try
      sl.LoadFromFile(FFile);
      try d := GetJSON(sl.Text); except d := nil; end;
      if (d <> nil) and (d.JSONType = jtObject) then Result := TJSONObject(d) else d.Free;
    finally
      sl.Free;
    end;
  end;
  if Result = nil then Result := TJSONObject.Create;
end;

procedure TSessionStore.Save(Doc: TJSONObject);
var
  sl: TStringList;
  tmp: string;
begin
  tmp := FFile + '.' + IntToStr(fpGetpid) + '.tmp';
  sl := TStringList.Create;
  try
    sl.Text := Doc.FormatJSON;
    sl.SaveToFile(tmp);
  finally
    sl.Free;
  end;
  fpChmod(tmp, &600);
  RenameFile(tmp, FFile);                 // atomic on the same filesystem
end;

function TSessionStore.Get(const Adapter, Chat: string): string;
var
  doc: TJSONObject;
  a: TJSONObject;
begin
  Result := '';
  Lock;
  try
    doc := Load;
    try
      a := doc.Get(Adapter, TJSONObject(nil));
      if a <> nil then Result := a.Get(Chat, '');
    finally
      doc.Free;
    end;
  finally
    Unlock;
  end;
end;

procedure TSessionStore.Put(const Adapter, Chat, SessionId: string);
var
  doc: TJSONObject;
  a: TJSONObject;
begin
  if (Adapter = '') or (Chat = '') or (SessionId = '') then Exit;
  Lock;
  try
    doc := Load;
    try
      a := doc.Get(Adapter, TJSONObject(nil));
      if a = nil then begin a := TJSONObject.Create; doc.Add(Adapter, a); end;
      a.Strings[Chat] := SessionId;
      Save(doc);
    finally
      doc.Free;
    end;
  finally
    Unlock;
  end;
end;

procedure TSessionStore.Clear(const Adapter, Chat: string);
var
  doc: TJSONObject;
  a: TJSONObject;
  i: Integer;
begin
  Lock;
  try
    doc := Load;
    try
      if Adapter = '' then doc.Clear
      else
      begin
        a := doc.Get(Adapter, TJSONObject(nil));
        if a <> nil then
        begin
          if Chat = '' then begin i := doc.IndexOfName(Adapter); if i >= 0 then doc.Delete(i); end
          else begin i := a.IndexOfName(Chat); if i >= 0 then a.Delete(i); end;
        end;
      end;
      Save(doc);
    finally
      doc.Free;
    end;
  finally
    Unlock;
  end;
end;

function TSessionStore.AsJson: string;
var
  doc: TJSONObject;
begin
  Lock;
  try
    doc := Load;
    try
      Result := doc.AsJSON;
    finally
      doc.Free;
    end;
  finally
    Unlock;
  end;
end;

end.
