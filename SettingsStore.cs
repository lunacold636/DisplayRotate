using System;
using Microsoft.Win32;

namespace DisplayRotate
{
    /// <summary>
    /// 设置存储：HKCU\Software\luyanjia\DisplayRotate。
    /// </summary>
    internal static class SettingsStore
    {
        private const string Root = @"Software\luyanjia\DisplayRotate";

        public static string Port
        {
            get { return Get("port", ""); }
            set { Set("port", value); }
        }

        public static string Monitor
        {
            get { return Get("monitor", ""); }
            set { Set("monitor", value); }
        }

        private static string Get(string name, string def)
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(Root))
            {
                if (key == null)
                    return def;
                object v = key.GetValue(name);
                return v == null ? def : v.ToString();
            }
        }

        private static void Set(string name, string value)
        {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(Root))
            {
                if (key != null)
                    key.SetValue(name, value);
            }
        }

    }
}
