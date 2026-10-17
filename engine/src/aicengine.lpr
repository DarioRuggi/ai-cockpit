(* =============================================================================
  aicengine — command line.

    aicengine detect [--adapters DIR]
    aicengine run ADAPTER --prompt TEXT | --prompt-file FILE
                  [--model M] [--session S] [--cwd DIR] [--tier read_only|edit|shell]
                  [--timeout SECONDS] [--max-output-kb N] [--record FILE] [--replay FILE]
    aicengine test ADAPTER|all [--replay|--live] [--fixtures DIR] [-v]
    aicengine record ADAPTER ...same options as run...      (a run that saves its raw output)
    aicengine localchat --model M --system-file F --user-file F --out FILE [--history-file F] [--base URL] [--style ollama|openai]
        The Ollama / OpenAI-compatible branch of agent_loop.sh: builds the chat request, pulls the model on first use, streams the reply.
    aicengine gemini --model M --prompt-file F --out FILE [--base URL] [--ca-file F] [--resolve IP] [--timeout S]     (key: env GEMINI_API_KEY)
        The Gemini REST branch of agent_loop.sh: one generateContent call over HTTPS (verified TLS), the answer or an [GEMINI ERROR] line appended to OUT_FILE.
    aicengine prompt --agent A --project P --project-dir D --chat-name C --data-dir D --user-file F --out F [--sys-out F] [--history-file F] [--rag-file F]
                  [--workers-file F] [--tools-file F] [--caps-file F] --crud-file F | --style-file F [--cli-supplier S] [--claude-model M] [--gemini-model M] [--model M] [--prompt-style xml|plain]
        assemble_prompt of agent_loop.sh: goal/kind/descriptions, COCKPIT.md, profile, global directives, identity line and the layout, into the prompt file(s).
    aicengine clean --agent A --out-file F --start-ns N [--usage-log F --model M --project P --chat C --prompt-chars N]
        What agent_loop.sh does with the raw answer: strip terminal artifacts (Ollama/Gemini), measure the duration (printed), write the Ollama usage line.
    aicengine signin-hint --agent A --agent-uc UC --out-file F
    aicengine intake --agent A --queue-dir D --response-dir D --prompt-file F --root D --prompt-out F
    aicengine route --agent A --project P --project-dir D --data-dir D --base-url U --home D
    aicengine loop <claude|gemini|ollama>
    aicengine fs --request-file F        the file window's operations (zones, confinement)
    aicengine exec --request-file F      one command, confined by Landlock
    aicengine crud PROJECT_DIR RESPONSE_FILE [PROPOSER] [PROJECT]   the %%markers%% of an answer (same results as scripts/crud_cli.php; exit 9 = refused)
    aicengine relay PROVIDER MODEL PROMPT_FILE                      the Workers relay (groq, huggingface, cloudflare) with no PHP (same text as worker_relay.php; exit 9 = refused)
    aicengine history needs|build|sync|add|append ...   the chat history (same interface as scripts/history_cli.php; exit 9 = refused)
        A short answer that says the CLI is not signed in gets a line telling where to sign in.
    aicengine legacy --prompt-file F --out FILE (--supplier ID --catalog FILE | --claude-model M)
                  [--model RAW] [--images a|b] [--extra-args "..."] [--local-base URL] [--cwd DIR] [--timeout S]
        Stands in for agent_loop.sh's run_generic_cli / Claude call: same command line, same plain-text OUT_FILE.

  Events are printed to stdout as JSON lines (one object per line, flushed immediately).
  Exit codes: the run's own (0 ok, 124 timeout, 125 output limit, 127 not found, 130 cancelled, ...);
  2 for a refused request or bad usage.
  ============================================================================= *)
program aicengine;

{$mode objfpc}{$H+}

uses
  SysUtils, StrUtils, Classes, BaseUnix, fpjson, jsonparser, aic_events, aic_adapter, aic_parse, aic_proc, aic_http, aic_run, aic_test, aic_service, aic_legacy, aic_post, aic_intake, aic_route, aic_loopmain, aic_fs, aic_exec, aic_history, aic_crud, aic_workers;

