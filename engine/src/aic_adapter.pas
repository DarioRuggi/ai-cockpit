(* =============================================================================
  aic_adapter — the adapter CATALOG (data first).

  One JSON file per agent / model API / tool in adapters/.  The engine has no code that is specific to
  "claude" or "codex"; it reads these.  Fields:

    id, display, kind (agent | model-api | tool), transport (process | http)
    command                program to run (transport process)
    args                   the argument TEMPLATE, an array.  Each element is either
                             "a string, with {prompt} {model} {session} {cwd} placeholders"
                           or an object   {"when":"model","args":["--model","{model}"]}
                             which is included only when that request field is non-empty
                           The prompt goes in as ONE argument, so quotes, newlines, "; rm -rf",
                           Hebrew text and $(...) in a prompt are just bytes.  No shell is ever involved.
    prompt_via             "arg" (default) | "stdin"   (very long prompts do not fit an argument)
    url, body_template     transport http: where to POST and the JSON body template
    parser                 plain | claude_stream_json | ollama_ndjson | jsonl_generic ...
    detect                 {"cmd": "...", "version_args": [...]}   (or {"url": "..."} for http)
    session                {"resume_args":[...]} how a conversation is resumed; absent = history replay
    tiers                  {"read_only":[args], "edit":[args], "shell":[args]} extra args per permission
                           tier.  A tier that is ABSENT is not supported: the engine refuses to run it
                           (it never silently runs with MORE rights than were asked for).
    env                    extra environment variables
    env_secret             names of env vars whose VALUES are secrets (masked in every event)
    cwd_policy             project | none
    limits                 {"timeout_s":N, "max_output_kb":N}
    docs_checked, terms_checked     dates the author last verified the vendor docs / terms
  ============================================================================= *)
unit aic_adapter;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser;

type
  { What one request asks for.  Everything the template placeholders can use. }
  TRunRequest = record
    Prompt: string;
    System: string;          // optional system prompt (chat APIs)
    Messages: string;        // optional JSON array of {role,content}: the conversation so far; Prompt is appended as the user turn
    Model: string;
    SessionId: string;
    Cwd: string;
    Tier: string;            // read_only (default) | edit | shell
    TimeoutS: Integer;       // 0 = use the adapter's limit
    MaxOutputKB: Integer;    // 0 = use the adapter's limit
  end;

  TAdapter = class
  public
    Id, Display, Kind, Transport, Command, Url, Parser, PromptVia, CwdPolicy: string;
    Doc: TJSONObject;        // the whole document, for adapter-specific keys
    constructor Create(ADoc: TJSONObject);
    destructor Destroy; override;

    { Full argv (without the program) for a request, or '' + error text when the request cannot be built. }
    function BuildArgs(const Req: TRunRequest; out Args: TStringList; out Err: string): Boolean;
    function TierSupported(const Tier: string): Boolean;
    function LimitTimeout(const Req: TRunRequest): Integer;
    function LimitOutputKB(const Req: TRunRequest): Integer;
    procedure SecretValues(Dest: TStrings);      // values of env_secret variables currently set
  end;

  TAdapterList = class
  private
    FItems: TList;
    function GetCount: Integer;
    function GetItem(I: Integer): TAdapter;
  public
    constructor Create;
    destructor Destroy; override;
    procedure LoadDir(const Dir: string);
    function Find(const Id: string): TAdapter;
    property Count: Integer read GetCount;
    property Items[I: Integer]: TAdapter read GetItem; default;
  end;

{ Replace {prompt} {model} {session} {cwd} in one template string. }
function ExpandPlaceholders(const T: string; const Req: TRunRequest): string;

implementation

function ExpandPlaceholders(const T: string; const Req: TRunRequest): string;
begin
  Result := T;
  Result := StringReplace(Result, '{prompt}', Req.Prompt, [rfReplaceAll]);
  Result := StringReplace(Result, '{model}', Req.Model, [rfReplaceAll]);
  Result := StringReplace(Result, '{session}', Req.SessionId, [rfReplaceAll]);
  Result := StringReplace(Result, '{cwd}', Req.Cwd, [rfReplaceAll]);
end;

{ ---- TAdapter ---------------------------------------------------------------------------------- }

constructor TAdapter.Create(ADoc: TJSONObject);
begin
  inherited Create;
  Doc := ADoc;
  Id := Doc.Get('id', '');
  Display := Doc.Get('display', Id);
  Kind := Doc.Get('kind', 'agent');
  Transport := Doc.Get('transport', 'process');
  Command := Doc.Get('command', '');
  Url := Doc.Get('url', '');
  Parser := Doc.Get('parser', 'plain');
  PromptVia := Doc.Get('prompt_via', 'arg');
  CwdPolicy := Doc.Get('cwd_policy', 'none');
end;

destructor TAdapter.Destroy;
begin
  Doc.Free;
  inherited Destroy;
end;

procedure AddTemplateArgs(Arr: TJSONArray; const Req: TRunRequest; Args: TStringList);
var
  i, k: Integer;
  el, sub: TJSONData;
  when: string;
  present: Boolean;
