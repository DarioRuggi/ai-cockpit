(* =============================================================================
  srv_static — serving one file: validators, conditional requests, ranges, streaming.

    * Last-Modified and a weak ETag (W/"size-mtime") on every file;
    * If-None-Match and If-Modified-Since -> 304 (a change on disk is seen at once: no caching by us);
    * Accept-Ranges: bytes; a single Range (first-last, first-, -suffix) -> 206 with Content-Range;
      an unsatisfiable range -> 416 with Content-Range: bytes */size; several ranges -> the whole file
      (allowed by the standard); If-Range makes a range conditional on the validator;
    * the file is read in 64 KB pieces and written as it goes: a 2 GB video costs 64 KB of memory;
    * Cache-Control from the configured rules (Cockpit's own: html/js/css/json = "no-cache, must-revalidate",
      so a deployed change is visible on the next reload);
    * the file's type comes from its extension only, plus X-Content-Type-Options: nosniff from the global headers.
  ============================================================================= *)
unit srv_static;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils, BaseUnix, srv_util, srv_http, srv_config;

type
  TStaticResult = (srOk, srNotFound, srAborted);

function ServeFile(R: TResponse; Req: TRequest; const FullPath, RelName: string; Cfg: TServerConfig): TStaticResult;

implementation

function CacheControlFor(const RelName: string; Cfg: TServerConfig): string;
var
  i: Integer;
  baseName: string;
begin
  Result := '';
  baseName := ExtractFileName(RelName);
  for i := 0 to High(Cfg.Cache) do
    if GlobMatch(Cfg.Cache[i].Match, baseName, True) or GlobMatch(Cfg.Cache[i].Match, RelName, True) then Exit(Cfg.Cache[i].Value);
end;

{ Does the If-None-Match list contain our validator?  Weak comparison; "*" matches anything. }
function EtagMatches(const Hdr, Etag: string): Boolean;
var
  parts: TStringList;
  i: Integer;
  t, mine: string;
begin
  Result := False;
  if Trim(Hdr) = '*' then Exit(True);
  mine := Etag;
  if Copy(mine, 1, 2) = 'W/' then Delete(mine, 1, 2);
  parts := TStringList.Create;
  try
    parts.Delimiter := ','; parts.StrictDelimiter := True; parts.DelimitedText := Hdr;
    for i := 0 to parts.Count - 1 do
    begin
      t := Trim(parts[i]);
      if Copy(t, 1, 2) = 'W/' then Delete(t, 1, 2);
      if t = mine then Exit(True);
    end;
  finally
    parts.Free;
  end;
end;

function ServeFile(R: TResponse; Req: TRequest; const FullPath, RelName: string; Cfg: TServerConfig): TStaticResult;
var
  st: Stat;
  fd: cint;
  etag, lastMod, cc, ifRange, rangeHdr: string;
  h: TStringList;
  mtimeUtc: TDateTime;
  ims: TDateTime;
  kind: TRangeKind;
  first, last, remaining, size: Int64;
  buf: array[0..65535] of Byte;
  n, want: Integer;
  status: Integer;
  useRange, notModified: Boolean;
  ifm: TDateTime;
begin
  Result := srNotFound;
  if fpStat(FullPath, st) <> 0 then Exit;
  if not fpS_ISREG(st.st_mode) then Exit;                    // directories and devices are never served as files
  fd := fpOpen(FullPath, O_RDONLY);
  if fd < 0 then Exit;
  try
    size := st.st_size;
    mtimeUtc := UnixToDateTime(st.st_mtime, True);
    etag := ETagFor(size, st.st_mtime);
    lastMod := HttpDate(mtimeUtc);
    cc := CacheControlFor(RelName, Cfg);

    h := TStringList.Create;
    try
      h.Add('Content-Type: ' + MimeFor(FullPath));
      h.Add('Last-Modified: ' + lastMod);
      h.Add('ETag: ' + etag);
      h.Add('Accept-Ranges: bytes');
      if cc <> '' then h.Add('Cache-Control: ' + cc);

      // ---- conditional ----
      notModified := False;
      if Req.H('if-none-match') <> '' then notModified := EtagMatches(Req.H('if-none-match'), etag)
      else if (Req.H('if-modified-since') <> '') and ParseHttpDate(Req.H('if-modified-since'), ims) then
        notModified := mtimeUtc <= ims + 0.5 / 86400;
      if notModified and ((Req.Method = 'GET') or (Req.Method = 'HEAD')) then
      begin
        if not R.Start(304, h, 0) then Exit(srAborted);
        R.Finish;
        Exit(srOk);
      end;

      // ---- range ----
      status := 200; first := 0; last := size - 1; useRange := False;
      rangeHdr := Req.H('range');
      if (rangeHdr <> '') and (Req.Method = 'GET') then
      begin
        ifRange := Req.H('if-range');
        if (ifRange <> '') then
        begin
          // an If-Range that is not our current validator means: ignore Range, send everything
          if Copy(ifRange, 1, 1) = '"' then begin if ifRange <> Copy(etag, 3, MaxInt) then rangeHdr := ''; end
          else if Copy(ifRange, 1, 2) = 'W/' then rangeHdr := ''                    // a weak validator is not valid for If-Range
          else if ParseHttpDate(ifRange, ifm) then begin if Abs(ifm - mtimeUtc) > 0.5 / 86400 then rangeHdr := ''; end
          else rangeHdr := '';
        end;
        if rangeHdr <> '' then
        begin
          kind := ParseRange(rangeHdr, size, first, last);
          if kind = rkUnsatisfiable then
          begin
            // only the validators that make sense for an error: the range the file really has
            h.Clear;
            h.Add('Content-Range: bytes */' + IntToStr(size));
            SimpleResponse(R, 416, 'text/plain; charset=utf-8', 'Range Not Satisfiable'#10, h);
            Exit(srOk);
          end;
          if kind = rkOk then
          begin
            useRange := True; status := 206;
            h.Add('Content-Range: bytes ' + IntToStr(first) + '-' + IntToStr(last) + '/' + IntToStr(size));
          end;
        end;
      end;

      if useRange then remaining := last - first + 1 else remaining := size;
      if not R.Start(status, h, remaining) then Exit(srAborted);
    finally
      h.Free;
    end;

    // ---- body ----
    if Req.Method = 'HEAD' then begin R.Finish; Exit(srOk); end;
    if useRange and (first > 0) then fpLSeek(fd, first, SEEK_SET);
    while remaining > 0 do
    begin
      want := SizeOf(buf);
      if Int64(want) > remaining then want := Integer(remaining);
      n := fpRead(fd, buf, want);
      if n <= 0 then Break;                                  // the file shrank while we were sending it
      if not R.Write(buf, n) then Exit(srAborted);
      Dec(remaining, n);
    end;
    R.Finish;                                               // a short body makes Finish drop the connection
    Result := srOk;
  finally
    fpClose(fd);
  end;
end;

end.