type
  TStdoutSink = class
    procedure Write(const Line: string);
  end;

  { keeps the first non-empty line a program prints (its version banner) }
  TFirstLine = class
    Line: string;
    procedure Take(const L: string; IsStderr: Boolean);
  end;

procedure TFirstLine.Take(const L: string; IsStderr: Boolean);
begin
  if (Line = '') and (Trim(L) <> '') then Line := Trim(L);
end;

var
  GRunner: TRunner;                    // the run in progress, so a signal can cancel it
  GCancelRequested: Boolean;

procedure OnLegacySignal(Sig: cint); cdecl;
begin
  aic_legacy.LegacyCancel := True;
end;

{ SIGINT / SIGTERM: do not die mid-run — ask the run to stop, so the child tree is killed and a clean
  `cancelled` + `done` are emitted.  Only a flag is set here (a handler must do almost nothing). }
procedure OnSignal(Sig: cint); cdecl;
begin
  GCancelRequested := True;
  if GRunner <> nil then GRunner.Cancel;
end;

procedure TStdoutSink.Write(const Line: string);
begin
  WriteLn(Line);
  Flush(Output);
end;

function OptVal(const Name: string; const Def: string = ''): string;
var
  i: Integer;
begin
  Result := Def;
  for i := 2 to ParamCount - 1 do
    if ParamStr(i) = Name then Exit(ParamStr(i + 1));
end;

