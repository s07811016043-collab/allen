# Petalia desktop probe (Windows).
#
# Prints the desktop's furniture as tab-separated lines on stdout and exits.
# Everything here is read-only: it enumerates, it never clicks, moves or closes
# anything.
#
#   MONITOR  x y w h  workX workY workW workH  primary
#   TASKBAR  x y w h
#   WINDOW   hwnd x y w h z title
#   ICON     x y w h name
#   NOTE     <diagnostic>            (never fatal; the caller just logs it)
#
# Why P/Invoke and not a friendlier API: there is no supported way to ask the
# shell where the desktop icons are. The only route is to talk to the
# SysListView32 that Explorer uses to draw them, and because that control lives
# in another process, LVM_GETITEMRECT has to be given a pointer that is valid in
# *Explorer's* address space. Hence OpenProcess + VirtualAllocEx: we rent a page
# inside Explorer, let it write the answer there, and read it back.
#
# Called by core/nav/providers/win32_provider.gd, always off the main thread.

param([int]$ExcludePid = 0, [int]$MaxIcons = 240)

$ErrorActionPreference = 'Stop'

$source = @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;

public static class PetaliaDesktop
{
	[StructLayout(LayoutKind.Sequential)]
	public struct RECT { public int left, top, right, bottom; }

	[StructLayout(LayoutKind.Sequential)]
	public struct POINT { public int x, y; }

	[StructLayout(LayoutKind.Sequential)]
	public struct MONITORINFO
	{
		public uint cbSize;
		public RECT rcMonitor;
		public RECT rcWork;
		public uint dwFlags;
	}

	// Must match Explorer's own LVITEM layout exactly; letting the marshaller
	// lay it out sequentially gets the 64-bit padding right for free.
	[StructLayout(LayoutKind.Sequential)]
	public struct LVITEM
	{
		public uint mask;
		public int iItem;
		public int iSubItem;
		public uint state;
		public uint stateMask;
		public IntPtr pszText;
		public int cchTextMax;
		public int iImage;
		public IntPtr lParam;
		public int iIndent;
		public int iGroupId;
		public uint cColumns;
		public IntPtr puColumns;
		public IntPtr piColFmt;
		public int iGroup;
	}

	public delegate bool EnumProc(IntPtr hwnd, IntPtr lparam);
	public delegate bool MonitorProc(IntPtr mon, IntPtr hdc, IntPtr rect, IntPtr data);

