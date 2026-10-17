(* =============================================================================
  aic_route — the middle of one turn of agent_loop.sh, after the request is read and before the prompt is assembled:

    * apply the capabilities the bridge staged in <project>/.cockpit_caps (Claude: the MCP file and the skill links; Ollama: the
      system-prompt text),
    * the Workers auto-route prompt (the providers workers.php lists, when the project has auto-route on),
    * the Local Tools auto-route prompt (the tool:preset pairs tools.php lists).

  Output: shell assignments (OLLAMA_CAPS_PROMPT, WORKERS_AUTO_PROMPT, TOOLS_AUTO_PROMPT, each single-quoted) for the loop to `eval`.
  The two lists are fetched from the web pages with the loop's internal key (COCKPIT_INTERNAL_KEY / COCKPIT_INTERNAL_USER in the
  environment, never on a command line).

  Exit 2 = refused, and the loop's Bash does it: Gemini's MCP settings merge (jq's output formatting is not copied), a skills file that is
  not the plain {"skills":{id:path}} shape, a provider or preset value that is not a string, a name with a control character.
  Everything that can refuse runs before the first file is written. tests/route_parity.sh proves the same results as the Bash + jq.
  ============================================================================= *)
unit aic_route;

{$mode objfpc}{$H+}

interface

type
  TRouteOptions = record
    Agent, Project, ProjectDir, DataDir, BaseUrl, Home: string;
  end;

{ the same as values. Lenient = what the Bash path would have been asked to do is done here instead of refusing: Gemini's MCP settings are merged
  (semantically; the file is rewritten by this program, not by jq), unusable skill entries and non-string provider names are skipped. }
function RunRouteEx(const O: TRouteOptions; Lenient: Boolean; out OutCaps, OutWorkers, OutTools, Msg: string): Integer;
function RunRoute(const O: TRouteOptions; out Shell, Msg: string): Integer;

implementation

uses
  SysUtils, Classes, BaseUnix, fpjson, jsonparser, fphttpclient;

function ReadWhole(const F: string): string;
var
  fs: TFileStream;
begin
  Result := '';
  if not FileExists(F) then Exit;
  try
    fs := TFileStream.Create(F, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Result, fs.Size);
      if fs.Size > 0 then fs.ReadBuffer(Result[1], fs.Size);
    finally
      fs.Free;
    end;
  except
    Result := '';
  end;
end;

function FileSize(const F: string): Int64;
var
  st: Stat;
begin
  if fpStat(F, st) <> 0 then Exit(0);
  Result := st.st_size;
end;