begin
  for i := 0 to Arr.Count - 1 do
  begin
    el := Arr[i];
    if el.JSONType = jtString then
      Args.Add(ExpandPlaceholders(el.AsString, Req))
    else if el.JSONType = jtObject then
    begin
      when := TJSONObject(el).Get('when', '');
      present := True;
      if when = 'model' then present := Req.Model <> ''
      else if when = 'session' then present := Req.SessionId <> ''
      else if when = 'cwd' then present := Req.Cwd <> '';
      if present then
      begin
        sub := TJSONObject(el).Find('args');
        if (sub <> nil) and (sub.JSONType = jtArray) then
          for k := 0 to TJSONArray(sub).Count - 1 do
            Args.Add(ExpandPlaceholders(TJSONArray(sub)[k].AsString, Req));
      end;
    end;
  end;
end;

function TAdapter.TierSupported(const Tier: string): Boolean;
var
  t: TJSONData;
begin
  t := Doc.FindPath('tiers.' + Tier);
  Result := (t <> nil) and (t.JSONType = jtArray);
end;

function TAdapter.BuildArgs(const Req: TRunRequest; out Args: TStringList; out Err: string): Boolean;
var
  a: TJSONData;
  tier: string;
  rs: TRunRequest;
begin
  Result := False;
  Err := '';
  Args := TStringList.Create;
  rs := Req;
  // With the prompt on stdin the {prompt} placeholder must not be filled with the whole text.
  if PromptVia = 'stdin' then rs.Prompt := '';
  a := Doc.Find('args');
  if (a <> nil) and (a.JSONType = jtArray) then AddTemplateArgs(TJSONArray(a), rs, Args);

  // session resume
  if (Req.SessionId <> '') then
  begin
    a := Doc.FindPath('session.resume_args');
    if (a <> nil) and (a.JSONType = jtArray) then AddTemplateArgs(TJSONArray(a), rs, Args);
  end;

  // permission tier: the default is the LOWEST right (read_only); an unsupported tier is refused.
  tier := Req.Tier;
  if tier = '' then tier := 'read_only';
  if not TierSupported(tier) then
  begin
    Err := 'adapter "' + Id + '" has no mapping for permission tier "' + tier + '"; refusing to run with unknown rights';
    Exit;
  end;
  a := Doc.FindPath('tiers.' + tier);
  AddTemplateArgs(TJSONArray(a), rs, Args);
  Result := True;
end;

function TAdapter.LimitTimeout(const Req: TRunRequest): Integer;
var
  d: TJSONData;
begin
  if Req.TimeoutS > 0 then Exit(Req.TimeoutS);
  d := Doc.FindPath('limits.timeout_s');
  if d <> nil then Result := d.AsInteger else Result := 600;     // 10 minutes unless the adapter says otherwise
end;

function TAdapter.LimitOutputKB(const Req: TRunRequest): Integer;
var
  d: TJSONData;
begin
  if Req.MaxOutputKB > 0 then Exit(Req.MaxOutputKB);
  d := Doc.FindPath('limits.max_output_kb');
  if d <> nil then Result := d.AsInteger else Result := 8192;    // 8 MB of raw output per run
end;

procedure TAdapter.SecretValues(Dest: TStrings);
var
  a: TJSONData;
  i: Integer;
  v: string;
begin
  a := Doc.Find('env_secret');
  if (a = nil) or (a.JSONType <> jtArray) then Exit;
  for i := 0 to TJSONArray(a).Count - 1 do
  begin
    // the adapter's own env block first (a key we are about to hand the child), then our environment
    v := '';
    if (Doc.Find('env') <> nil) and (Doc.Find('env').JSONType = jtObject) then
      v := TJSONObject(Doc.Find('env')).Get(TJSONArray(a)[i].AsString, '');
    if v = '' then v := GetEnvironmentVariable(TJSONArray(a)[i].AsString);
    if v <> '' then Dest.Add(v);
  end;
end;

{ ---- TAdapterList ------------------------------------------------------------------------------ }

constructor TAdapterList.Create;
begin
  inherited Create;
  FItems := TList.Create;
end;

destructor TAdapterList.Destroy;
var
  i: Integer;
begin
  for i := 0 to FItems.Count - 1 do TAdapter(FItems[i]).Free;
  FItems.Free;
  inherited Destroy;
end;

function TAdapterList.GetCount: Integer;
begin
  Result := FItems.Count;
end;

function TAdapterList.GetItem(I: Integer): TAdapter;
begin
  Result := TAdapter(FItems[I]);
end;

procedure TAdapterList.LoadDir(const Dir: string);
var
  sr: TSearchRec;
  fs: TFileStream;
  d: TJSONData;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.json', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Attr and faDirectory) <> 0 then Continue;
      fs := TFileStream.Create(IncludeTrailingPathDelimiter(Dir) + sr.Name, fmOpenRead or fmShareDenyNone);
      try
        try
          d := GetJSON(fs);
          if d.JSONType = jtObject then FItems.Add(TAdapter.Create(TJSONObject(d))) else d.Free;
        except
          on E: Exception do
            WriteLn(StdErr, 'adapter file ', sr.Name, ' skipped: ', E.Message);
        end;
      finally
        fs.Free;
      end;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function TAdapterList.Find(const Id: string): TAdapter;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FItems.Count - 1 do
    if TAdapter(FItems[i]).Id = Id then Exit(TAdapter(FItems[i]));
end;

end.