	[DllImport("user32.dll", CharSet = CharSet.Unicode)]
	public static extern IntPtr FindWindowW(string cls, string title);
	[DllImport("user32.dll", CharSet = CharSet.Unicode)]
	public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
	[DllImport("user32.dll")]
	public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
	[DllImport("user32.dll", CharSet = CharSet.Unicode)]
	public static extern IntPtr SendMessageW(IntPtr hwnd, uint msg, IntPtr wp, IntPtr lp);
	[DllImport("user32.dll")]
	public static extern bool ClientToScreen(IntPtr hwnd, ref POINT pt);
	[DllImport("user32.dll")]
	public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
	[DllImport("user32.dll")]
	public static extern bool IsWindowVisible(IntPtr hwnd);
	[DllImport("user32.dll")]
	public static extern bool IsIconic(IntPtr hwnd);
	[DllImport("user32.dll", CharSet = CharSet.Unicode)]
	public static extern int GetWindowTextW(IntPtr hwnd, StringBuilder buf, int max);
	[DllImport("user32.dll", CharSet = CharSet.Unicode)]
	public static extern int GetClassNameW(IntPtr hwnd, StringBuilder buf, int max);
	[DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
	public static extern IntPtr GetWindowLongPtr64(IntPtr hwnd, int index);
	[DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
	public static extern int GetWindowLong32(IntPtr hwnd, int index);
	[DllImport("user32.dll")]
	public static extern bool EnumWindows(EnumProc cb, IntPtr lparam);
	[DllImport("user32.dll")]
	public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorProc cb, IntPtr data);
	[DllImport("user32.dll", CharSet = CharSet.Unicode)]
	public static extern bool GetMonitorInfoW(IntPtr mon, ref MONITORINFO mi);

	[DllImport("dwmapi.dll")]
	public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT val, int size);
	[DllImport("dwmapi.dll")]
	public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int val, int size);

	[DllImport("kernel32.dll", SetLastError = true)]
	public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
	[DllImport("kernel32.dll", SetLastError = true)]
	public static extern bool CloseHandle(IntPtr h);
	[DllImport("kernel32.dll", SetLastError = true)]
	public static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr addr, UIntPtr size, uint type, uint protect);
	[DllImport("kernel32.dll", SetLastError = true)]
	public static extern bool VirtualFreeEx(IntPtr h, IntPtr addr, UIntPtr size, uint type);
	[DllImport("kernel32.dll", SetLastError = true)]
	public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, IntPtr buf, UIntPtr size, out UIntPtr read);
	[DllImport("kernel32.dll", SetLastError = true)]
	public static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, IntPtr buf, UIntPtr size, out UIntPtr written);

	const int GWL_EXSTYLE = -20;
	const long WS_EX_TOOLWINDOW = 0x00000080L;
	const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
	const int DWMWA_CLOAKED = 14;
	const uint LVM_GETITEMCOUNT = 0x1004;
	const uint LVM_GETITEMRECT = 0x100E;
	const uint LVM_GETITEMTEXTW = 0x1073;
	const int LVIR_ICON = 1;
	const uint LVIF_TEXT = 0x0001;
	const uint PROC_ACCESS = 0x0438; // QUERY_INFORMATION | VM_OPERATION | VM_READ | VM_WRITE
	const uint MEM_COMMIT_RESERVE = 0x3000;
	const uint MEM_RELEASE = 0x8000;
	const uint PAGE_READWRITE = 0x04;

	static long GetExStyle(IntPtr hwnd)
	{
		// GetWindowLongPtrW is only exported on 64-bit; on 32-bit it is a macro
		// for GetWindowLongW, so the import must never be touched there.
		if (IntPtr.Size == 8) return GetWindowLongPtr64(hwnd, GWL_EXSTYLE).ToInt64();
		return (long)(uint)GetWindowLong32(hwnd, GWL_EXSTYLE);
	}

	static string Clean(string s)
	{
		if (s == null) return "";
		return s.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ').Trim();
	}

	// Progman normally owns SHELLDLL_DefView. With a wallpaper slideshow running,
	// Explorer reparents it under one of several WorkerW siblings instead, so
	// both layouts have to be tried before giving up.
	public static IntPtr FindDesktopListView()
	{
		IntPtr progman = FindWindowW("Progman", null);
		IntPtr defView = IntPtr.Zero;
		if (progman != IntPtr.Zero)
			defView = FindWindowExW(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
		if (defView == IntPtr.Zero)
		{
			IntPtr worker = IntPtr.Zero;
			for (int i = 0; i < 64; i++)
			{
				worker = FindWindowExW(IntPtr.Zero, worker, "WorkerW", null);
				if (worker == IntPtr.Zero) break;
				defView = FindWindowExW(worker, IntPtr.Zero, "SHELLDLL_DefView", null);
				if (defView != IntPtr.Zero) break;
			}
		}
		if (defView == IntPtr.Zero) return IntPtr.Zero;
		return FindWindowExW(defView, IntPtr.Zero, "SysListView32", null);
	}

	public static void CollectIcons(List<string> lines, int maxIcons)
	{
		IntPtr lv = FindDesktopListView();
		if (lv == IntPtr.Zero) { lines.Add("NOTE\tno-listview"); return; }

		uint pid;
		GetWindowThreadProcessId(lv, out pid);
		IntPtr proc = OpenProcess(PROC_ACCESS, false, pid);
		if (proc == IntPtr.Zero) { lines.Add("NOTE\tno-process-access"); return; }

		IntPtr remote = VirtualAllocEx(proc, IntPtr.Zero, (UIntPtr)4096, MEM_COMMIT_RESERVE, PAGE_READWRITE);
		if (remote == IntPtr.Zero) { CloseHandle(proc); lines.Add("NOTE\tno-remote-page"); return; }

		IntPtr local = Marshal.AllocHGlobal(1024);
		try
		{
			int count = (int)SendMessageW(lv, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero);
			if (count > maxIcons) count = maxIcons;
			// Second half of the rented page holds the icon label; the first half
			// holds whichever struct we are asking Explorer to fill in.
			IntPtr textRemote = new IntPtr(remote.ToInt64() + 512);
			int rectSize = Marshal.SizeOf(typeof(RECT));
			int itemSize = Marshal.SizeOf(typeof(LVITEM));
			UIntPtr written, read;

			for (int i = 0; i < count; i++)
			{
				RECT r = new RECT();
				r.left = LVIR_ICON; // LVM_GETITEMRECT reads the requested part from here
				Marshal.StructureToPtr(r, local, false);
				if (!WriteProcessMemory(proc, remote, local, (UIntPtr)rectSize, out written)) continue;
				if (SendMessageW(lv, LVM_GETITEMRECT, new IntPtr(i), remote) == IntPtr.Zero) continue;
				if (!ReadProcessMemory(proc, remote, local, (UIntPtr)rectSize, out read)) continue;
				r = (RECT)Marshal.PtrToStructure(local, typeof(RECT));

				POINT p;
				p.x = r.left;
				p.y = r.top;
				ClientToScreen(lv, ref p);
				int w = r.right - r.left;
				int h = r.bottom - r.top;
				if (w <= 0 || h <= 0) continue;

				string name = "";
				LVITEM it = new LVITEM();
				it.mask = LVIF_TEXT;
				it.iItem = i;
				it.iSubItem = 0;
				it.pszText = textRemote;
				it.cchTextMax = 200;
				Marshal.StructureToPtr(it, local, false);
				if (WriteProcessMemory(proc, remote, local, (UIntPtr)itemSize, out written))
				{
					if (SendMessageW(lv, LVM_GETITEMTEXTW, new IntPtr(i), remote) != IntPtr.Zero)
					{
						if (ReadProcessMemory(proc, textRemote, local, (UIntPtr)400, out read))
						{
							string raw = Marshal.PtrToStringUni(local, 200);
							int nul = raw.IndexOf('\0');
							name = nul >= 0 ? raw.Substring(0, nul) : raw;
						}
					}
				}
				lines.Add(string.Format("ICON\t{0}\t{1}\t{2}\t{3}\t{4}", p.x, p.y, w, h, Clean(name)));
			}
		}
		finally
		{
			Marshal.FreeHGlobal(local);
			VirtualFreeEx(proc, remote, UIntPtr.Zero, MEM_RELEASE);
			CloseHandle(proc);
		}
	}

	public static void CollectWindows(List<string> lines, int excludePid)
	{
		List<string> acc = new List<string>();
		int[] z = new int[1];
		EnumProc cb = delegate(IntPtr hwnd, IntPtr lp)
		{
			if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return true;
			uint pid;
			GetWindowThreadProcessId(hwnd, out pid);
			if (excludePid != 0 && pid == (uint)excludePid) return true;
			if ((GetExStyle(hwnd) & WS_EX_TOOLWINDOW) != 0) return true;

			// UWP parks cloaked windows all over the virtual desktop. They are
			// invisible, so a pet perched on one would be standing on nothing.
			int cloaked = 0;
			if (DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, out cloaked, sizeof(int)) == 0 && cloaked != 0)
				return true;

			StringBuilder cls = new StringBuilder(160);
			GetClassNameW(hwnd, cls, cls.Capacity);
			string c = cls.ToString();
			if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" ||
				c == "Shell_SecondaryTrayWnd" || c == "Windows.UI.Core.CoreWindow")
				return true;

			StringBuilder tb = new StringBuilder(320);
			GetWindowTextW(hwnd, tb, tb.Capacity);
			string title = Clean(tb.ToString());
			if (title.Length == 0) return true;

			// The DWM frame bounds, not GetWindowRect: since Windows 10 the latter
			// includes several pixels of invisible resize border, and a pet walking
			// that border reads as hovering next to the window.
			RECT r;
			if (DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf(typeof(RECT))) != 0)
			{
				if (!GetWindowRect(hwnd, out r)) return true;
			}
			int w = r.right - r.left;
			int h = r.bottom - r.top;
			if (w < 80 || h < 60) return true;

			acc.Add(string.Format("WINDOW\t{0}\t{1}\t{2}\t{3}\t{4}\t{5}\t{6}",
				hwnd.ToInt64(), r.left, r.top, w, h, z[0], title));
			z[0]++;
			return true;
		};
		EnumWindows(cb, IntPtr.Zero);
		GC.KeepAlive(cb);
		lines.AddRange(acc);
	}

	public static void CollectMonitors(List<string> lines)
	{
		List<string> acc = new List<string>();
		MonitorProc cb = delegate(IntPtr mon, IntPtr hdc, IntPtr prect, IntPtr data)
		{
			MONITORINFO mi = new MONITORINFO();
			mi.cbSize = (uint)Marshal.SizeOf(typeof(MONITORINFO));
			if (GetMonitorInfoW(mon, ref mi))
			{
				acc.Add(string.Format("MONITOR\t{0}\t{1}\t{2}\t{3}\t{4}\t{5}\t{6}\t{7}\t{8}",
					mi.rcMonitor.left, mi.rcMonitor.top,
					mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top,
					mi.rcWork.left, mi.rcWork.top,
					mi.rcWork.right - mi.rcWork.left, mi.rcWork.bottom - mi.rcWork.top,
					(mi.dwFlags & 1u) != 0 ? 1 : 0));
			}
			return true;
		};
		EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
		GC.KeepAlive(cb);
		lines.AddRange(acc);
	}

	public static void CollectTaskbars(List<string> lines)
	{
		RECT r;
		IntPtr tray = FindWindowW("Shell_TrayWnd", null);
		if (tray != IntPtr.Zero && GetWindowRect(tray, out r))
			lines.Add(string.Format("TASKBAR\t{0}\t{1}\t{2}\t{3}", r.left, r.top, r.right - r.left, r.bottom - r.top));
		IntPtr sec = IntPtr.Zero;
		for (int i = 0; i < 8; i++)
		{
			sec = FindWindowExW(IntPtr.Zero, sec, "Shell_SecondaryTrayWnd", null);
			if (sec == IntPtr.Zero) break;
			if (GetWindowRect(sec, out r))
				lines.Add(string.Format("TASKBAR\t{0}\t{1}\t{2}\t{3}", r.left, r.top, r.right - r.left, r.bottom - r.top));
		}
	}

	// Each collector is isolated: a locked-down machine that refuses
	// OpenProcess should still give us windows and monitors, not nothing.
	public static string[] Probe(int excludePid, int maxIcons)
	{
		List<string> lines = new List<string>();
		try { CollectMonitors(lines); } catch (Exception e) { lines.Add("NOTE\tmonitors:" + e.GetType().Name); }
		try { CollectTaskbars(lines); } catch (Exception e) { lines.Add("NOTE\ttaskbars:" + e.GetType().Name); }
		try { CollectWindows(lines, excludePid); } catch (Exception e) { lines.Add("NOTE\twindows:" + e.GetType().Name); }
		try { CollectIcons(lines, maxIcons); } catch (Exception e) { lines.Add("NOTE\ticons:" + e.GetType().Name); }
		return lines.ToArray();
	}
}
'@

try {
	Add-Type -TypeDefinition $source -Language CSharp | Out-Null
	foreach ($line in [PetaliaDesktop]::Probe($ExcludePid, $MaxIcons)) {
		Write-Output $line
	}
} catch {
	# The caller treats a bare NOTE line as "nothing usable, keep simulating".
	Write-Output ("NOTE`tfatal:" + $_.Exception.Message.Replace("`t", " ").Replace("`r", " ").Replace("`n", " "))
	exit 1
}
