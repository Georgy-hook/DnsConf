using System;
using System.IO;
using System.Diagnostics;
using System.ServiceProcess;
using System.Threading;
using System.Text;
[assembly:System.Reflection.AssemblyTitle("NextDNS Bridge")]
[assembly:System.Reflection.AssemblyDescription("NextDNS TLS 1.3 DNS service, bound to loopback only")]
[assembly:System.Reflection.AssemblyVersion("1.0.0.0")]
namespace NextDNSBridge {
 public sealed class BridgeService:ServiceBase {
  Process child;bool stopping;readonly ManualResetEvent ready=new ManualResetEvent(false);
  readonly object logLock=new object();
  static readonly string Data=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"NextDNSBridge");
  public BridgeService(){ServiceName="NextDNSBridge";CanStop=true;CanShutdown=true;AutoLog=true;}
  void Log(string text){lock(logLock){try{Directory.CreateDirectory(Data);string path=Path.Combine(Data,"service.log");if(File.Exists(path)&&new FileInfo(path).Length>256*1024)File.WriteAllText(path,"");File.AppendAllText(path,DateTime.UtcNow.ToString("o")+" "+text+Environment.NewLine,Encoding.UTF8);}catch{}}}
  protected override void OnStart(string[] args){
   string root=AppDomain.CurrentDomain.BaseDirectory;
   var start=new ProcessStartInfo(Path.Combine(root,@"python\python.exe"),"-I -u \""+Path.Combine(root,"bridge.py")+"\" --profile-file \""+Path.Combine(root,"profile.txt")+"\" --data-dir \""+Data+"\"");
   start.UseShellExecute=false;start.CreateNoWindow=true;start.RedirectStandardInput=true;start.RedirectStandardOutput=true;start.RedirectStandardError=true;start.WorkingDirectory=root;
   child=new Process();child.StartInfo=start;child.EnableRaisingEvents=true;
   child.OutputDataReceived+=delegate(object sender,DataReceivedEventArgs e){if(e.Data=="READY")ready.Set();else if(!string.IsNullOrEmpty(e.Data))Log(e.Data);};
   child.ErrorDataReceived+=delegate(object sender,DataReceivedEventArgs e){if(!string.IsNullOrEmpty(e.Data))Log(e.Data);};
   child.Exited+=delegate{if(!stopping){Log("DNS worker exited unexpectedly; Windows recovery requested");Environment.Exit(1);}};
   child.Start();child.BeginOutputReadLine();child.BeginErrorReadLine();
   if(!ready.WaitOne(12000)){stopping=true;try{child.Kill();}catch{}throw new InvalidOperationException("DNS worker did not become ready; see service.log");}
   Log("Service started; DNS worker ready");
  }
  protected override void OnStop(){stopping=true;if(child!=null){try{child.StandardInput.WriteLine("STOP");child.StandardInput.Flush();if(!child.WaitForExit(6000))child.Kill();}catch{}child.Dispose();}Log("Service stopped");}
  protected override void OnShutdown(){OnStop();}
 }
 public static class Program {
  public static int Main(string[] args){try{ServiceBase.Run(new BridgeService());return 0;}catch(Exception e){Console.Error.WriteLine(e.ToString());return 1;}}
 }
}
