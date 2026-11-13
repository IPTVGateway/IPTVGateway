program IPTVPlayTests;

{ DUnitX console test runner. Add core unit folders to the project search path
  (..\src\core and subfolders) so the units under test resolve. }

{$IFNDEF TESTINSIGHT}
{$APPTYPE CONSOLE}
{$ENDIF}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.TestFramework,
  Test.M3U in 'Test.M3U.pas',
  Test.Utils in 'Test.Utils.pas',
  Test.Config in 'Test.Config.pas',
  Test.Storage in 'Test.Storage.pas',
  Test.Probe in 'Test.Probe.pas',
  Test.SourceHttp in 'Test.SourceHttp.pas',
  Test.Stalker in 'Test.Stalker.pas',
  Test.OutputBuilder in 'Test.OutputBuilder.pas',
  Test.Serializers in 'Test.Serializers.pas',
  Test.SettingsIO in 'Test.SettingsIO.pas',
  Test.Integration.Live in 'Test.Integration.Live.pas';

var
  Runner: ITestRunner;
  Results: IRunResults;
  Logger: ITestLogger;
begin
  try
    Runner := TDUnitX.CreateRunner;
    Runner.UseRTTI := False; // fixtures register explicitly in each unit's initialization
    Logger := TDUnitXConsoleLogger.Create(True);
    Runner.AddLogger(Logger);
    Results := Runner.Execute;
    if not Results.AllPassed then
      System.ExitCode := 1;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      System.ExitCode := 2;
    end;
  end;
end.