function HasFlag(const Name: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 2 to ParamCount do
    if ParamStr(i) = Name then Exit(True);
end;

function ReadFileText(const F: string): string;
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.LoadFromFile(F);
    Result := sl.Text;
    if (Length(Result) > 0) and (Result[Length(Result)] = #10) then SetLength(Result, Length(Result) - 1);
  finally
    sl.Free;
  end;
end;

function DefaultAdaptersDir: string;
begin
  Result := OptVal('--adapters', '');
  if Result = '' then Result := GetEnvironmentVariable('AICENGINE_ADAPTERS');
  if Result = '' then Result := ExpandFileName(ExtractFilePath(ParamStr(0)) + '../adapters');
end;

function CmdDetect(Ads: TAdapterList): Integer;
var
  i, j, st: Integer;
  Ad: TAdapter;
  path, body: string;
  args: TStringList;
  vv: TJSONData;
  fl: TFirstLine;
begin
  WriteLn(Format('%-16s %-10s %-6s %s', ['adapter', 'kind', 'ready', 'detail']));
  for i := 0 to Ads.Count - 1 do
  begin
    Ad := Ads[i];
    if Ad.Transport = 'http' then
    begin
      st := HttpGetStatus(Ad.Doc.Get('detect_url', Ad.Url), 1500, body);
      WriteLn(Format('%-16s %-10s %-6s %s', [Ad.Id, Ad.Kind, BoolToStr(st = 200, 'yes', 'no'), 'HTTP ' + IntToStr(st)]));
    end
    else
    begin
      path := FindInPath(Ad.Command, GetEnvironmentVariable('PATH'));
      fl := TFirstLine.Create;
      args := TStringList.Create;
      try
        if path <> '' then
        begin
          vv := Ad.Doc.FindPath('detect.version_args');
          if (vv <> nil) and (vv.JSONType = jtArray) then
            for j := 0 to TJSONArray(vv).Count - 1 do args.Add(TJSONArray(vv)[j].AsString);
          RunProcess(Ad.Command, args, '', nil, '', 3, 64, @fl.Take, nil);   // 3 s limit: a probe must never hang detect
        end;
        WriteLn(Format('%-16s %-10s %-6s %s', [Ad.Id, Ad.Kind, BoolToStr(path <> '', 'yes', 'no'),
          Copy(fl.Line, 1, 60) + IfThen(fl.Line <> '', '  ', '') + path]));
      finally
        args.Free; fl.Free;
      end;
    end;
  end;
  Result := 0;
end;

const
  ENGINE_VERSION = '1.4.0';

var
  Ads: TAdapterList;
  Sink: TStdoutSink;
  Em: TEventEmitter;
  Rn: TRunner;
  Req: TRunRequest;
  Ad: TAdapter;
  cmd, id, pf: string;
  rc: Integer;
  SvcO: TServiceOptions;
  LO: TLegacyOptions;
  LCo: TLocalChatOptions;
  GMo: TGeminiOptions;
  PRo: TPromptOptions;
  CLo: TCleanOptions;
  INo: TIntakeOptions;
  inSh: string;
  RTo: TRouteOptions;
  fsReq: TJSONData;
  fsResp: TJSONObject;
  hsArgs: array of string;
  hsI: Integer;
  hsIn, hsLine, hsOut, hsErr: string;
  hsN: PtrInt;
  hsBuf: array[0..65535] of Byte;
  clDur, clMsg: string;
  legacyMsg: string;

begin
  Randomize;
  // FPC 3.2 converts strings through the SYSTEM code page when it parses and writes JSON, which turns every
  // non-ASCII character into "?" under a C locale (a service started by systemd, say). Everything the engine
  // handles is UTF-8, so say so before any string is touched.
  DefaultSystemCodePage := CP_UTF8;
  DefaultRTLFileSystemCodePage := CP_UTF8;
  DefaultUnicodeCodePage := CP_UTF8;
  SetMultiByteConversionCodePage(CP_UTF8);
  SetMultiByteRTLFileSystemCodePage(CP_UTF8);
  // Writing to a pipe or socket whose other end has gone raises SIGPIPE, which by default KILLS the process.
  // A child that exits without reading its whole stdin, or a model server that drops the connection, is
  // normal here: the write must fail with an error code instead of taking the engine down.
  fpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  if ParamCount < 1 then
  begin
    WriteLn('usage: aicengine detect | run ADAPTER --prompt TEXT | test ADAPTER|all [--replay|--live] | record ADAPTER ...');
    Halt(2);
  end;
  cmd := ParamStr(1);
  if (cmd = 'version') or (cmd = '--version') then begin WriteLn('aicengine ', ENGINE_VERSION, ' (legacy mode for agent_loop.sh, localchat, gemini, prompt, clean, signin-hint, intake, route, loop, fs, exec, history, crud, relay, run, serve, detect, test)'); Halt(0); end;
  Ads := TAdapterList.Create;
  try
    Ads.LoadDir(DefaultAdaptersDir);
    if cmd = 'detect' then Halt(CmdDetect(Ads));

    if cmd = 'test' then
    begin
      id := ParamStr(2); if id = '' then id := 'all';
      if HasFlag('--live') then
        rc := RunAdapterTests(Ads, id, 'live', OptVal('--fixtures', ExpandFileName(ExtractFilePath(ParamStr(0)) + '../tests')), HasFlag('-v'))
      else
        rc := RunAdapterTests(Ads, id, 'replay', OptVal('--fixtures', ExpandFileName(ExtractFilePath(ParamStr(0)) + '../tests')), HasFlag('-v'));
      Halt(rc);
    end;

    if cmd = 'legacy' then
    begin
      FillChar(LO, SizeOf(LO), 0);
      LO.CatalogFile := OptVal('--catalog'); LO.Supplier := OptVal('--supplier'); LO.ClaudeModel := OptVal('--claude-model');
      LO.RawModel := OptVal('--model'); LO.PromptFile := OptVal('--prompt-file'); LO.OutFile := OptVal('--out');
      LO.Images := OptVal('--images'); LO.ExtraCliArgs := OptVal('--extra-args'); LO.LocalBase := OptVal('--local-base');
      LO.Cwd := OptVal('--cwd'); LO.TimeoutS := StrToIntDef(OptVal('--timeout'), 0);
      if (LO.PromptFile = '') or (LO.OutFile = '') then begin WriteLn(StdErr, 'legacy needs --prompt-file and --out'); Halt(2); end;
      fpSignal(SIGINT, @OnLegacySignal);
      fpSignal(SIGTERM, @OnLegacySignal);
      rc := RunLegacy(LO, legacyMsg);
      if legacyMsg <> '' then WriteLn(StdErr, 'aicengine legacy: ', legacyMsg);
      Halt(rc);
    end;

    if cmd = 'localchat' then
    begin
      FillChar(LCo, SizeOf(LCo), 0);
      LCo.Base := OptVal('--base', 'http://127.0.0.1:11434'); LCo.Style := OptVal('--style', 'ollama'); LCo.Model := OptVal('--model');
      LCo.SystemFile := OptVal('--system-file'); LCo.HistoryFile := OptVal('--history-file'); LCo.UserFile := OptVal('--user-file');
      LCo.OutFile := OptVal('--out'); LCo.AgentUc := OptVal('--agent-uc', 'AGENT'); LCo.TimeoutS := StrToIntDef(OptVal('--timeout'), 300);
      while (Length(LCo.Base) > 0) and (LCo.Base[Length(LCo.Base)] = '/') do SetLength(LCo.Base, Length(LCo.Base) - 1);
      if (LCo.SystemFile = '') or (LCo.UserFile = '') or (LCo.OutFile = '') or (LCo.Model = '') then begin WriteLn(StdErr, 'localchat needs --model --system-file --user-file --out'); Halt(2); end;
      fpSignal(SIGINT, @OnLegacySignal);
      fpSignal(SIGTERM, @OnLegacySignal);
      rc := RunLocalChat(LCo, legacyMsg);
      if legacyMsg <> '' then WriteLn(StdErr, 'aicengine localchat: ', legacyMsg);
      Halt(rc);
    end;

    if cmd = 'gemini' then
    begin
      // aicengine gemini --model M --prompt-file F --out FILE [--base URL] [--ca-file F] [--resolve IP] [--timeout S]   (key: GEMINI_API_KEY)
      FillChar(GMo, SizeOf(GMo), 0);
      GMo.Base := OptVal('--base', 'https://generativelanguage.googleapis.com'); GMo.Model := OptVal('--model');
      GMo.PromptFile := OptVal('--prompt-file'); GMo.OutFile := OptVal('--out'); GMo.CaFile := OptVal('--ca-file');
      GMo.ResolveIp := OptVal('--resolve'); GMo.TimeoutS := StrToIntDef(OptVal('--timeout'), 180);
      while (Length(GMo.Base) > 0) and (GMo.Base[Length(GMo.Base)] = '/') do SetLength(GMo.Base, Length(GMo.Base) - 1);
      if (GMo.Model = '') or (GMo.PromptFile = '') or (GMo.OutFile = '') then begin WriteLn(StdErr, 'gemini needs --model --prompt-file --out'); Halt(2); end;
      fpSignal(SIGINT, @OnLegacySignal);
      fpSignal(SIGTERM, @OnLegacySignal);
      rc := RunGemini(GMo, legacyMsg);
      if legacyMsg <> '' then WriteLn(StdErr, 'aicengine gemini: ', legacyMsg);
      Halt(rc);
    end;

    if cmd = 'prompt' then
    begin
      // aicengine prompt --agent A --project P --project-dir D --chat-name C --data-dir D --user-file F --out F [--sys-out F] ...  (see usage)
      FillChar(PRo, SizeOf(PRo), 0);
      PRo.Agent := OptVal('--agent'); PRo.Project := OptVal('--project'); PRo.ProjectDir := OptVal('--project-dir'); PRo.ChatName := OptVal('--chat-name', 'default');
      PRo.DataDir := OptVal('--data-dir'); PRo.CliSupplier := OptVal('--cli-supplier'); PRo.ClaudeModel := OptVal('--claude-model'); PRo.GeminiModel := OptVal('--gemini-model');
      PRo.Model := OptVal('--model'); PRo.PromptStyle := OptVal('--prompt-style', 'plain');
      PRo.UserFile := OptVal('--user-file'); PRo.HistoryFile := OptVal('--history-file'); PRo.RagFile := OptVal('--rag-file'); PRo.WorkersFile := OptVal('--workers-file');
      PRo.ToolsFile := OptVal('--tools-file'); PRo.CapsFile := OptVal('--caps-file'); PRo.CrudFile := OptVal('--crud-file'); PRo.StyleFile := OptVal('--style-file');
      PRo.OutFile := OptVal('--out'); PRo.SysOutFile := OptVal('--sys-out');
      if (PRo.Agent = '') or (PRo.ProjectDir = '') or (PRo.DataDir = '') or (PRo.UserFile = '') or (PRo.OutFile = '') then begin WriteLn(StdErr, 'prompt needs --agent --project-dir --data-dir --user-file --out'); Halt(2); end;
      rc := RunPrompt(PRo, legacyMsg);
      if legacyMsg <> '' then WriteLn(StdErr, 'aicengine prompt: ', legacyMsg);
      Halt(rc);
    end;

    if cmd = 'clean' then
    begin
      // aicengine clean --agent A --out-file F --start-ns N [--usage-log F --model M --project P --chat C --prompt-chars N] [--end-ns N --ts T]; prints the duration
      FillChar(CLo, SizeOf(CLo), 0);
      CLo.Agent := OptVal('--agent'); CLo.OutFile := OptVal('--out-file'); CLo.UsageLog := OptVal('--usage-log'); CLo.Model := OptVal('--model');
      CLo.Project := OptVal('--project'); CLo.Chat := OptVal('--chat'); CLo.StartNs := StrToInt64Def(OptVal('--start-ns'), 0); CLo.EndNs := StrToInt64Def(OptVal('--end-ns'), 0);
      CLo.PromptChars := StrToInt64Def(OptVal('--prompt-chars'), 0); CLo.Ts := OptVal('--ts');
      rc := RunClean(CLo, clDur, clMsg);
      if clMsg <> '' then WriteLn(StdErr, 'aicengine clean: ', clMsg);
      if rc = 0 then WriteLn(clDur);
      Halt(rc);
    end;
    if cmd = 'intake' then
    begin
      // aicengine intake --agent A --queue-dir D --response-dir D --prompt-file F --root D --prompt-out F ; prints shell assignments (exit 2 = refused, nothing touched)
      FillChar(INo, SizeOf(INo), 0);
      INo.Agent := OptVal('--agent'); INo.QueueDir := OptVal('--queue-dir'); INo.ResponseDir := OptVal('--response-dir');
      INo.PromptFile := OptVal('--prompt-file'); INo.Root := OptVal('--root'); INo.PromptOut := OptVal('--prompt-out');
      rc := RunIntake(INo, inSh, clMsg);
      if clMsg <> '' then WriteLn(StdErr, 'aicengine intake: ', clMsg);
      if rc = 0 then Write(inSh);
      Halt(rc);
    end;

    if cmd = 'route' then
    begin
      // aicengine route --agent A --project P --project-dir D --data-dir D --base-url U --home D ; prints shell assignments (exit 2 = refused, nothing written)
      FillChar(RTo, SizeOf(RTo), 0);
      RTo.Agent := OptVal('--agent'); RTo.Project := OptVal('--project', 'default'); RTo.ProjectDir := OptVal('--project-dir'); RTo.DataDir := OptVal('--data-dir');
      RTo.BaseUrl := OptVal('--base-url', 'http://localhost/cockpit'); RTo.Home := OptVal('--home', GetEnvironmentVariable('HOME'));
      rc := RunRoute(RTo, inSh, clMsg);
      if clMsg <> '' then WriteLn(StdErr, 'aicengine route: ', clMsg);
      if rc = 0 then Write(inSh);
      Halt(rc);
    end;

    if cmd = 'loop' then
    begin
      // aicengine loop <claude|gemini|ollama>   (environment: COCKPIT_QUEUE_DIR, COCKPIT_RESPONSE_DIR, COCKPIT_DATA_DIR, HOME)
      Halt(RunLoop(ParamStr(2)));
    end;

    if cmd = 'fs' then
    begin
      // aicengine fs --request-file F  -> the response JSON on standard output (the file manager's operations; tests and scripts use it directly)
      pf := OptVal('--request-file');
      if pf = '' then begin WriteLn(StdErr, 'fs needs --request-file'); Halt(2); end;
      fsReq := GetJSON(ReadFileText(pf));
      fsResp := FsHandle(TJSONObject(fsReq));
      WriteLn(fsResp.FormatJSON([foSingleLineArray, foSingleLineObject, foSkipWhiteSpace], 0));
      Halt(0);
    end;

    if cmd = 'exec' then
    begin
      // aicengine exec --request-file F  -> the response JSON (a simple command, confined by the kernel; see aic_exec)
      pf := OptVal('--request-file');
      if pf = '' then begin WriteLn(StdErr, 'exec needs --request-file'); Halt(2); end;
      fsReq := GetJSON(ReadFileText(pf));
      fsResp := ExecHandle(TJSONObject(fsReq));
      WriteLn(fsResp.FormatJSON([foSingleLineArray, foSingleLineObject, foSkipWhiteSpace], 0));
      Halt(0);
    end;

    if cmd = 'history' then
    begin
      // aicengine history needs|build|sync|add|append ...   (the same interface as scripts/history_cli.php; exit 9 = refused: use the PHP helper)
      hsArgs := nil; SetLength(hsArgs, 0);
      for hsI := 3 to ParamCount do begin SetLength(hsArgs, Length(hsArgs) + 1); hsArgs[High(hsArgs)] := ParamStr(hsI); end;
      hsIn := '';
      if (ParamStr(2) = 'needs') or (ParamStr(2) = 'build') then
      begin
        repeat
          hsN := fpRead(0, hsBuf, SizeOf(hsBuf));
          if hsN > 0 then begin hsLine := ''; SetLength(hsLine, hsN); Move(hsBuf[0], hsLine[1], hsN); hsIn := hsIn + hsLine; end;
        until hsN <= 0;
      end;
      rc := HistoryRun(ParamStr(2), hsArgs, hsIn, hsOut, hsErr);
      if hsOut <> '' then Write(hsOut);
      if hsErr <> '' then Write(StdErr, hsErr);
      Halt(rc);
    end;

    if cmd = 'relay' then
    begin
      // aicengine relay PROVIDER MODEL PROMPT_FILE   (data dir from COCKPIT_DATA_OVERRIDE; the same text as worker_relay.php prints; exit 9 = refused: use the PHP)
      rc := WorkersRelay(ParamStr(2), ParamStr(3), ParamStr(4), GetEnvironmentVariable('COCKPIT_DATA_OVERRIDE'), GetEnvironmentVariable('COCKPIT_WORKER_BASE'), hsOut);
      if rc = 0 then Write(hsOut);
      Halt(rc);
    end;

    if cmd = 'crud' then
    begin
      // aicengine crud PROJECT_DIR RESPONSE_FILE [PROPOSER] [PROJECT_NAME]   (the same results as scripts/crud_cli.php; exit 9 = refused: use the PHP helper)
      rc := CrudRun(ParamStr(2), ParamStr(3), ParamStr(4), ParamStr(5), hsOut, hsErr, hsLine);
      if hsOut <> '' then Write(hsOut);
      if hsErr <> '' then Write(StdErr, hsErr);
      Halt(rc);
    end;

    if cmd = 'signin-hint' then
    begin
      // aicengine signin-hint --agent A --agent-uc UC --out-file F
      if (OptVal('--agent') = '') or (OptVal('--out-file') = '') then begin WriteLn(StdErr, 'signin-hint needs --agent --agent-uc --out-file'); Halt(2); end;
      Halt(RunSigninHint(OptVal('--agent'), OptVal('--agent-uc', UpperCase(OptVal('--agent'))), OptVal('--out-file'), clMsg));
    end;

    if cmd = 'serve' then
    begin
      // aicengine serve --socket PATH [--state DIR] [--token-file F] [--adapters DIR] [--socket-mode 660]
      //                  [--socket-group NAME] [--allowed-roots A:B] [--max-runs N] [--max-request-mb N]
      SvcO.SocketPath := OptVal('--socket');
      if SvcO.SocketPath = '' then begin WriteLn(StdErr, 'serve needs --socket PATH'); Halt(2); end;
      SvcO.StateDir := OptVal('--state', ExpandFileName(ExtractFilePath(ParamStr(0)) + '../state'));
      SvcO.TokenFile := OptVal('--token-file');
      SvcO.AdaptersDir := DefaultAdaptersDir;
      SvcO.SocketMode := StrToIntDef('&' + OptVal('--socket-mode', '600'), &600);
      SvcO.SocketGroup := OptVal('--socket-group');
      SvcO.AllowedRoots := TStringList.Create;
      SvcO.AllowedRoots.Delimiter := ':';
      SvcO.AllowedRoots.StrictDelimiter := True;
      SvcO.AllowedRoots.DelimitedText := OptVal('--allowed-roots');
      SvcO.MaxRuns := StrToIntDef(OptVal('--max-runs'), 16);
      SvcO.MaxRequestBytes := StrToIntDef(OptVal('--max-request-mb'), 32) * 1048576;
      SvcO.ReadTimeoutMs := StrToIntDef(OptVal('--read-timeout-ms'), 5000);
      Halt(ServeForever(SvcO));
    end;
    if (cmd = 'run') or (cmd = 'record') then
    begin
      id := ParamStr(2);
      Ad := Ads.Find(id);
      if Ad = nil then begin WriteLn(StdErr, 'no such adapter: ', id); Halt(2); end;
      FillChar(Req, SizeOf(Req), 0);
      Req.Prompt := OptVal('--prompt');
      pf := OptVal('--prompt-file');
      if pf <> '' then Req.Prompt := ReadFileText(pf);
      Req.System := OptVal('--system');
      if OptVal('--messages-file') <> '' then Req.Messages := ReadFileText(OptVal('--messages-file'));
      Req.Model := OptVal('--model');
      Req.SessionId := OptVal('--session');
      Req.Cwd := OptVal('--cwd');
      Req.Tier := OptVal('--tier');
      Req.TimeoutS := StrToIntDef(OptVal('--timeout'), 0);
      Req.MaxOutputKB := StrToIntDef(OptVal('--max-output-kb'), 0);
      Sink := TStdoutSink.Create;
      Em := TEventEmitter.Create(NewRunId, @Sink.Write);
      Rn := TRunner.Create(Em);
      Rn.ExtraEnv := TStringList.Create;
      for rc := 2 to ParamCount - 1 do
        if ParamStr(rc) = '--env' then Rn.ExtraEnv.Add(ParamStr(rc + 1));
      GRunner := Rn;
      fpSignal(SIGINT, @OnSignal);
      fpSignal(SIGTERM, @OnSignal);
      try
        if cmd = 'record' then Rn.RecordFile := OptVal('--record', id + '.jsonl')
        else Rn.RecordFile := OptVal('--record');
        if OptVal('--replay') <> '' then rc := Rn.Replay(Ad, Req, OptVal('--replay'))
        else rc := Rn.Run(Ad, Req);
      finally
        GRunner := nil;
        Rn.ExtraEnv.Free;
        Rn.Free; Em.Free; Sink.Free;
      end;
      Halt(rc);
    end;

    WriteLn(StdErr, 'unknown command: ', cmd);
    Halt(2);
  finally
    Ads.Free;
  end;
end.
