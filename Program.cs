using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace DisplayRotate
{
    internal static class Program
    {
        [DllImport("user32.dll")]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            // 单实例：第二个实例直接提示并退出，避免多份托盘图标与串口争抢
            bool createdNew;
            using (Mutex m = new Mutex(true, @"Local\DisplayRotate_SingleInstance", out createdNew))
            {
                if (!createdNew)
                {
                    MessageBox.Show("DisplayRotate 已在运行。", "DisplayRotate",
                        MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }

                // 高分屏：启用 per-monitor DPI 感知（v2），避免 4K 屏文字发虚。
                // 旧系统不支持该 API 时抛异常，属预期情况，静默忽略即可。
                try
                {
                    SetProcessDpiAwarenessContext(new IntPtr(-4)); // PER_MONITOR_AWARE_V2
                }
                catch
                {
                }

                bool autostart = false;
                string[] args = Environment.GetCommandLineArgs();
                for (int i = 1; i < args.Length; i++)
                {
                    if (args[i] == "--autostart")
                        autostart = true;
                }

                // 全局异常兜底：一律写入日志，避免崩溃时连原因都查不到
                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                Application.ThreadException += delegate(object sender, System.Threading.ThreadExceptionEventArgs e)
                {
                    Log.Error("UI 线程未处理异常", e.Exception);
                };
                AppDomain.CurrentDomain.UnhandledException += delegate(object sender, UnhandledExceptionEventArgs e)
                {
                    Exception ex = e.ExceptionObject as Exception;
                    if (ex != null)
                        Log.Error("非 UI 线程未处理异常", ex);
                };

                Application.Run(new MainForm(autostart));
            }
        }
    }
}
