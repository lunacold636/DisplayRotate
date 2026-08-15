using System;
using System.Collections.Generic;
using System.IO.Ports;
using System.Threading;

namespace DisplayRotate
{
    internal enum SensorDirection
    {
        Up,
        Right,
        Down,
        Left,
        Unknown
    }

    /// <summary>
    /// GY-25T 串口通信：组帧/校验/加速度解析/方向判定，逻辑与 Qt 版一致。
    /// </summary>
    internal class Gy25t : IDisposable
    {
        private const int AccWindow = 20;
        private const int XUp = -1;  // 安装方向约定：X 轴 -1g = 上（装反了交换这两个常量）
        private const int XDown = 1; // X 轴 +1g = 下
        private const int WatchdogPeriodMs = 1000;   // 看门狗检查周期
        private const double WatchdogTimeoutSec = 5; // 超过 5 秒无有效加速度帧即判定离线

        private readonly SerialPort _port;
        private readonly List<byte> _rx = new List<byte>();
        private readonly int[][] _acc = new int[3][];
        private readonly Dictionary<SensorDirection, int> _countMap = new Dictionary<SensorDirection, int>();
        private readonly ManualResetEventSlim _ackEvent = new ManualResetEventSlim(false);
        private readonly object _lock = new object();

        private int _accIndex;
        private int _accCount;
        private volatile bool _ready;
        private bool _subscribed;
        private byte[] _pendingCmd;
        private DateTime _lastAccUtc = DateTime.MinValue;
        private System.Threading.Timer _watchdog;
        private volatile int _stateGen; // 连接状态代数：Open/Close 时递增，用于丢弃滞留事件
        private int _pendingGen;        // 当前待触发事件对应的代数（仅在串口接收线程访问）

        public bool IsOpen
        {
            get { return _port != null && _port.IsOpen; }
        }

        public bool IsReady
        {
            get { return _ready; }
        }

        public string PortName
        {
            get { return _port.PortName; }
        }

        public SensorDirection LastDirection { get; private set; }

        public event Action<bool> ReadyChanged;
        public event Action<SensorDirection> Rotated;

        public Gy25t()
        {
            _port = new SerialPort
            {
                BaudRate = 9600,
                DataBits = 8,
                Parity = Parity.None,
                StopBits = StopBits.One,
                WriteTimeout = 2000,   // 读写超时：设备异常时防止串口调用无限阻塞
                ReadTimeout = 2000
            };
            for (int i = 0; i < 3; i++)
                _acc[i] = new int[AccWindow + 2];
        }

        public void SetPortName(string name)
        {
            _port.PortName = name;
        }

        public bool Open()
        {
            try
            {
                if (!_port.IsOpen)
                    _port.Open();
                if (!_subscribed)
                {
                    _port.DataReceived += OnDataReceived;
                    _port.ErrorReceived += OnErrorReceived;
                    _subscribed = true;
                }
                ResetState();
                lock (_lock)
                {
                    if (_watchdog == null)
                        _watchdog = new System.Threading.Timer(OnWatchdogTick, null,
                            WatchdogPeriodMs, WatchdogPeriodMs);
                }
                return true;
            }
            catch (Exception ex)
            {
                Log.Error("打开串口失败", ex);
                return false;
            }
        }

        public void Close()
        {
            try
            {
                if (_subscribed)
                {
                    _port.DataReceived -= OnDataReceived;
                    _port.ErrorReceived -= OnErrorReceived;
                    _subscribed = false;
                }
                if (_port.IsOpen)
                    _port.Close();
            }
            catch (Exception ex)
            {
                Log.Error("关闭串口异常", ex);
            }
            System.Threading.Timer w = _watchdog;
            _watchdog = null;
            if (w != null)
                w.Dispose();
            ResetState();
            SetReady(false);
        }

