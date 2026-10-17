(* =============================================================================
  sup_sched — schedules: when is a job due?   (pure functions: no clock, no files, fully unit-tested)

  Replaces the cron line (`*/1 * * * * php scheduler.php`) and the systemd timers (OnCalendar=Sun 04:00,
  OnCalendar=*-*-01 09:00, Persistent=true, RandomizedDelaySec).

  Spec strings (case-insensitive, local time):
      every 60s | every 5m | every 2h        a fixed interval after the previous run STARTED
      daily 04:00
      weekly sun 04:00                       mon tue wed thu fri sat sun
      monthly 1 09:00                        day of month 1..31 (a short month uses its last day)

  FirstSlotAfter(T)  = the earliest scheduled moment strictly after T
  LastSlotAtOrBefore(T) = the latest scheduled moment at or before T   (used to decide "was one missed?")
  ============================================================================= *)
unit sup_sched;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DateUtils;

type
  TSchedKind = (skEvery, skDaily, skWeekly, skMonthly);

  TSchedule = record
    Kind: TSchedKind;
    EverySecs: Integer;
    Hour, Minute: Integer;
    Dow: Integer;              // 1 = Monday .. 7 = Sunday (DayOfTheWeek)
    Dom: Integer;              // 1..31
  end;

function ParseSchedule(const Spec: string; out S: TSchedule; out Err: string): Boolean;
function FirstSlotAfter(const S: TSchedule; T: TDateTime): TDateTime;       // calendar kinds only
function LastSlotAtOrBefore(const S: TSchedule; T: TDateTime): TDateTime;   // calendar kinds only
function ScheduleToText(const S: TSchedule): string;

implementation

function DowFromName(const N: string): Integer;
const
  Names: array[1..7] of string = ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun');
var
  i: Integer;
begin
  Result := 0;
  for i := 1 to 7 do
    if Copy(LowerCase(N), 1, 3) = Names[i] then Exit(i);
end;

function ParseHHMM(const T: string; out H, M: Integer): Boolean;
var
  p: Integer;
begin
  Result := False;
  p := Pos(':', T);
  if p < 2 then Exit;
  H := StrToIntDef(Copy(T, 1, p - 1), -1);
  M := StrToIntDef(Copy(T, p + 1, 5), -1);
  Result := (H >= 0) and (H <= 23) and (M >= 0) and (M <= 59);
end;

function ParseSchedule(const Spec: string; out S: TSchedule; out Err: string): Boolean;
var
  parts: array of string;
  t, cur: string;
  i, n, mult: Integer;
begin
  Result := False;
  Err := '';
  FillChar(S, SizeOf(S), 0);
  t := LowerCase(Trim(Spec));
  SetLength(parts, 0);
  cur := '';
  for i := 1 to Length(t) + 1 do
    if (i > Length(t)) or (t[i] in [' ', #9]) then
    begin
      if cur <> '' then begin SetLength(parts, Length(parts) + 1); parts[High(parts)] := cur; cur := ''; end;
    end
    else cur := cur + t[i];
  if Length(parts) = 0 then begin Err := 'empty schedule'; Exit; end;

  if parts[0] = 'every' then
  begin
    if Length(parts) <> 2 then begin Err := '"every" needs one interval, like every 60s'; Exit; end;
    cur := parts[1];
    mult := 1;
    case cur[Length(cur)] of
      's': mult := 1;
      'm': mult := 60;
      'h': mult := 3600;
    else
      Err := 'interval must end in s, m or h: ' + cur; Exit;
    end;
    n := StrToIntDef(Copy(cur, 1, Length(cur) - 1), -1);
    if n < 1 then begin Err := 'bad interval: ' + cur; Exit; end;
    S.Kind := skEvery; S.EverySecs := n * mult;
    Exit(True);
  end
  else if parts[0] = 'daily' then
  begin
    if (Length(parts) <> 2) or not ParseHHMM(parts[1], S.Hour, S.Minute) then begin Err := 'daily needs HH:MM'; Exit; end;
    S.Kind := skDaily;
    Exit(True);
  end
  else if parts[0] = 'weekly' then
  begin
    if (Length(parts) <> 3) or (DowFromName(parts[1]) = 0) or not ParseHHMM(parts[2], S.Hour, S.Minute) then
    begin Err := 'weekly needs a weekday and HH:MM, like weekly sun 04:00'; Exit; end;
    S.Kind := skWeekly; S.Dow := DowFromName(parts[1]);
    Exit(True);
  end
  else if parts[0] = 'monthly' then
  begin
    if Length(parts) <> 3 then begin Err := 'monthly needs a day and HH:MM, like monthly 1 09:00'; Exit; end;
    S.Dom := StrToIntDef(parts[1], 0);
    if (S.Dom < 1) or (S.Dom > 31) or not ParseHHMM(parts[2], S.Hour, S.Minute) then begin Err := 'bad monthly schedule'; Exit; end;
    S.Kind := skMonthly;
    Exit(True);
  end;
  Err := 'unknown schedule kind: ' + parts[0];
end;

{ The slot on a given calendar day for this schedule, or 0 when the day carries no slot. }
function SlotOnDay(const S: TSchedule; Day: TDateTime): TDateTime;
var
  d: Integer;
  y, m, dd: Word;
begin
  Result := 0;
  case S.Kind of
    skDaily: ;
    skWeekly: if DayOfTheWeek(Day) <> S.Dow then Exit;
    skMonthly:
      begin
        DecodeDate(Day, y, m, dd);
        d := S.Dom;
        if d > DaysInMonth(Day) then d := DaysInMonth(Day);       // a short month uses its last day
        if dd <> d then Exit;
      end;
  else
    Exit;
  end;
  Result := DateOf(Day) + EncodeTime(S.Hour, S.Minute, 0, 0);
end;

function FirstSlotAfter(const S: TSchedule; T: TDateTime): TDateTime;
var
  i: Integer;
  c: TDateTime;
begin
  Result := 0;
  for i := 0 to 400 do
  begin
    c := SlotOnDay(S, DateOf(T) + i);
    if (c <> 0) and (c > T) then Exit(c);
  end;
end;

function LastSlotAtOrBefore(const S: TSchedule; T: TDateTime): TDateTime;
var
  i: Integer;
  c: TDateTime;
begin
  Result := 0;
  for i := 0 to 400 do
  begin
    c := SlotOnDay(S, DateOf(T) - i);
    if (c <> 0) and (c <= T) then Exit(c);
  end;
end;

function ScheduleToText(const S: TSchedule): string;
const
  D: array[1..7] of string = ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun');
begin
  case S.Kind of
    skEvery: Result := Format('every %ds', [S.EverySecs]);
    skDaily: Result := Format('daily %.2d:%.2d', [S.Hour, S.Minute]);
    skWeekly: Result := Format('weekly %s %.2d:%.2d', [D[S.Dow], S.Hour, S.Minute]);
    skMonthly: Result := Format('monthly %d %.2d:%.2d', [S.Dom, S.Hour, S.Minute]);
  end;
end;

end.
