using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace DisplayRotate
{
    internal enum DisplayRotation
    {
        Default = 0,
        Rotate90 = 1,
        Rotate180 = 2,
        Rotate270 = 3
    }

    /// <summary>
    /// Windows 显示器旋转，纯 Win32 API（EnumDisplayDevices / ChangeDisplaySettingsEx）。
    /// </summary>
    internal static class DisplayRotator
    {
        private const int DMDO_DEFAULT = 0;
        private const int DMDO_90 = 1;
        private const int DMDO_180 = 2;
        private const int DMDO_270 = 3;
        private const int ENUM_CURRENT_SETTINGS = -1;
        private const int DM_PELSWIDTH = 0x00080000;
        private const int DM_PELSHEIGHT = 0x00100000;
        private const int DM_DISPLAYORIENTATION = 0x00000080;
        private const uint CDS_RESET = 0x00000001;
        private const uint DISPLAY_DEVICE_ACTIVE = 0x00000001;
        private const int DISP_CHANGE_SUCCESSFUL = 0;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DEVMODE
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion;
            public short dmDriverVersion;
            public short dmSize;
            public short dmDriverExtra;
            public int dmFields;
            public int dmPositionX;
            public int dmPositionY;
            public int dmDisplayOrientation;
            public int dmDisplayFixedOutput;
            public short dmColor;
            public short dmDuplex;
            public short dmYResolution;
            public short dmTTOption;
            public short dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels;
            public int dmBitsPerPel;
            public int dmPelsWidth;
            public int dmPelsHeight;
            public int dmDisplayFlags;
            public int dmDisplayFrequency;
            public int dmICMMethod;
            public int dmICMIntent;
            public int dmMediaType;
            public int dmDitherType;
            public int dmReserved1;
            public int dmReserved2;
            public int dmPanningWidth;
            public int dmPanningHeight;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DISPLAY_DEVICE
        {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool EnumDisplaySettingsEx(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode, uint dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwFlags, IntPtr lParam);

        private static readonly object SyncLock = new object();

        /// <summary>返回当前活动的显示器设备名（如 \\.\DISPLAY1）。</summary>
        public static List<string> ActiveMonitors()
        {
            List<string> list = new List<string>();
            DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
            dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            uint i = 0;
            while (EnumDisplayDevices(null, i, ref dd, 0))
            {
                if ((dd.StateFlags & DISPLAY_DEVICE_ACTIVE) != 0)
                    list.Add(dd.DeviceName);
                i++;
                dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            }
            return list;
        }

        public static DisplayRotation GetRotation(string monitor)
        {
            DEVMODE dm = new DEVMODE();
            dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettingsEx(monitor, ENUM_CURRENT_SETTINGS, ref dm, 0))
                return DisplayRotation.Default;
            switch (dm.dmDisplayOrientation)
            {
                case DMDO_90: return DisplayRotation.Rotate90;
                case DMDO_180: return DisplayRotation.Rotate180;
                case DMDO_270: return DisplayRotation.Rotate270;
                default: return DisplayRotation.Default;
            }
        }

        public static bool Rotate(string monitor, DisplayRotation r)
        {
            lock (SyncLock)
            {
                DEVMODE dm = new DEVMODE();
                dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
                if (!EnumDisplaySettingsEx(monitor, ENUM_CURRENT_SETTINGS, ref dm, 0))
                    return false;

                int defW, defH;
                switch (dm.dmDisplayOrientation)
                {
                    case DMDO_90:
                    case DMDO_270:
                        defW = dm.dmPelsHeight;
                        defH = dm.dmPelsWidth;
                        break;
                    default:
                        defW = dm.dmPelsWidth;
                        defH = dm.dmPelsHeight;
                        break;
                }

                int oldOri = dm.dmDisplayOrientation;
                switch (r)
                {
                    case DisplayRotation.Default:
                        dm.dmDisplayOrientation = DMDO_DEFAULT;
                        dm.dmPelsWidth = defW;
                        dm.dmPelsHeight = defH;
                        break;
                    case DisplayRotation.Rotate90:
                        dm.dmDisplayOrientation = DMDO_90;
                        dm.dmPelsWidth = defH;
                        dm.dmPelsHeight = defW;
                        break;
                    case DisplayRotation.Rotate180:
                        dm.dmDisplayOrientation = DMDO_180;
                        dm.dmPelsWidth = defW;
                        dm.dmPelsHeight = defH;
                        break;
                    case DisplayRotation.Rotate270:
                        dm.dmDisplayOrientation = DMDO_270;
                        dm.dmPelsWidth = defH;
                        dm.dmPelsHeight = defW;
                        break;
                    default:
                        return false;
                }

                if (oldOri == dm.dmDisplayOrientation)
                    return true;

                dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYORIENTATION;
                int ret = ChangeDisplaySettingsEx(monitor, ref dm, IntPtr.Zero, CDS_RESET, IntPtr.Zero);
                return ret == DISP_CHANGE_SUCCESSFUL;
            }
        }
    }
}
