param(
  [string]$BotDir,
  [string]$PyExe,
  [string]$LogDir
)

# --- Ensure paths
if (-not (Test-Path $BotDir))   { throw "BotDir not found: $BotDir" }
if (-not (Test-Path $PyExe))    { throw "Python not found: $PyExe" }
if (-not (Test-Path $LogDir))   { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

# --- Win32 Job Object interop (KILL_ON_JOB_CLOSE)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class JobApi {
  [StructLayout(LayoutKind.Sequential)]
  public struct IO_COUNTERS {
    public UInt64 ReadOperationCount;
    public UInt64 WriteOperationCount;
    public UInt64 OtherOperationCount;
    public UInt64 ReadTransferCount;
    public UInt64 WriteTransferCount;
    public UInt64 OtherTransferCount;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
    public Int64 PerProcessUserTimeLimit;
    public Int64 PerJobUserTimeLimit;
    public UInt32 LimitFlags;
    public UIntPtr MinimumWorkingSetSize;
    public UIntPtr MaximumWorkingSetSize;
    public UIntPtr ActiveProcessLimit;
    public Int64 Affinity;
    public UInt32 PriorityClass;
    public UInt32 SchedulingClass;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    public IO_COUNTERS IoInfo;
    public UIntPtr ProcessMemoryLimit;
    public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed;
    public UIntPtr PeakJobMemoryUsed;
  }

  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
  public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

  [DllImport("kernel32.dll")]
  public static extern bool SetInformationJobObject(
    IntPtr hJob, int JobObjectInfoClass,
    ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpJobObjectInfo, uint cbJobObjectInfoLength);

  [DllImport("kernel32.dll")]
  public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
}
"@ -ErrorAction Stop

$job = [JobApi]::CreateJobObject([IntPtr]::Zero, "TradingBotJob")
if ($job -eq [IntPtr]::Zero) { throw "CreateJobObject failed." }

# 0x2000 = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
$info = New-Object JobApi+JOBOBJECT_EXTENDED_LIMIT_INFORMATION
$info.BasicLimitInformation.LimitFlags = 0x2000
$ok = [JobApi]::SetInformationJobObject($job, 9, [ref]$info, [System.Runtime.InteropServices.Marshal]::SizeOf($info))
if (-not $ok) { throw "SetInformationJobObject failed." }

# --- Start python base.py (hidden), capture Process object
$stdout = Join-Path $LogDir "bot.out"
$stderr = Join-Path $LogDir "bot.err"

$proc = Start-Process -FilePath $PyExe `
  -ArgumentList 'base.py' `
  -WorkingDirectory $BotDir `
  -WindowStyle Hidden `
  -PassThru `
  -RedirectStandardOutput $stdout `
  -RedirectStandardError  $stderr

# --- Assign the process to the Job (children inherit)
[void][JobApi]::AssignProcessToJobObject($job, $proc.Handle)

# --- Write both PIDs
$launcherPidPath = Join-Path $BotDir "launcher.pid"
$botPidPath      = Join-Path $BotDir "bot.pid"
$PID | Out-File -Encoding ascii -FilePath $launcherPidPath
$proc.Id | Out-File -Encoding ascii -FilePath $botPidPath

# --- Keep the launcher alive until python exits
try {
  Wait-Process -Id $proc.Id
} finally {
  # When this script exits, the job handle is released -> KILL_ON_JOB_CLOSE nukes the whole tree
}