        /// <summary>初始化序列：查询模式 → 配置 → 自动模式，每条指令等待应答（最多 3 秒）。</summary>
        public void Init()
        {
            WriteSync(Hex("00 06 03 01 0A")); // 查询模式
            WriteSync(Hex("00 06 07 53 60")); // 水平模式
            WriteSync(Hex("00 06 02 01 09")); // 50Hz 上报
            WriteSync(Hex("00 03 08 06 11")); // 读取加速度寄存器
            WriteSync(Hex("00 06 03 00 09")); // 自动模式（开始持续上报）
            WriteSync(Hex("00 06 05 55 60")); // 保存设置
        }

        private void ResetState()
        {
            lock (_lock)
            {
                _rx.Clear();
                _pendingCmd = null;
                _ackEvent.Reset();
                _accIndex = 0;
                _accCount = 0;
                foreach (int[] a in _acc)
                    Array.Clear(a, 0, a.Length);
                _countMap.Clear();
                _lastAccUtc = DateTime.MinValue;
                LastDirection = SensorDirection.Unknown;
                _stateGen++;
            }
        }

        private bool WriteSync(byte[] cmd)
        {
            lock (_lock)
            {
                if (_pendingCmd != null)
                    return false;
                _pendingCmd = cmd;
                _ackEvent.Reset();
            }
            try
            {
                _port.Write(cmd, 0, cmd.Length);
                return _ackEvent.Wait(3000);
            }
            catch (Exception ex)
            {
                Log.Error("串口写入/等待应答异常", ex);
                return false;
            }
            finally
            {
                lock (_lock)
                    _pendingCmd = null;
            }
        }

        private static byte[] Hex(string s)
        {
            s = s.Replace(" ", "");
            byte[] b = new byte[s.Length / 2];
            for (int i = 0; i < b.Length; i++)
                b[i] = Convert.ToByte(s.Substring(i * 2, 2), 16);
            return b;
        }

        private void OnDataReceived(object sender, SerialDataReceivedEventArgs e)
        {
            List<Action> pending = null;
            try
            {
                int n = _port.BytesToRead;
                if (n <= 0)
                    return;
                byte[] buf = new byte[n];
                int read = _port.Read(buf, 0, n);
                if (read <= 0)
                    return;
                lock (_lock)
                {
                    for (int i = 0; i < read; i++)
                        _rx.Add(buf[i]);
                    pending = ProcessBuffer();
                }
            }
            catch (Exception ex)
            {
                Log.Error("串口数据接收异常", ex);
                SetReady(false);
            }

            // 事件统一在锁外触发：避免持有 _lock 时回调 UI，防止阻塞串口接收线程或造成死锁。
            // 若期间发生过 Open/Close（代数变化），说明这些事件已过期，直接丢弃。
            if (pending != null && _pendingGen == _stateGen)
            {
                for (int i = 0; i < pending.Count; i++)
                {
                    try
                    {
                        pending[i]();
                    }
                    catch (Exception ex)
                    {
                        Log.Error("传感器事件回调异常", ex);
                    }
                }
            }
        }

        private void OnErrorReceived(object sender, SerialErrorReceivedEventArgs e)
        {
            Log.Error("串口错误事件（帧错误/溢出等）", null);
            SetReady(false);
        }

        private void OnWatchdogTick(object state)
        {
            bool lost;
            lock (_lock)
            {
                lost = _ready && (DateTime.UtcNow - _lastAccUtc).TotalSeconds >= WatchdogTimeoutSec;
            }
            if (lost)
                SetReady(false);
        }

        private List<Action> ProcessBuffer()
        {
            List<Action> pending = new List<Action>();
            _pendingGen = _stateGen;
            while (_rx.Count >= 5)
            {
                int idx = _rx.IndexOf(0xA4);
                if (idx < 0)
                {
                    _rx.Clear();
                    return pending;
                }
                if (idx > 0)
                    _rx.RemoveRange(0, idx);

                byte func = _rx[1];
                int total;
                if (func == 0x03)
                    total = 5 + _rx[3];
                else if (func == 0x06 || func == 0x86 || func == 0x83)
                    total = 5;
                else
                {
                    _rx.RemoveAt(0);
                    continue;
                }

                if (_rx.Count < total)
                    return pending;

                byte[] frame = _rx.GetRange(0, total).ToArray();
                _rx.RemoveRange(0, total);
                HandleFrame(frame, pending);
            }
            return pending;
        }