function CmdSubst(const S: string): string;
var
  i, n: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do if S[i] <> #0 then Result := Result + S[i];
  n := Length(Result);
  while (n > 0) and (Result[n] = #10) do Dec(n);
  SetLength(Result, n);
end;

function Q(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''\''''', [rfReplaceAll]) + '''';
end;

function HasCtl(const S: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 1 to Length(S) do if S[i] < ' ' then Exit(True);
end;

function ParseJson(const S: string): TJSONData;
begin
  Result := nil;
  try
    Result := GetJSON(S);
  except
    Result := nil;
  end;
end;


{ jq's  A * B  for two objects: keys of B are merged into A, two objects merge recursively, anything else: B's value wins }
procedure MergeObjects(A, B: TJSONObject);
var
  i, k: Integer;
  nm: string;
  av: TJSONData;
begin
  for i := 0 to B.Count - 1 do
  begin
    nm := B.Names[i];
    av := A.Find(nm);
    if (av <> nil) and (av.JSONType = jtObject) and (B.Items[i].JSONType = jtObject) then MergeObjects(TJSONObject(av), TJSONObject(B.Items[i]))
    else
    begin
      k := A.IndexOfName(nm);
      if k >= 0 then A.Elements[nm] := B.Items[i].Clone      // keeps the key where it was, as jq does
      else A.Add(nm, B.Items[i].Clone);
    end;
  end;
end;

function ItemAt(D: TJSONData; I: Integer): TJSONData;
begin
  if D.JSONType = jtArray then Result := TJSONArray(D).Items[I] else Result := TJSONObject(D).Items[I];
end;

{ the GET of the Bash:  curl -s --max-time 4 [headers] URL  (a failed request is an empty answer; any HTTP status gives its body) }
function HttpGetBody(const Url: string): string;
var
  c: TFPHTTPClient;
  ms: TMemoryStream;
  key, user: string;
begin
  Result := '';
  c := TFPHTTPClient.Create(nil);
  ms := TMemoryStream.Create;
  try
    c.ConnectTimeout := 4000; c.IOTimeout := 4000; c.AllowRedirect := False;
    key := GetEnvironmentVariable('COCKPIT_INTERNAL_KEY'); user := GetEnvironmentVariable('COCKPIT_INTERNAL_USER');
    if (key <> '') and (user <> '') then begin c.AddHeader('X-Cockpit-Internal', key); c.AddHeader('X-Cockpit-User', user); end;
    try
      c.HTTPMethod('GET', Url, ms, []);
      SetLength(Result, ms.Size);
      if ms.Size > 0 then Move(ms.Memory^, Result[1], ms.Size);
    except
      Result := '';
    end;
  finally
    ms.Free; c.Free;
  end;
end;

{ .auto_route_projects // [] | map(select(. == $p)) | length  = 1 ?   (an error in jq = empty = no) }
function AutoRouteOn(const StateFile, Project: string): Boolean;
var
  d, a: TJSONData;
  i, cnt: Integer;
  it: TJSONData;
begin
  Result := False;
  if not FileExists(StateFile) then Exit;
  d := ParseJson(ReadWhole(StateFile));
  if d = nil then Exit;
  try
    if d.JSONType <> jtObject then Exit;                       // null, array, string ...: jq fails or finds nothing
    a := TJSONObject(d).Find('auto_route_projects');
    if (a = nil) or (a.JSONType = jtNull) or ((a.JSONType = jtBoolean) and not a.AsBoolean) then Exit;   // // []  -> 0
    if not (a.JSONType in [jtArray, jtObject]) then Exit;      // map on a string, number or true is an error
    cnt := 0;
    for i := 0 to a.Count - 1 do
    begin
      it := ItemAt(a, i);
      if (it.JSONType = jtString) and (it.AsString = Project) then Inc(cnt);
    end;
    Result := cnt = 1;
  finally
    d.Free;
  end;
end;

{ the list item of a response:  .<top> // [] | map(.<field>) ; Fail = something the Bash's jq program does that is not copied here.
  Items = the field values in order; a null stays null (marked with a leading #0). Returns False when jq would print nothing. }
function ListField(const Body, Top, Field: string; Items: TStringList; out Fail: Boolean): Boolean;
var
  d, a, it, v: TJSONData;
  i: Integer;
begin
  Result := False; Fail := False;
  d := ParseJson(Body);
  if d = nil then Exit;                                        // not JSON: jq prints nothing
  try
    if d.JSONType <> jtObject then Exit;                       // .models on an array / string is an error
    a := TJSONObject(d).Find(Top);
    if (a = nil) or (a.JSONType = jtNull) or ((a.JSONType = jtBoolean) and not a.AsBoolean) then begin Result := True; Exit; end;   // // []
    if not (a.JSONType in [jtArray, jtObject]) then Exit;
    for i := 0 to a.Count - 1 do
    begin
      it := ItemAt(a, i);
      if it.JSONType = jtNull then begin Items.Add(#0); Continue; end;
      if it.JSONType <> jtObject then Exit;                    // .provider on a string or number is an error
      v := TJSONObject(it).Find(Field);
      if (v = nil) or (v.JSONType = jtNull) then Items.Add(#0)
      else if v.JSONType = jtString then
      begin
        if Pos(#0, v.AsString) > 0 then begin Fail := True; Exit; end;
        Items.Add(v.AsString);
      end
      else begin Fail := True; Exit; end;                      // numbers, booleans, objects: join/unique formatting is not copied
    end;
    Result := True;
  finally
    d.Free;
  end;
end;

function ByteCompare(List: TStringList; A, B: Integer): Integer;
begin
  Result := CompareStr(List[A], List[B]);      // jq sorts strings by code point = by UTF-8 byte
end;

function JoinItems(Items: TStringList): string;
var
  i: Integer;
  s: string;
begin
  Result := '';
  for i := 0 to Items.Count - 1 do
  begin
    s := Items[i]; if s = #0 then s := '';
    if i > 0 then Result := Result + ', ';
    Result := Result + s;
  end;
end;

function RunRouteEx(const O: TRouteOptions; Lenient: Boolean; out OutCaps, OutWorkers, OutTools, Msg: string): Integer;
var
  stage, caps, workers, tools, avail, tavail, f, key, path, dest, base: string;
  items: TStringList;
  fail, skills: Boolean;
  sk, skJson: TJSONData;
  i, j: Integer;
  names, paths: TStringList;
  toDo: Boolean;
  geminiMerge, dupe: Boolean;
  a1, a2: TJSONData;
begin
  OutCaps := ''; OutWorkers := ''; OutTools := ''; Msg := ''; Result := 0;
  caps := ''; workers := ''; tools := '';
  if (O.Agent = '') or (O.ProjectDir = '') or (O.DataDir = '') then begin Msg := 'missing option'; Exit(2); end;
  base := O.BaseUrl; while (base <> '') and (base[Length(base)] = '/') do SetLength(base, Length(base) - 1);
  stage := O.ProjectDir + '/.cockpit_caps';
  names := TStringList.Create; paths := TStringList.Create; items := TStringList.Create;
  try
    // ---- capabilities: decide everything first
    skills := False; geminiMerge := False;
    if DirectoryExists(stage) then
    begin
      if O.Agent = 'gemini' then
      begin
        if FileSize(stage + '/gemini_mcp.json') > 0 then
        begin
          if not Lenient then begin Msg := 'gemini MCP settings merge is done by the Bash'; Exit(2); end;
          geminiMerge := True;
        end;
      end
      else if O.Agent = 'claude' then
      begin
        if FileSize(stage + '/claude_skills.json') > 0 then
        begin
          skills := True;
          skJson := ParseJson(ReadWhole(stage + '/claude_skills.json'));
          if skJson <> nil then
          try
            sk := nil;
            if skJson.JSONType = jtObject then sk := TJSONObject(skJson).Find('skills')
            else if not Lenient then begin Msg := 'skills file is not an object'; Exit(2); end;
            if (sk <> nil) and (sk.JSONType <> jtNull) and (sk.JSONType <> jtObject) then
            begin
              if not Lenient then begin Msg := 'skills is not an object'; Exit(2); end;
              sk := nil;
            end;
            if (sk = nil) or (sk.JSONType = jtNull) then
            begin
              if (not Lenient) and (skJson.JSONType = jtObject) then begin Msg := 'skills missing: jq errors on null'; Exit(2); end;
            end
            else
              for i := 0 to sk.Count - 1 do
              begin
                key := TJSONObject(sk).Names[i];
                if TJSONObject(sk).Items[i].JSONType <> jtString then
                begin
                  if Lenient then Continue;
                  Msg := 'a skill path is not a string'; Exit(2);
                end;
                path := TJSONObject(sk).Items[i].AsString;
                if (key = '') or HasCtl(key) or HasCtl(path) or (Pos(#0, key) > 0) then
                begin
                  if Lenient then Continue;
                  Msg := 'an unusable skill entry'; Exit(2);
                end;
                dupe := False;
                for j := 0 to names.Count - 1 do if names[j] = key then dupe := True;
                if dupe then begin if Lenient then Continue; Msg := 'duplicate skill id'; Exit(2); end;
                names.Add(key); paths.Add(path);
              end;
          finally
            skJson.Free;
          end;
        end;
      end
      else if O.Agent = 'ollama' then
      begin
        if FileSize(stage + '/ollama_system_prompt.txt') > 0 then caps := CmdSubst(ReadWhole(stage + '/ollama_system_prompt.txt'));
      end;
    end;

    // ---- the two lists (read-only requests): anything that refuses does so before a file is written
    avail := ''; tavail := '';
    if AutoRouteOn(O.DataDir + '/workers_state.json', O.Project) then
    begin
      items.Clear;
      if ListField(HttpGetBody(base + '/workers.php?action=models'), 'models', 'provider', items, fail) or fail then
      begin
        if fail and not Lenient then begin Msg := 'a provider is not a string'; Exit(2); end;
        // unique = sorted, no repeats; null sorts before every string
        items.CustomSort(@ByteCompare); i := 0;
        while i < items.Count - 1 do if items[i] = items[i + 1] then items.Delete(i + 1) else Inc(i);
        avail := JoinItems(items);
      end;
    end;
    if (avail <> '') and (avail <> 'null') then
      workers := #10 + '[SYSTEM: Workers Auto-Route Available]' + #10 +
        'For tasks outside your specialty (image generation, audio, niche translations,' + #10 +
        'or when you''ve hit token limits), you can dispatch to online specialty workers' + #10 +
        'by emitting a marker like:' + #10 +
        '    %%WORKER:provider:task:prompt%%' + #10 + #10 +
        'Available providers: ' + avail + #10 +
        'Tasks: text, translate, summary, image, image-gen, audio, code' + #10 + #10 +
        'The result will be returned to you in the next turn as %%WORKER_RESULT:...%%.' + #10 +
        'Use sparingly — only when your own capabilities don''t suffice.' + #10;
    if AutoRouteOn(O.DataDir + '/tools_state.json', O.Project) then
    begin
      items.Clear;
      if ListField(HttpGetBody(base + '/tools.php?action=presets'), 'presets', 'value', items, fail) or fail then
      begin
        if fail and not Lenient then begin Msg := 'a preset value is not a string'; Exit(2); end;
        tavail := JoinItems(items);
      end;
    end;
    if (tavail <> '') and (tavail <> 'null') then
      tools := #10 + '[SYSTEM: Local Tools Auto-Route Available]' + #10 +
        'For file conversions and transformations (media, audio, transcription, document' + #10 +
        'formats, ebooks, subtitles), you can dispatch to local CLI tools by emitting:' + #10 +
        '    %%TOOL:tool:preset:input_path%%' + #10 +
        'or with extra arguments:' + #10 +
        '    %%TOOL:tool:preset:input_path|extra_args%%' + #10 + #10 +
        'Available tool:preset pairs: ' + tavail + #10 + #10 +
        'The output path is returned in the next turn as %%TOOL_RESULT:tool:output_path%%.' + #10 +
        'Use these for offline file operations — no internet required.' + #10;

    // ---- now the side effects
    if geminiMerge then
    begin
      ForceDirectories(O.Home + '/.gemini');
      dest := O.Home + '/.gemini/settings.json';
      if not FileExists(dest) then
        with TFileStream.Create(dest, fmCreate) do try f := '{}' + #10; WriteBuffer(f[1], Length(f)); finally Free; end;
      a1 := ParseJson(ReadWhole(dest)); a2 := ParseJson(ReadWhole(stage + '/gemini_mcp.json'));
      try
        if (a1 <> nil) and (a2 <> nil) and (a1.JSONType = jtObject) and (a2.JSONType = jtObject) then
        begin
          MergeObjects(TJSONObject(a1), TJSONObject(a2));
          f := a1.FormatJSON([], 2) + #10;
          with TFileStream.Create(dest, fmCreate) do try WriteBuffer(f[1], Length(f)); finally Free; end;
        end;
      finally
        a1.Free; a2.Free;
      end;
    end;
    if DirectoryExists(stage) and (O.Agent = 'claude') then
    begin
      if FileSize(stage + '/claude_mcp.json') > 0 then
      begin
        f := ReadWhole(stage + '/claude_mcp.json'); dest := O.ProjectDir + '/.mcp.json';
        try
          with TFileStream.Create(dest, fmCreate) do try if f <> '' then WriteBuffer(f[1], Length(f)); finally Free; end;
        except
        end;
      end;
      if skills then
      begin
        ForceDirectories(O.Home + '/.claude/skills');
        for i := 0 to names.Count - 1 do
          if (paths[i] <> '') and FileExists(paths[i]) then
          begin
            dest := O.Home + '/.claude/skills/' + names[i] + '.md';
            if DirectoryExists(dest) and (fpReadLink(dest) = '') then Continue;
            fpUnlink(dest);
            fpSymlink(PChar(paths[i]), PChar(dest));
          end;
      end;
    end;
  finally
    names.Free; paths.Free; items.Free;
  end;
  OutCaps := caps; OutWorkers := workers; OutTools := tools;
end;

function RunRoute(const O: TRouteOptions; out Shell, Msg: string): Integer;
var
  c, w, t: string;
begin
  Shell := '';
  Result := RunRouteEx(O, False, c, w, t, Msg);
  if Result <> 0 then Exit;
  Shell := 'OLLAMA_CAPS_PROMPT=' + Q(c) + #10 + 'WORKERS_AUTO_PROMPT=' + Q(w) + #10 + 'TOOLS_AUTO_PROMPT=' + Q(t) + #10;
end;

end.
