using System;
using System.Collections;
using System.Globalization;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Security.Cryptography;
using System.Security.Principal;

[assembly: AssemblyTitle("NextDNS")]
[assembly: AssemblyDescription("Native Windows launcher for the NextDNS connection manager")]
[assembly: AssemblyProduct("NextDNS")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace NextDNS.Desktop
{
    // Poll the event on the WPF dispatcher; never invoke PowerShell on a CLR worker thread.
    public static class DesktopInstance
    {
        private static Mutex mutex;
        private static EventWaitHandle activation;
        public static bool Acquire(string root, bool repair, bool background)
        {
            string hash;
            using (SHA256 sha = SHA256.Create())
                hash = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(Path.GetFullPath(root).ToLowerInvariant()))).Replace("-", "").Substring(0, 24);
            string name = @"Local\NextDNS.Manager." + WindowsIdentity.GetCurrent().User.Value + "." + hash + (repair ? ".Repair" : ".Main");
            activation = new EventWaitHandle(false, EventResetMode.AutoReset, name + ".Activate");
            bool created;
            mutex = new Mutex(true, name, out created);
            if (!created) { if (!background) activation.Set(); Dispose(); }
            return created;
        }
        public static bool ConsumeActivation() { return activation != null && activation.WaitOne(0); }
        public static void Dispose()
        {
            if (activation != null) { activation.Dispose(); activation = null; }
            if (mutex != null) { mutex.Dispose(); mutex = null; }
        }
    }

    internal sealed class DesktopHost : PSHost
    {
        private readonly Guid instanceId = Guid.NewGuid();
        internal bool ExitRequested { get; private set; }
        internal int ExitCode { get; private set; }
        public override Guid InstanceId { get { return instanceId; } }
        public override string Name { get { return "NextDNS.Desktop"; } }
        public override Version Version { get { return new Version(1, 0); } }
        public override PSHostUserInterface UI { get { return null; } }
        public override CultureInfo CurrentCulture { get { return CultureInfo.CurrentCulture; } }
        public override CultureInfo CurrentUICulture { get { return CultureInfo.CurrentUICulture; } }
        public override void SetShouldExit(int exitCode) { ExitCode = exitCode; ExitRequested = true; }
        public override void EnterNestedPrompt() { throw new PSNotSupportedException("Interactive prompts are not available in this desktop application."); }
        public override void ExitNestedPrompt() { }
        public override void NotifyBeginApplication() { }
        public override void NotifyEndApplication() { }
    }

    internal static class Program
    {
        private static string serviceRoot;
        private static bool smokeTest;

        [STAThread]
        private static int Main(string[] args)
        {
            serviceRoot = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "_service");
            if (!File.Exists(Path.Combine(serviceRoot, "NextDNS-GUI.ps1")))
                serviceRoot = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
            foreach (string argument in args)
            {
                if (string.Equals(argument, "-SmokeTest", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(argument, "-RenderPreview", StringComparison.OrdinalIgnoreCase)) smokeTest = true;
            }
            try
            {
                string script = Path.Combine(serviceRoot, "NextDNS-GUI.ps1");
                if (!File.Exists(script)) throw new FileNotFoundException("Не найден файл интерфейса _service\\NextDNS-GUI.ps1.", script);
                bool repair = Array.Exists(args, a => string.Equals(a, "-Repair", StringComparison.OrdinalIgnoreCase));
                bool tray = Array.Exists(args, a => string.Equals(a, "-Tray", StringComparison.OrdinalIgnoreCase));
                if (!smokeTest && !DesktopInstance.Acquire(serviceRoot, repair, tray)) return 0;

                // Use Windows PowerShell 5.1 modules even when launched from a PowerShell 7 terminal.
                string windowsPowerShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0");
                string userModules = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), @"WindowsPowerShell\Modules");
                string sharedModules = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"WindowsPowerShell\Modules");
                Environment.SetEnvironmentVariable("PSModulePath", userModules + ";" + sharedModules + ";" + Path.Combine(windowsPowerShell, "Modules"));

                DesktopHost host = new DesktopHost();
                InitialSessionState state = InitialSessionState.CreateDefault();
                state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
                using (Runspace runspace = RunspaceFactory.CreateRunspace(host, state))
                {
                    runspace.ApartmentState = ApartmentState.STA;
                    runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                    runspace.Open();
                    runspace.SessionStateProxy.Path.SetLocation(serviceRoot);
                    Hashtable versionTable = runspace.SessionStateProxy.GetVariable("PSVersionTable") as Hashtable;
                    Version version = versionTable == null ? null : versionTable["PSVersion"] as Version;
                    if (version == null || version.Major != 5 || version.Minor != 1)
                        throw new InvalidOperationException("Для NextDNS требуется системный Windows PowerShell 5.1.");

                    AppendLog("launcher.log", "Started; runtime=" + version + "; apartment=" + Thread.CurrentThread.GetApartmentState() + "; engine=" + typeof(PSObject).Assembly.Location);
                    using (PowerShell shell = PowerShell.Create())
                    {
                        shell.Runspace = runspace;
                        // AddCommand executes the saved file and preserves PSScriptRoot/MyInvocation.
                        shell.AddCommand(script);
                        BindArguments(shell, args);
                        var output = shell.Invoke();
                        foreach (PSObject item in output) if (item != null) AppendLog("launcher.log", item.ToString());
                        if (shell.HadErrors)
                        {
                            StringBuilder errors = new StringBuilder();
                            foreach (ErrorRecord error in shell.Streams.Error) errors.AppendLine(error.ToString());
                            // Recoverable probes (e.g. a process is absent) can populate
                            // Error even with SilentlyContinue. Unhandled terminating
                            // exceptions are thrown by Invoke; explicit exit is below.
                            if (errors.Length > 0) AppendLog("launcher.log", "Recovered diagnostics: " + errors.ToString().Trim());
                        }
                    }
                    int exitCode = host.ExitRequested ? host.ExitCode : 0;
                    AppendLog("launcher.log", "Stopped; exit=" + exitCode);
                    if (exitCode != 0) AppendLog("launcher-error.log", "The GUI returned exit=" + exitCode + "; see GUI-error.log for application details.");
                    return exitCode;
                }
            }
            catch (Exception exception)
            {
                string diagnostic = exception.ToString();
                AppendLog("launcher-error.log", diagnostic);
                if (!smokeTest)
                {
                    string message = "Не удалось открыть NextDNS.\r\n\r\n" + exception.Message;
                    if (message.Length > 2400) message = message.Substring(0, 2400);
                    message += "\r\n\r\nПодробности: _service\\launcher-error.log";
                    MessageBox.Show(message, "NextDNS", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                return 1;
            }
            finally { DesktopInstance.Dispose(); }
        }

        private static void BindArguments(PowerShell shell, string[] args)
        {
            for (int index = 0; index < args.Length; index++)
            {
                string argument = args[index];
                if (string.Equals(argument, "-SmokeTest", StringComparison.OrdinalIgnoreCase)) shell.AddParameter("SmokeTest");
                else if (string.Equals(argument, "-Tray", StringComparison.OrdinalIgnoreCase)) shell.AddParameter("Tray");
                else if (string.Equals(argument, "-RenderPreview", StringComparison.OrdinalIgnoreCase)) shell.AddParameter("RenderPreview");
                else if (string.Equals(argument, "-Repair", StringComparison.OrdinalIgnoreCase)) shell.AddParameter("Repair");
                else if (string.Equals(argument, "-PreviewPath", StringComparison.OrdinalIgnoreCase) ||
                         string.Equals(argument, "-PreviewWidth", StringComparison.OrdinalIgnoreCase) ||
                         string.Equals(argument, "-PreviewHeight", StringComparison.OrdinalIgnoreCase) ||
                         string.Equals(argument, "-HealthSnapshotPath", StringComparison.OrdinalIgnoreCase))
                {
                    if (++index >= args.Length) throw new ArgumentException("Не указано значение " + argument + ".");
                    shell.AddParameter(argument.Substring(1), args[index]);
                }
                else throw new ArgumentException("Неизвестный параметр приложения: " + argument);
            }
        }

        private static void AppendLog(string name, string text)
        {
            try
            {
                string path = Path.Combine(serviceRoot, name);
                if (File.Exists(path) && new FileInfo(path).Length > 512 * 1024)
                    File.WriteAllText(path, "", new UTF8Encoding(true));
                File.AppendAllText(path, DateTime.Now.ToString("o", CultureInfo.InvariantCulture) + "  " + text + Environment.NewLine, new UTF8Encoding(true));
            }
            catch { }
        }
    }
}