        private void HandleFrame(byte[] frame, List<Action> pending)
        {
            if (!Checksum(frame))
                return;
            if (frame[0] != 0xA4)
                return;

            if (HandleWriteFeedback(frame))
                return;

            // 加速度帧：A4 03 08 06 + X/Y/Z 各 2 字节 + 校验和
            if (frame.Length == 11 && frame[1] == 0x03 && frame[2] == 0x08 && frame[3] == 0x06)
                HandleAcc(frame, pending);
        }

        private static bool Checksum(byte[] b)
        {
            if (b.Length < 2)
                return false;
            byte sum = 0;
            for (int i = 0; i < b.Length - 1; i++)
                sum += b[i];
            return sum == b[b.Length - 1];
        }

        private bool HandleWriteFeedback(byte[] frame)
        {
            byte[] pending;
            lock (_lock)
                pending = _pendingCmd;
            if (pending == null)
                return false;

            if (frame[1] == 0x03 || frame[1] == 0x06)
            {
                if (frame[1] == pending[1] && frame[2] == pending[2] && frame[3] == pending[3])
                {
                    _ackEvent.Set();
                    return true;
                }
            }
            else if (frame[1] == 0x86 || frame[1] == 0x83)
            {
                _ackEvent.Set();
                return true;
            }
            return false;
        }

        private void HandleAcc(byte[] frame, List<Action> pending)
        {
            _lastAccUtc = DateTime.UtcNow;
            if (!_ready)
                pending.Add(delegate { RaiseReadyChanged(true); });
            _ready = true;

            int ix = (short)((frame[4] << 8) | frame[5]);
            int iy = (short)((frame[6] << 8) | frame[7]);
            int iz = (short)((frame[8] << 8) | frame[9]);
            ix /= 100;
            iy /= 100;
            iz /= 100;

            if (_accCount < AccWindow)
                _accCount++;
            _accIndex = (_accIndex + 1) % AccWindow;
            _acc[0][_accIndex] = ix;
            _acc[1][_accIndex] = iy;
            _acc[2][_accIndex] = iz;

            int qx = 0, qy = 0;
            if (_accCount > 0)
            {
                long sx = 0, sy = 0;
                for (int i = 0; i < _accCount; i++)
                {
                    sx += _acc[0][i];
                    sy += _acc[1][i];
                }
                qx = (int)Math.Round((sx / (double)_accCount) / 160.0);
                qy = (int)Math.Round((sy / (double)_accCount) / 160.0);
            }

            // 去抖：按「方向类别」计数，同方向连续满 20 帧才触发一次旋转；
            // 方向一变就清空重新计数，避免过渡期抖动反复触发。
            SensorDirection dir = GetDirection(qx, qy);
            int count;
            if (!_countMap.TryGetValue(dir, out count))
            {
                _countMap.Clear();
                _countMap[dir] = 1;
            }
            else
            {
                if (count == 20)
                {
                    LastDirection = dir;
                    if (dir != SensorDirection.Unknown)
                        pending.Add(delegate { RaiseRotated(dir); });
                }
                if (count < 100)
                    _countMap[dir] = count + 1;
            }
        }

        private static SensorDirection GetDirection(int x, int y)
        {
            if (y == 1)
                return SensorDirection.Right;
            if (y == -1)
                return SensorDirection.Left;
            if (x == XUp)
                return SensorDirection.Up;
            if (x == XDown)
                return SensorDirection.Down;
            return SensorDirection.Unknown;
        }

        private void SetReady(bool value)
        {
            bool changed = _ready != value;
            _ready = value;
            if (changed)
                RaiseReadyChanged(value);
        }

        private void RaiseReadyChanged(bool value)
        {
            Action<bool> h = ReadyChanged;
            if (h != null)
                h(value);
        }

        private void RaiseRotated(SensorDirection dir)
        {
            Action<SensorDirection> h = Rotated;
            if (h != null)
                h(dir);
        }

        public void Dispose()
        {
            Close();
            _ackEvent.Dispose();
            _port.Dispose();
        }
    }
}
