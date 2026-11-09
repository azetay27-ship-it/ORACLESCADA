// C# 2 / x86 / STA. Holds a connector and samples only NILIT's existing internal timer. No writes.
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Xml;
using Microsoft.Win32;
using System.Reflection;
using System.Globalization;
[assembly: AssemblyVersion("1.3.2.0")]
[assembly: AssemblyFileVersion("1.3.2.0")]

internal sealed class VuniqKeeper {
    private static readonly Guid ClassId = new Guid("33B13A42-BAF1-4543-96DE-DF12FE54DB2D");
    private string root, configFile, configText, enginePath, statusFile, stopFile, logFile;
    private int session, pid;
    private int maxStartsPerWindow=3, restartWindowMinutes=15;
    private long started;
    private object connector;
    private Engine engine;
    private const string ProbeAddress = "99;1;N111";
    private string value="", rawState="", readStatus="NotChecked", comReply="NotChecked";
    private string windowDetail="NotChecked";
    private long comReplyTicks, valueChangedTicks;
    private bool registered, sampled;
    private readonly System.Collections.Generic.List<long> attempts = new System.Collections.Generic.List<long>();
    private static string Canonical(string path) { return NILITGHWatchdog.Native.CanonicalPath(Path.GetFullPath(path)); }
    private static bool Same(string a, string b) { return String.Equals(a,b,StringComparison.OrdinalIgnoreCase); }

