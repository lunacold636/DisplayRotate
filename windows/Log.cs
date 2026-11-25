using System;
using System.IO;

namespace DisplayRotate
{
    /// <summary>
    /// 轻量文件日志：崩溃 / 异常诊断用。
    /// 所有方法都保证不抛异常，失败时静默降级，绝不影响主流程。
    /// 日志文件生成在程序目录下：DisplayRotate.log。
    /// </summary>
    internal static class Log
    {
        private const string FileName = "DisplayRotate.log";
        private static readonly object Sync = new object();
        private static string _path;
        private static bool _ready;

        public static bool Init()
        {
            if (_ready)
                return true;
            lock (Sync)
            {
                if (_ready)
                    return true;
                try
                {
                    _path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, FileName);
                    _ready = true;
                }
                catch
                {
                    _ready = false;
                }
            }
            return _ready;
        }

        public static void Error(string label, Exception ex)
        {
            if (!Init())
                return;
            lock (Sync)
            {
                try
                {
                    File.AppendAllText(_path,
                        string.Format("[{0:yyyy-MM-dd HH:mm:ss}] {1}: {2}{3}{4}",
                            DateTime.Now, label, ex == null ? "(无异常对象)" : ex.ToString(),
                            Environment.NewLine, Environment.NewLine));
                }
                catch
                {
                }
            }
        }
    }
}
