using System;
using System.IO;
using System.IO.Ports;
using System.Threading;

namespace DisplayRotate
{
    /// <summary>
    /// 传感器基准探测工具：连接 GY-25T 后实时打印方向与原始加速度，
    /// 用于实测「横屏」状态下的基准值，供主程序写死基准（LandscapeDir）。
    /// 用法：
    ///   SensorProbe.exe                  // 交互模式：Enter 记录基准，Q 退出
    ///   SensorProbe.exe COM3             // 指定串口
    ///   SensorProbe.exe COM3 --wait 5    // 等待 5 秒后自动记录最后一次稳定方向并退出
    /// </summary>
    internal static class SensorProbe
    {
        private const string BaselineFile = "baseline.txt";

        private static void Main(string[] args)
        {
            Console.OutputEncoding = System.Text.Encoding.UTF8;
            Console.WriteLine("=== GY-25T 传感器基准探测 ===");

            string[] ports = SerialPort.GetPortNames();
            if (args.Length > 0 && args[0] == "--list")
            {
                Console.WriteLine(ports.Length == 0 ? "未发现任何 COM 口" : "可用串口: " + string.Join(", ", ports));
                return;
            }
            if (ports.Length == 0)
            {
                Console.WriteLine("未发现任何 COM 口。请检查：驱动是否安装、是否插在 USB2.0 口。");
                return;
            }

            string port = args.Length > 0 && !args[0].StartsWith("--") ? args[0] : ports[0];
            bool found = false;
            foreach (string p in ports)
                if (p == port) { found = true; break; }
            if (!found)
            {
                Console.WriteLine("指定串口不存在: " + port + "，可用: " + string.Join(", ", ports));
                return;
            }

            int waitSec = 0;
            for (int i = 1; i < args.Length - 1; i++)
            {
                if (args[i] == "--wait")
                {
                    int.TryParse(args[i + 1], out waitSec);
                    break;
                }
            }

            Console.WriteLine("打开串口 " + port + " ...");
            Gy25t s = new Gy25t();
            s.SetPortName(port);
            if (!s.Open())
            {
                Console.WriteLine("打开串口失败");
                return;
            }
            Console.WriteLine("初始化传感器（最多约 18 秒）...");
            s.Init();
            Console.WriteLine("已连接，开始读取...");

            if (waitSec > 0)
                RunAutoCapture(s, waitSec);
            else
                RunInteractive(s);

            s.Dispose();
        }

        private static void RunInteractive(Gy25t s)
        {
            Console.WriteLine();
            Console.WriteLine("操作说明：");
            Console.WriteLine("  1) 请把设备摆到【横屏】并保持稳定；");
            Console.WriteLine("  2) 按 Enter 记录当前状态为「横屏基准」；");
            Console.WriteLine("  3) 可再摆到【竖屏】按 Enter 记录，用于校验方向；");
            Console.WriteLine("  按 Q 退出。");
            Console.WriteLine();

            string lastDir = "";
            int stableMs = 0;
            DateTime lastPrint = DateTime.MinValue;
            while (true)
            {
                if (Console.KeyAvailable)
                {
                    ConsoleKey k = Console.ReadKey(true).Key;
                    if (k == ConsoleKey.Q) break;
                    if (k == ConsoleKey.Enter) Capture(s, "手动基准");
                }

                SensorDirection d = s.LastDirection;
                string ds = DirText(d);
                if (ds == lastDir && d != SensorDirection.Unknown)
                    stableMs += 200;
                else
                {
                    stableMs = 0;
                    lastDir = ds;
                }

                DateTime now = DateTime.Now;
                if ((now - lastPrint).TotalMilliseconds >= 500)
                {
                    lastPrint = now;
                    Console.WriteLine(string.Format("[{0:HH:mm:ss}] 方向={1,-4} X={2,5} Y={3,5} Z={4,5}  稳定 {5} ms",
                        now, ds, s.AvgX, s.AvgY, s.AvgZ, stableMs));
                }
                Thread.Sleep(200);
            }
            Console.WriteLine("已退出。");
        }

        private static void RunAutoCapture(Gy25t s, int waitSec)
        {
            Console.WriteLine("自动模式：等待 " + waitSec + " 秒后记录最后一次稳定方向。");
            string lastDir = "";
            int stableMs = 0;
            DateTime lastPrint = DateTime.MinValue;
            DateTime end = DateTime.Now.AddSeconds(waitSec);
            while (DateTime.Now < end)
            {
                SensorDirection d = s.LastDirection;
                string ds = DirText(d);
                if (ds == lastDir && d != SensorDirection.Unknown)
                    stableMs += 200;
                else
                {
                    stableMs = 0;
                    lastDir = ds;
                }

                DateTime now = DateTime.Now;
                if ((now - lastPrint).TotalMilliseconds >= 500)
                {
                    lastPrint = now;
                    Console.WriteLine(string.Format("[{0:HH:mm:ss}] 方向={1,-4} X={2,5} Y={3,5} Z={4,5}  稳定 {5} ms",
                        now, ds, s.AvgX, s.AvgY, s.AvgZ, stableMs));
                }
                Thread.Sleep(200);
            }
            Console.WriteLine("-- 采集结束 --");
            if (stableMs >= 1000 && s.LastDirection != SensorDirection.Unknown)
                Capture(s, "横屏基准（自动）");
            else
                Console.WriteLine("未采集到稳定方向（最后方向=" + DirText(s.LastDirection) + "），请确认设备是否横屏放稳后重试。");
        }

        private static void Capture(Gy25t s, string label)
        {
            SensorDirection d = s.LastDirection;
            string line = string.Format("{0}: 方向={1} X={2} Y={3} Z={4}",
                label, DirText(d), s.AvgX, s.AvgY, s.AvgZ);
            Console.WriteLine();
            Console.WriteLine(">>> " + line);
            Console.WriteLine(">>> 建议写死为常量（方向即基准）: LandscapeDir = SensorDirection." + d + ";");
            try
            {
                File.AppendAllText(BaselineFile, line + Environment.NewLine);
                Console.WriteLine("已追加写入 " + BaselineFile + "（程序目录下）");
            }
            catch (Exception ex)
            {
                Console.WriteLine("写入 baseline.txt 失败: " + ex.Message);
            }
            Console.WriteLine();
        }

        private static string DirText(SensorDirection d)
        {
            switch (d)
            {
                case SensorDirection.Up: return "上";
                case SensorDirection.Right: return "右";
                case SensorDirection.Down: return "下";
                case SensorDirection.Left: return "左";
                default: return "--";
            }
        }
    }
}