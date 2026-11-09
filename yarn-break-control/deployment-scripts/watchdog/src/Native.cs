using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
namespace NILITGHWatchdog {
    public static class Native {
        private delegate bool EnumProc(IntPtr hwnd, IntPtr data);
        [DllImport("user32.dll", SetLastError=true)]
        private static extern bool EnumWindows(EnumProc callback, IntPtr data);
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError=true)]
        private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message,
            UIntPtr wparam, IntPtr lparam, uint flags, uint timeout, out UIntPtr result);
        [DllImport("kernel32.dll")]
        private static extern void SetLastError(uint error);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern uint GetLongPathName(string shortPath, StringBuilder longPath, uint capacity);
        public static string CanonicalPath(string path) {
            StringBuilder buffer = new StringBuilder(32768);
            uint count = GetLongPathName(path, buffer, (uint)buffer.Capacity);
            if (count == 0 || count >= buffer.Capacity)
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),
                    "Cannot verify the full executable path.");
            return buffer.ToString();
        }
        public static string Check(int processId) {
            List<IntPtr> windows = new List<IntPtr>();
            bool enumerated = EnumWindows(delegate(IntPtr hwnd, IntPtr data) {
                uint owner; GetWindowThreadProcessId(hwnd, out owner);
                if (owner == (uint)processId) windows.Add(hwnd);
                return windows.Count <= 30;
            }, IntPtr.Zero);
            if (!enumerated || windows.Count == 0 || windows.Count > 30) return "Unknown";
            bool uncertain = false;
            Stopwatch elapsed = Stopwatch.StartNew();
            foreach (IntPtr hwnd in windows) {
                uint owner; GetWindowThreadProcessId(hwnd, out owner);
                if (owner != (uint)processId) { uncertain = true; continue; }
                long remaining = 2000 - elapsed.ElapsedMilliseconds;
                if (remaining <= 0) return "Unknown";
                UIntPtr result;
                SetLastError(0);
                // WM_NULL; no messages that change application state. The whole
                // sequence has a two-second budget, including hidden windows.
                IntPtr ok = SendMessageTimeout(hwnd, 0, UIntPtr.Zero, IntPtr.Zero,
                    0x0001 | 0x0020, (uint)remaining, out result);
                if (ok == IntPtr.Zero) {
                    int error = Marshal.GetLastWin32Error();
                    if (error == 1460) return "Hung";
                    uncertain = true;
                }
            }
            return uncertain ? "Unknown" : "Responsive";
        }
        public static string DescribeWindows(int processId) {
            int total=0, visible=0;
            bool ok=EnumWindows(delegate(IntPtr hwnd,IntPtr data) {
                uint owner; GetWindowThreadProcessId(hwnd,out owner);
                if(owner==(uint)processId) { total++; if(IsWindowVisible(hwnd)) visible++; }
                return total<=1000;
            },IntPtr.Zero);
            return "total="+total+"; visible="+visible+"; enumOK="+ok+"; originalProbeLimit=30";
        }
    }
}