    [STAThread] private static int Main(string[] args) {
        VuniqKeeper k = new VuniqKeeper();
        Mutex mutex = null;
        bool owned = false;
        try {
            if (args.Length != 2 || args[0] != "--config") throw new ArgumentException("Expected --config and an absolute local configuration file.");
            if (IntPtr.Size != 4 || Thread.CurrentThread.GetApartmentState() != ApartmentState.STA) throw new InvalidOperationException("x86 STA required.");
            k.root = Canonical(AppDomain.CurrentDomain.BaseDirectory);
            k.configFile = Canonical(args[1]);
            string data = Path.Combine(k.root,"runtime"); Directory.CreateDirectory(data);
            k.statusFile = Path.Combine(data,"keeper.xml");
            k.stopFile = Path.Combine(k.root,"KEEPER_STOP");
            k.logFile = Path.Combine(data,"keeper.log");
            using (Process self = Process.GetCurrentProcess()) { k.session = self.SessionId; k.pid = self.Id; k.started = self.StartTime.ToUniversalTime().Ticks; }
            if (k.session == 0) throw new InvalidOperationException("Interactive operator session required.");
            k.configText = File.ReadAllText(k.configFile);
            k.ReadRecoveryPolicy();
            k.enginePath = k.ReadEnginePath();
#if !KEEPER_FIXTURE
            FileVersionInfo build = FileVersionInfo.GetVersionInfo(k.enginePath);
            if (build.FileMajorPart != 5 || build.FileMinorPart != 9 || build.FileBuildPart != 2 || build.FilePrivatePart != 9) throw new InvalidOperationException("This test package targets the observed Vuniq 5.9.2.9 only.");
#endif
            string hash;
            SHA256 sha = SHA256.Create();
            try { hash = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(k.enginePath.ToLowerInvariant()+":"+k.session))).Replace("-",""); }
            finally { sha.Clear(); }
            mutex = new Mutex(false,"Global\\NILITGHVuniqKeeper131-"+hash);
            try { owned = mutex.WaitOne(0,false); } catch (AbandonedMutexException) { owned = true; }
            if (!owned) return 0;
            k.LoadAttempts();
            k.Log("Keeper started; x86 CLR="+Environment.Version+"; engine="+k.enginePath+"; session="+k.session+"; connector quota="+(k.maxStartsPerWindow==0 ? "unlimited" : k.maxStartsPerWindow.ToString())+"; window minutes="+k.restartWindowMinutes);
            k.Run();
            return 0;
        } catch (Exception e) {
            k.Log("FATAL: "+e.Message);
            if (k.statusFile != null && owned) { k.Status("Error",e.Message); }
            return 1;
        } finally {
            // StopKeeper/config changes release only this client's reference, no server quit/cleanup calls.
            if (owned) { k.Release(); if (k.statusFile != null) k.Status("Stopped","Keeper exited; its own reference was released."); }
            if (mutex != null) { if (owned) mutex.ReleaseMutex(); mutex.Close(); }
        }
    }

    private void ReadRecoveryPolicy() {
        XmlDocument doc=LoadXml(configFile);
        if (doc.DocumentElement==null || doc.DocumentElement.Name!="Watchdog") throw new InvalidOperationException("Expected Watchdog configuration.");
        System.Collections.Generic.Dictionary<string,bool> seen=new System.Collections.Generic.Dictionary<string,bool>(StringComparer.OrdinalIgnoreCase);
        foreach (XmlNode n in doc.DocumentElement.ChildNodes) {
            if (n.NodeType!=XmlNodeType.Element) continue;
            if (seen.ContainsKey(n.Name)) throw new InvalidOperationException("Repeated setting: "+n.Name);
            seen.Add(n.Name,true);
        }
        maxStartsPerWindow=ReadIntSetting(doc,"MaxStartsPerWindow",3,0,100);
        restartWindowMinutes=ReadIntSetting(doc,"RestartWindowMinutes",15,1,1440);
    }
    private static int ReadIntSetting(XmlDocument doc,string name,int fallback,int minimum,int maximum) {
        XmlNode node=null;
        foreach (XmlNode candidate in doc.DocumentElement.ChildNodes) {
            if (candidate.NodeType==XmlNodeType.Element && String.Equals(candidate.Name,name,StringComparison.OrdinalIgnoreCase)) { node=candidate; break; }
        }
        if (node==null) return fallback;
        int value;
        if (!Int32.TryParse(node.InnerText,NumberStyles.Integer,CultureInfo.InvariantCulture,out value) || value<minimum || value>maximum)
            throw new InvalidOperationException("Invalid "+name+".");
        return value;
    }
    private string ReadEnginePath() {
        XmlDocument doc = LoadXml(configFile);
        XmlNode node = doc.SelectSingleNode("/Watchdog/VuniqPath");
        if (node == null) throw new InvalidOperationException("VuniqPath missing.");
        string path = node.InnerText;
        if (path.Length < 3 || path[1] != ':' || path[2] != '\\' || path.Substring(2).Contains(":")) throw new InvalidOperationException("Absolute local VuniqPath required.");
        path = Canonical(path);
        if (!Same(Path.GetFileName(path),"Vuniq.exe") || !File.Exists(path)) throw new InvalidOperationException("Expected existing Vuniq.exe.");
        if (new DriveInfo(Path.GetPathRoot(path)).DriveType == DriveType.Network) throw new InvalidOperationException("Network paths unsupported.");
        return path;
    }
    private static XmlDocument LoadXml(string path) {
        XmlReaderSettings s = new XmlReaderSettings(); s.ProhibitDtd = true; s.XmlResolver = null;
        XmlDocument doc = new XmlDocument(); doc.XmlResolver = null;
        using (XmlReader reader = XmlReader.Create(path,s)) { doc.Load(reader); }
        return doc;
    }

    private sealed class Engine {
        internal int Pid; internal long Started;
        internal string Identity { get { return Pid+":"+Started; } }
    }
    private Engine Inspect() {
        Engine found = null;
        Process[] procs = Process.GetProcessesByName("Vuniq");
        try {
            foreach (Process p in procs) {
                if (p.HasExited) continue;
                if (!Same(Canonical(p.MainModule.FileName),enginePath) || p.SessionId != session || found != null)
                    throw new InvalidOperationException("Another/ambiguous Vuniq instance exists; COM activation blocked.");
                found = new Engine(); found.Pid = p.Id; found.Started = p.StartTime.ToUniversalTime().Ticks;
            }
        } finally { foreach (Process p in procs) p.Dispose(); }
        return found;
    }
    private void VerifyRegistration() {
#if KEEPER_FIXTURE
        return; // Test-only build; shipped binary is compiled WITHOUT this symbol.
#else
        using (RegistryKey prog = Registry.ClassesRoot.OpenSubKey("Vuniq.VuniqConnector\\CLSID")) {
            if (prog == null || new Guid(Convert.ToString(prog.GetValue(""))) != ClassId) throw new InvalidOperationException("32-bit VuniqConnector registration differs.");
            RejectRedirection(prog);
        }
        using (RegistryKey cls = Registry.ClassesRoot.OpenSubKey("CLSID\\{"+ClassId+"}")) {
            if (cls == null) throw new InvalidOperationException("Connector class registration missing.");
            using (RegistryKey inproc = cls.OpenSubKey("InprocServer32")) {
                if (inproc != null) throw new InvalidOperationException("Unexpected in-process COM server.");
            }
            using (RegistryKey server = cls.OpenSubKey("LocalServer32")) {
                if (server == null) throw new InvalidOperationException("LocalServer32 missing.");
                string raw = Convert.ToString(server.GetValue("",null,RegistryValueOptions.DoNotExpandEnvironmentNames));
                string path = raw.Trim();
                if (path.StartsWith("\"")) {
                    int close = path.IndexOf('"',1);
                    if (close < 0 || path.Substring(close+1).Trim().Length != 0) throw new InvalidOperationException("COM server arguments unsupported.");
                    path = path.Substring(1,close-1);
                } else if (path.IndexOf(' ') >= 0) throw new InvalidOperationException("Ambiguous unquoted COM path.");
                if (!Same(Canonical(path),enginePath)) throw new InvalidOperationException("COM server path differs from configured Vuniq.");
                string executable = Convert.ToString(server.GetValue("ServerExecutable","",RegistryValueOptions.DoNotExpandEnvironmentNames));
                if (executable.Length != 0 && !Same(Canonical(executable.Trim('"')),enginePath)) throw new InvalidOperationException("COM ServerExecutable differs.");
            }
            RejectRedirection(cls);
        }
#endif
    }
    private static void RejectRedirection(RegistryKey key) {
        foreach (string name in new string[] {"TreatAs","AutoTreatAs","AppID","LocalService"}) {
            using (RegistryKey child=key.OpenSubKey(name)) {
                if (child != null || key.GetValue(name,null) != null) throw new InvalidOperationException("COM redirection unsupported: "+name);
            }
        }
    }
    private object Activate() {
#if KEEPER_FIXTURE
        Engine current = Inspect();
        if (current == null) { using (Process p = Process.Start(enginePath,"--many-windows")) { } Thread.Sleep(400); }
        return new object(); // No real COM in automated tests.
#else
        return Activator.CreateInstance(Type.GetTypeFromCLSID(ClassId,true));
#endif
    }
    private void Release() {
        object own = connector; connector = null; engine = null;
        registered=false; sampled=false; value=""; rawState=""; readStatus="NotChecked"; comReply="NotChecked"; comReplyTicks=0; valueChangedTicks=0;
        if (own != null && Marshal.IsComObject(own)) Marshal.FinalReleaseComObject(own);
    }
    private object Call(string method, object[] args, ParameterModifier[] modifiers) {
        return connector.GetType().InvokeMember(method,BindingFlags.InvokeMethod,null,connector,args,modifiers,CultureInfo.InvariantCulture,null);
    }
    private static string TextValue(object text) {
        string s=Convert.ToString(text,CultureInfo.InvariantCulture);
        if (s.Length>4096) throw new InvalidOperationException("Oversized COM text.");
        return s.Trim().TrimEnd('\0');
    }
    private void Probe() {
#if KEEPER_FIXTURE
        string fixture=Path.Combine(root,"fixture-probe.txt");
        string next=File.Exists(fixture) ? File.ReadAllText(fixture).Trim() : "1";
        if (next=="ERROR") throw new InvalidOperationException("Synthetic COM read failure.");
        rawState="fixture";
#else
        // All methods are from the inspected 5.9.2.9 type library. VOID return values are not success codes.
        if (!registered) { Call("AddItem",new object[] { ProbeAddress },null); registered=true; }
        object[] validArgs=new object[] { ProbeAddress,0 };
        ParameterModifier validModifier=new ParameterModifier(2); validModifier[1]=true;
        Call("IsValidReference",validArgs,new ParameterModifier[] { validModifier });
        if (Convert.ToInt32(validArgs[1],CultureInfo.InvariantCulture)==0) throw new InvalidOperationException("COM responds but internal timer reference is invalid; verify GH project.");
        object[] args=new object[] { ProbeAddress,new string(' ',30),new string(' ',30),0 };
        ParameterModifier modifier=new ParameterModifier(4); modifier[1]=true; modifier[2]=true; modifier[3]=true;
        Call("GetItemValue",args,new ParameterModifier[] { modifier });
        string next=TextValue(args[1]); rawState=TextValue(args[2]);
#endif
        Engine after=Inspect();
        if (after==null || after.Identity!=engine.Identity) throw new InvalidOperationException("Engine changed during COM probe.");
        long number, previous;
        bool numeric=Int64.TryParse(next,NumberStyles.Integer,CultureInfo.InvariantCulture,out number);
        readStatus=numeric ? "NumericValue" : "NoNumericValue";
        if (sampled && numeric && Int64.TryParse(value,NumberStyles.Integer,CultureInfo.InvariantCulture,out previous) && number!=previous) valueChangedTicks=DateTime.UtcNow.Ticks;
        value=next; sampled=true; comReply="OK"; comReplyTicks=DateTime.UtcNow.Ticks;
    }
    private string AttemptsFile { get { return Path.Combine(root,"runtime\\keeper-attempts.xml"); } }
    private void LoadAttempts() {
        if (!File.Exists(AttemptsFile)) return;
        XmlDocument d = LoadXml(AttemptsFile);
        if (d.DocumentElement.Name != "KeeperAttempts") throw new InvalidOperationException("Invalid keeper attempts file.");
        foreach (XmlNode n in d.SelectNodes("/KeeperAttempts/Attempt")) {
            long ticks = Int64.Parse(n.InnerText);
            if (ticks <= 0 || ticks > DateTime.MaxValue.Ticks || attempts.Count >= 10000) throw new InvalidOperationException("Invalid keeper attempt.");
            attempts.Add(ticks);
        }
    }
    private bool ReserveAttempt() {
        long now = DateTime.UtcNow.Ticks, cutoff = DateTime.UtcNow.AddMinutes(-restartWindowMinutes).Ticks;
        for (int i=attempts.Count-1; i>=0; i--) { if (attempts[i] > now) attempts[i] = now; if (attempts[i] <= cutoff) attempts.RemoveAt(i); }
        if (maxStartsPerWindow>0 && attempts.Count >= maxStartsPerWindow) return false;
        // One free slot before persisting, even after repeated clock rollbacks.
        // Retain newest records so restoring a positive quota stays conservative.
        if (attempts.Count>=10000) { attempts.Sort(); attempts.RemoveRange(0,attempts.Count-9999); }
        attempts.Add(now);
        XmlDocument d = new XmlDocument(); d.LoadXml("<KeeperAttempts/>");
        foreach (long t in attempts) { XmlElement n = d.CreateElement("Attempt"); n.InnerText=t.ToString(); d.DocumentElement.AppendChild(n); }
        Save(d,AttemptsFile); return true;
    }
    private static void Save(XmlDocument d, string path) {
        string temp = path+".tmp"; d.Save(temp);
        if (File.Exists(path)) File.Replace(temp,path,path+".previous"); else File.Move(temp,path);
    }
    private void Status(string phase, string message) {
        XmlDocument d = new XmlDocument(); d.LoadXml("<Keeper version=\"1\"/>");
        XmlElement n = d.DocumentElement;
        n.SetAttribute("phase",phase); n.SetAttribute("message",message);
        n.SetAttribute("pid",pid.ToString()); n.SetAttribute("startedTicks",started.ToString());
        n.SetAttribute("session",session.ToString()); n.SetAttribute("updatedTicks",DateTime.UtcNow.Ticks.ToString());
        n.SetAttribute("enginePath",enginePath); n.SetAttribute("configPath",configFile);
        n.SetAttribute("enginePid",engine == null ? "0" : engine.Pid.ToString());
        n.SetAttribute("engineStartedTicks",engine == null ? "0" : engine.Started.ToString());
        n.SetAttribute("comReply",comReply); n.SetAttribute("comReplyTicks",comReplyTicks.ToString());
        n.SetAttribute("probeAddress",ProbeAddress); n.SetAttribute("value",value); n.SetAttribute("rawState",rawState);
        n.SetAttribute("readStatus",readStatus); n.SetAttribute("valueChangedTicks",valueChangedTicks.ToString());
        n.SetAttribute("windowDetail",windowDetail);
        n.SetAttribute("maxStartsPerWindow",maxStartsPerWindow.ToString());
        n.SetAttribute("restartWindowMinutes",restartWindowMinutes.ToString());
        try { Save(d,statusFile); }
        catch (IOException e) { Log("STATUS_RETRY: "+e.Message); } // A short reader/AV lock must not release the retained connector.
        catch (UnauthorizedAccessException e) { Log("STATUS_RETRY: "+e.Message); }
    }
    private void Log(string message) {
        if (logFile == null) return;
        try {
        if (File.Exists(logFile) && new FileInfo(logFile).Length > 1048576) { if (File.Exists(logFile+".1")) File.Delete(logFile+".1"); File.Move(logFile,logFile+".1"); }
        File.AppendAllText(logFile,DateTime.Now.ToString("s")+" "+message+Environment.NewLine);
        } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
    private bool Stopping() { return File.Exists(stopFile) || File.ReadAllText(configFile) != configText; }
    private void Pump(int milliseconds) {
        Stopwatch w = Stopwatch.StartNew();
        while (w.ElapsedMilliseconds < milliseconds && !Stopping()) { Application.DoEvents(); Thread.Sleep(100); }
    }
    private void Run() {
        while (!Stopping()) {
            try {
                Engine current = Inspect();
                if (connector != null && (current == null || current.Identity != engine.Identity)) {
                    Status("Reconnecting","Vuniq identity changed; releasing only the keeper's stale reference.");
                    Log("Engine changed; reconnecting."); Release();
                }
                if (connector == null) {
                    VerifyRegistration();
                    if (!ReserveAttempt()) { Status("RateLimited","Connector activation quota "+maxStartsPerWindow+" in "+restartWindowMinutes+" minutes; waiting."); Pump(2000); continue; }
                    Status("Connecting","Activating retained connector; only existing internal timer is read, no writes.");
                    if (Stopping()) break;
                    connector = Activate();
                    engine = Inspect();
                    if (engine == null || (current != null && current.Identity != engine.Identity)) throw new InvalidOperationException("Vuniq identity changed during activation.");
                    Log("Connector retained; engine="+engine.Identity);
                }
                string health = NILITGHWatchdog.Native.Check(engine.Pid);
                windowDetail=NILITGHWatchdog.Native.DescribeWindows(engine.Pid);
                bool warmed = DateTime.UtcNow.Ticks - engine.Started >= TimeSpan.FromSeconds(10).Ticks;
                Status("Probing","Testing read-only internal timer COM round-trip; window="+health);
                Probe();
                Status(warmed ? "Ready" : "Waiting", "COM reply=OK; window="+health+"; timer="+value+"; raw state="+rawState+". NILIT activity, PLC freshness and SAP delivery are separate evidence.");
                Pump(2000);
            } catch (Exception e) {
                comReply="Error"; readStatus="Error"; registered=false;
                while (e is TargetInvocationException && e.InnerException != null) e=e.InnerException;
                Log("ERROR: "+e.Message); Status("Error",e.Message);
                // Retain an existing reference on inspection errors; never close Vuniq to recover NILIT.
                Pump(5000);
            }
        }
    }
}
