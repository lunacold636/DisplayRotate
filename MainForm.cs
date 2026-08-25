using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DisplayRotate
{
    internal class ComboItem
    {
        public string Port;
        public string Display;

        public ComboItem(string port, string display)
        {
            Port = port;
            Display = display;
        }

        public override string ToString()
        {
            return Display;
        }
    }

    internal class SerialPortInfo
    {
        public string PortName;
        public string DisplayName;

        public SerialPortInfo(string port, string display)
        {
            PortName = port;
            DisplayName = display;
        }
    }

    internal class MainForm : Form
    {
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValueName = "DisplayRotate";
        private const int HTCAPTION = 2;
        private const int WM_NCLBUTTONDOWN = 0xA1;
        private const int ReconnectBaseMs = 2000; // 自动重连起始间隔
        private const int ReconnectMaxMs = 60000; // 自动重连最大间隔（退避封顶）
        private const int RotateCooldownMs = 2000; // 旋转后抑制窗口：防止过渡期抖动触发反向旋转/振荡
        private const int PollIntervalMs = 500;    // 状态轮询周期：漏一次事件也能在下一轮自愈
        // 实测基准：显示器横屏 0° 时传感器方向（SensorProbe 实测 X=16 Y=-162 Z=6，稳定 7s+）
        // 映射循环序已验证：Down→Rotate270（实测）、Up→Rotate90、Right→Rotate180、Left→Default
        private const SensorDirection LandscapeDir = SensorDirection.Left;
        private const string AppVersion = "v1.0.3"; // 发布新版本时同步更新（窗口标题栏/托盘文本显示）

        private readonly Gy25t _sensor = new Gy25t();
        private readonly Dictionary<SensorDirection, DisplayRotation> _rotateMap =
            new Dictionary<SensorDirection, DisplayRotation>();
        private readonly object _rotateLock = new object();
        private readonly object _sensorOpLock = new object(); // 串口 Open/Close/Init 互斥，避免手动关闭与自动重连竞态
        private readonly System.Windows.Forms.Timer _openTimer = new System.Windows.Forms.Timer();
        private readonly System.Windows.Forms.Timer _reconnectTimer = new System.Windows.Forms.Timer();
        private readonly System.Windows.Forms.Timer _pollTimer = new System.Windows.Forms.Timer();
        private bool _reconnectEnabled;
        private int _reconnectAttempts;
        private bool _reconnecting;
        private bool _autoAttempting;
        private volatile bool _manualClosePending;
        private bool _startupInitDone;
        private readonly double _scale;
        private readonly Image _imgGreen;
        private readonly Image _imgRed;
        private readonly Image _imgGreen32;
        private readonly Image _imgRed32;

        private DisplayRotation _lastApplied = DisplayRotation.Default; // 当前已应用的屏幕旋转（轮询对比用）
        private DateTime _lastRotateUtc = DateTime.MinValue; // 最近一次实际调用旋转的时间（UTC），仅用于冷却
        private bool _autostart;
        private bool _suppressFirstShow;
        private bool _quitting;
        private string _selectedMonitor = "";

        private Panel _titleBar;
        private PictureBox _picStatus;
        private Label _lblStatus;
        private Label _lblDirection;
        private ComboBox _cmbPort;
        private ComboBox _cmbMonitor;
        private Button _btnOpen;
        private CheckBox _chkAutoStart;
        private NotifyIcon _tray;

        [DllImport("user32.dll")]
        private static extern bool DestroyIcon(IntPtr hIcon);

        [DllImport("user32.dll")]
        private static extern uint GetDpiForSystem();

        [DllImport("user32.dll")]
        private static extern bool ReleaseCapture();

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

        private static readonly Color WinBorderColor = Color.FromArgb(0xC9, 0xCD, 0xD4);

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ClassStyle |= 0x00020000; // CS_DROPSHADOW：无边框窗口补投影，白底下也有清晰轮廓
                return cp;
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            using (Pen p = new Pen(WinBorderColor))
                e.Graphics.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
        }

        public MainForm(bool autostart)
        {
            _autostart = autostart;
            _suppressFirstShow = autostart;

            uint dpi = 0;
            try
            {
                dpi = GetDpiForSystem();
            }
            catch
            {
                // 旧系统不支持该 API 时按 96 DPI 处理
                dpi = 0;
            }
            _scale = (dpi == 0 ? 96.0 : dpi) / 96.0;

            _imgGreen = LoadImage("DisplayRotate.logoGreen.png");
            _imgRed = LoadImage("DisplayRotate.logoRed.png");
            _imgGreen32 = _imgGreen == null ? null : IconFactory.Render(_imgGreen, 32);
            _imgRed32 = _imgRed == null ? null : IconFactory.Render(_imgRed, 32);
            if (_imgGreen != null)
                Icon = IconFactory.MultiSizeIcon(_imgGreen, new int[] { 16, 24, 32, 48, 64 });

            Text = "DisplayRotate";
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(0xF4, 0xF6, 0xF9);
            Font = new Font("Microsoft YaHei UI", 9F);
            ClientSize = new Size(S(360), S(342));
            DoubleBuffered = true;
            MaximizeBox = false;
            MinimizeBox = false;

            _openTimer.Interval = 20000; // 覆盖 Init 最长耗时（6 条指令 × 3 秒 = 18 秒）
            _openTimer.Tick += OnOpenTimeout;
            _reconnectTimer.Tick += OnReconnectTick;
            _pollTimer.Interval = PollIntervalMs;
            _pollTimer.Tick += OnPollTick;
            _pollTimer.Start();

            BuildTray();
            BuildUi();

            _sensor.ReadyChanged += OnReadyChanged;
            Load += OnLoad;

            // 写死基准（不再运行时校准）：以实测横屏方向建立固定映射
            RebuildMap(LandscapeDir, DisplayRotation.Default);

            if (autostart)
            {
                // 自启时不显示窗体：主动创建句柄，保证后台线程 BeginInvoke 可用；
                // 并绕过 Load 事件（首次显示被 SetVisibleCore 抑制时不会触发），直接进入静默自动连接。
                IntPtr handle = Handle;
                _startupInitDone = true;
                InitStartup(true);
            }
        }

        private static Image LoadImage(string name)
        {
            try
            {
                using (System.IO.Stream s = System.Reflection.Assembly.GetExecutingAssembly()
                    .GetManifestResourceStream(name))
                {
                    if (s == null)
                        return null;
                    using (Image tmp = Image.FromStream(s))
                        return new Bitmap(tmp);
                }
            }
            catch
            {
                return null;
            }
        }

        private int S(int v)
        {
            return (int)Math.Round(v * _scale);
        }

        private void BuildUi()
        {
            int w = ClientSize.Width;

            _titleBar = new Panel { Dock = DockStyle.Top, Height = S(52), BackColor = Color.White };
            _titleBar.Paint += delegate(object s, PaintEventArgs e)
            {
                using (Pen p = new Pen(Color.FromArgb(0xE3, 0xE7, 0xEE)))
                    e.Graphics.DrawLine(p, 0, _titleBar.Height - 1, _titleBar.Width, _titleBar.Height - 1); // 标题栏下分隔线
                using (Pen p2 = new Pen(WinBorderColor))
                    e.Graphics.DrawLine(p2, 0, 0, _titleBar.Width, 0); // 窗口上缘细边框
            };

            Label title = new Label
            {
                Text = "DisplayRotate",
                Font = new Font("Microsoft YaHei UI", 10.5F, FontStyle.Bold),
                ForeColor = Color.FromArgb(0x1C, 0x21, 0x28),
                Location = new Point(S(16), S(15)),
                AutoSize = true,
                BackColor = Color.White
            };
            _titleBar.Controls.Add(title);
            // 版本号：便于判断当前运行的是哪个版本
            Size titleSize = TextRenderer.MeasureText("DisplayRotate", title.Font);
            Label lblVersion = new Label
            {
                Text = AppVersion,
                Font = new Font("Microsoft YaHei UI", 8F),
                ForeColor = Color.FromArgb(0x9A, 0xA2, 0xAE),
                Location = new Point(S(16) + titleSize.Width + S(8), S(20)),
                AutoSize = true,
                BackColor = Color.White
            };
            _titleBar.Controls.Add(lblVersion);

            Button btnHide = MakeTitleButton("\u2014", w - S(78), S(12)); // —
            btnHide.Click += delegate { HideToTray(); };
            Button btnClose = MakeTitleButton("\u00D7", w - S(40), S(12)); // ×
            btnClose.Click += delegate { HideToTray(); };
            _titleBar.Controls.Add(btnHide);
            _titleBar.Controls.Add(btnClose);

            _picStatus = new PictureBox
            {
                Size = new Size(S(18), S(18)),
                Location = new Point(w - S(178), S(17)),
                SizeMode = PictureBoxSizeMode.Zoom,
                Image = _imgRed,
                BackColor = Color.White
            };
            _titleBar.Controls.Add(_picStatus);

            _lblStatus = new Label
            {
                Text = "未连接",
                ForeColor = Color.FromArgb(0x5B, 0x66, 0x75),
                Location = new Point(w - S(154), S(17)),
                AutoSize = true,
                BackColor = Color.White
            };
            _titleBar.Controls.Add(_lblStatus);

            Controls.Add(_titleBar);
            EnableTitleBarDrag();

            // 卡片一：设备
            RoundedPanel card1 = MakeCard(S(60), S(108));
            AddLabel(card1, "串口", new Point(S(18), S(12)));
            _cmbPort = new ComboBox
            {
                DropDownStyle = ComboBoxStyle.DropDownList,
                FlatStyle = FlatStyle.Flat,
                Location = new Point(S(18), S(32)),
                Size = new Size(S(190), S(26))
            };
            card1.Controls.Add(_cmbPort);

            Button btnScan = MakeButton("扫描", new Point(S(216), S(31)), new Size(S(96), S(28)), false);
            btnScan.Click += delegate { RefreshPorts(); };
            card1.Controls.Add(btnScan);

            _btnOpen = MakeButton("打开", new Point(S(18), S(68)), new Size(S(294), S(32)), true);
            _btnOpen.Click += OnOpenClicked;
            card1.Controls.Add(_btnOpen);

            // 卡片二：旋转
            RoundedPanel card2 = MakeCard(S(180), S(96));
            AddLabel(card2, "监视器", new Point(S(18), S(12)));
            _cmbMonitor = new ComboBox
            {
                DropDownStyle = ComboBoxStyle.DropDownList,
                FlatStyle = FlatStyle.Flat,
                Location = new Point(S(18), S(32)),
                Size = new Size(S(294), S(26))
            };
            _cmbMonitor.SelectedIndexChanged += delegate { UpdateSelectedMonitor(); };
            card2.Controls.Add(_cmbMonitor);

            _lblDirection = new Label
            {
                Text = "传感器方向：--",
                ForeColor = Color.FromArgb(0x8A, 0x92, 0x9E),
                Location = new Point(S(18), S(68)),
                AutoSize = true,
                BackColor = Color.White
            };
            card2.Controls.Add(_lblDirection);

            // 卡片三：开机自启动
            RoundedPanel card3 = MakeCard(S(288), S(40));
            _chkAutoStart = new CheckBox
            {
                Text = "开机自启动",
                Location = new Point(S(16), S(10)),
                AutoSize = true,
                ForeColor = Color.FromArgb(0x2C, 0x33, 0x3B),
                BackColor = Color.White,
                Cursor = Cursors.Hand
            };
            _chkAutoStart.CheckedChanged += delegate { SetAutoStart(_chkAutoStart.Checked); };
            _chkAutoStart.Checked = GetAutoStart();
            card3.Controls.Add(_chkAutoStart);
        }

        private RoundedPanel MakeCard(int y, int h)
        {
            RoundedPanel c = new RoundedPanel
            {
                Location = new Point(S(14), y),
                Size = new Size(ClientSize.Width - S(28), h)
            };
            Controls.Add(c);
            return c;
        }

        private void AddLabel(Control parent, string text, Point loc)
        {
            Label l = new Label
            {
                Text = text,
                Location = loc,
                AutoSize = true,
                BackColor = Color.White,
                ForeColor = Color.FromArgb(0x8A, 0x92, 0x9E)
            };
            parent.Controls.Add(l);
        }

        private Button MakeTitleButton(string text, int x, int y)
        {
            Button b = new Button
            {
                Text = text,
                Location = new Point(x, y),
                Size = new Size(S(30), S(28)),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.White,
                ForeColor = Color.FromArgb(0x5B, 0x66, 0x75),
                Font = new Font("Microsoft YaHei UI", 11F),
                Cursor = Cursors.Hand
            };
            b.FlatAppearance.BorderSize = 0;
            b.FlatAppearance.MouseOverBackColor = Color.FromArgb(0xEE, 0xF1, 0xF6);
            return b;
        }

        private Button MakeButton(string text, Point loc, Size size, bool primary)
        {
            Button b = new Button
            {
                Text = text,
                Location = loc,
                Size = size,
                FlatStyle = FlatStyle.Flat,
                Cursor = Cursors.Hand,
                Font = new Font("Microsoft YaHei UI", 9F)
            };
            b.FlatAppearance.BorderSize = 1;
            b.FlatAppearance.BorderColor = Color.FromArgb(0xD6, 0xDB, 0xE3);
            if (primary)
            {
                b.BackColor = Color.FromArgb(0x3B, 0x82, 0xF6);
                b.ForeColor = Color.White;
                b.FlatAppearance.MouseOverBackColor = Color.FromArgb(0x2F, 0x6F, 0xE0);
            }
            else
            {
                b.BackColor = Color.White;
                b.ForeColor = Color.FromArgb(0x2C, 0x33, 0x3B);
                b.FlatAppearance.MouseOverBackColor = Color.FromArgb(0xF1, 0xF5, 0xFD);
            }
            return b;
        }

        private void BuildTray()
        {
            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add("显示", null, delegate
            {
                Show();
                WindowState = FormWindowState.Normal;
                Activate();
            });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("退出", null, delegate
            {
                _quitting = true;
                _tray.Visible = false;
                Application.Exit(); // 资源释放统一在 OnFormClosing 完成
            });

            _tray = new NotifyIcon
            {
                ContextMenuStrip = menu,
                Visible = true,
                Text = "DisplayRotate " + AppVersion + " - 未连接"
            };
            _tray.DoubleClick += delegate
            {
                Show();
                Activate();
            };
            SetTrayIcon(false);
        }

        private void SetTrayIcon(bool connected)
        {
            Image img = connected ? _imgGreen : _imgRed;
            if (img == null)
                return;
            try
            {
                Icon ic = IconFactory.MultiSizeIcon(img, new int[] { 16, 24, 32 });
                Icon old = _tray.Icon;
                _tray.Icon = ic;
                if (old != null)
                {
                    DestroyIcon(old.Handle);
                    old.Dispose();
                }
            }
            catch (Exception ex)
            {
                Log.Error("更新托盘图标失败", ex);
            }
        }

        private void OnLoad(object sender, EventArgs e)
        {
            // 自启模式下 InitStartup 已在构造函数执行（首次显示被抑制时 Load 不触发）
            if (_startupInitDone)
                return;
            _startupInitDone = true;
            InitStartup(_autostart);
        }

        /// <summary>启动初始化：扫描端口/显示器，并按模式进入自动连接流程。</summary>
        private void InitStartup(bool autostart)
        {
            RefreshPorts();
            RefreshMonitors();
            _chkAutoStart.Checked = GetAutoStart();

            string savedPort = SettingsStore.Port;
            if (!string.IsNullOrEmpty(savedPort))
                SelectPort(savedPort);

            if (autostart)
            {
                // 静默自启：不弹窗，直接进入退避重连，设备就绪后自动连接
                SetStatus(false);
                StartReconnect();
                return;
            }

            if (!string.IsNullOrEmpty(savedPort) && PortExists(savedPort))
            {
                _btnOpen.Enabled = false;
                _btnOpen.Text = "连接中...";
                _openTimer.Start();
                Task.Run(delegate
                {
                    bool ok = false;
                    lock (_sensorOpLock)
                    {
                        ok = ConnectTo(savedPort);
                    }
                    BeginInvoke((Action)delegate
                    {
                        _btnOpen.Enabled = true;
                        if (!ok)
                        {
                            _openTimer.Stop();
                            SetStatus(false);
                            StartReconnect();
                        }
                    });
                });
            }
            else
            {
                StartReconnect();
            }
        }

        private static bool GetAutoStart()
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKey))
            {
                return key != null && key.GetValue(RunValueName) != null;
            }
        }

        private static void SetAutoStart(bool enabled)
        {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (key == null)
                    return;
                if (enabled)
                {
                    string target = "\"" + Application.ExecutablePath + "\" --autostart";
                    object existing = key.GetValue(RunValueName);
                    string existingStr = existing as string;
                    if (existingStr == null || !string.Equals(existingStr, target, StringComparison.OrdinalIgnoreCase))
                        key.SetValue(RunValueName, target);
                }
                else
                {
                    key.DeleteValue(RunValueName, false);
                }
            }
        }

        private void OnOpenClicked(object sender, EventArgs e)
        {
            if (_sensor.IsOpen)
            {
                StopReconnect();
                _autoAttempting = false;
                _openTimer.Stop();
                _manualClosePending = true;
                lock (_sensorOpLock)
                {
                    try { _sensor.Close(); }
                    catch (Exception ex) { Log.Error("手动关闭串口", ex); }
                }
                _manualClosePending = false;
                SetStatus(false);
                return;
            }

            string port = GetSelectedPort();
            if (string.IsNullOrEmpty(port))
            {
                MessageBox.Show(this, "没有可用的串口设备！", "DisplayRotate",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            StopReconnect();
            _manualClosePending = false;
            _autoAttempting = false;
            _openTimer.Stop();
            _btnOpen.Enabled = false;
            _btnOpen.Text = "连接中...";
            _openTimer.Start();

            Task.Run(delegate
            {
                bool ok = false;
                lock (_sensorOpLock)
                {
                    if (!_manualClosePending)
                        ok = ConnectTo(port);
                }
                BeginInvoke((Action)delegate
                {
                    _btnOpen.Enabled = true;
                    if (!ok)
                    {
                        _openTimer.Stop();
                        SetStatus(false);
                        MessageBox.Show(this, "打开串口失败：" + port, "DisplayRotate",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
                        // 失败后转为静默退避重连，设备就绪后自动恢复
                        if (!_reconnectEnabled)
                            StartReconnect();
                    }
                });
            });
        }

        private bool ConnectTo(string port)
        {
            _sensor.SetPortName(port);
            bool ok = _sensor.Open();
            if (ok)
                _sensor.Init();
            return ok;
        }

        private void OnOpenTimeout(object sender, EventArgs e)
        {
            _openTimer.Stop();
            if (_autoAttempting)
            {
                // 自动重连尝试超时：静默关闭并安排下一次（不弹窗）
                _autoAttempting = false;
                lock (_sensorOpLock)
                {
                    try { _sensor.Close(); }
                    catch (Exception ex) { Log.Error("自动重连超时关闭串口", ex); }
                }
                _reconnecting = false;
                ScheduleNextReconnect();
                return;
            }
            lock (_sensorOpLock)
            {
                try { _sensor.Close(); }
                catch (Exception ex) { Log.Error("手动连接超时关闭串口", ex); }
            }
            SetStatus(false);
            MessageBox.Show(this, "打开设备失败：传感器无响应！", "DisplayRotate",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        /// <summary>开启自动重连（指数退避，连上后自动停止）。必须在 UI 线程调用。</summary>
        private void StartReconnect()
        {
            _reconnectEnabled = true;
            _reconnectAttempts = 0;
            _reconnectTimer.Interval = ReconnectBaseMs;
            _reconnectTimer.Start();
        }

        /// <summary>停止自动重连。必须在 UI 线程调用。</summary>
        private void StopReconnect()
        {
            _reconnectEnabled = false;
            _reconnectTimer.Stop();
        }

        private void OnReconnectTick(object sender, EventArgs e)
        {
            if (!_reconnectEnabled || _reconnecting)
                return;
            // 传感器仍在正常上报：不重连
            if (_sensor.IsOpen && _sensor.IsReady)
                return;

            string port = FindSensorPort();
            if (string.IsNullOrEmpty(port))
            {
                ScheduleNextReconnect();
                return;
            }

            _reconnecting = true;
            _autoAttempting = true;
            _openTimer.Start();
            Task.Run(delegate
            {
                bool ok = false;
                try
                {
                    lock (_sensorOpLock)
                    {
                        // 用户在重连过程中手动关闭：放弃本次尝试
                        if (_manualClosePending)
                        {
                            ok = false;
                        }
                        else
                        {
                            // 先清理可能残留的旧串口句柄（静默拔线时端口对象可能处于坏状态）
                            _sensor.Close();
                            ok = ConnectTo(port);
                        }
                    }
                }
                catch (Exception ex)
                {
                    ok = false;
                    Log.Error("自动重连异常", ex);
                }
                try
                {
                    BeginInvoke((Action)delegate
                    {
                        _reconnecting = false;
                        bool wasAuto = _autoAttempting;
                        _autoAttempting = false;
                        if (wasAuto)
                            _openTimer.Stop();
                        if (!ok && _reconnectEnabled)
                            ScheduleNextReconnect();
                    });
                }
                catch (Exception ex)
                {
                    _reconnecting = false;
                    Log.Error("重连结果回调失败", ex);
                }
            });
        }

        private void ScheduleNextReconnect()
        {
            if (!_reconnectEnabled)
                return;
            _reconnectAttempts++;
            int ms = ReconnectBaseMs;
            for (int i = 1; i < _reconnectAttempts; i++)
            {
                if (ms >= ReconnectMaxMs)
                    break;
                ms = Math.Min(ms * 2, ReconnectMaxMs);
            }
            _reconnectTimer.Interval = ms;
            _reconnectTimer.Start();
        }

        /// <summary>按 保存的端口 → 保存的设备描述 → 唯一端口 的顺序定位传感器串口。</summary>
        private string FindSensorPort()
        {
            RefreshPorts();

            string saved = SettingsStore.Port;
            if (!string.IsNullOrEmpty(saved) && PortExists(saved))
                return saved;

            string desc = SettingsStore.Description;
            if (!string.IsNullOrEmpty(desc))
            {
                for (int i = 0; i < _cmbPort.Items.Count; i++)
                {
                    ComboItem item = _cmbPort.Items[i] as ComboItem;
                    if (item != null && item.Display.IndexOf(desc, StringComparison.OrdinalIgnoreCase) >= 0)
                        return item.Port;
                }
            }

            if (_cmbPort.Items.Count == 1)
            {
                ComboItem only = _cmbPort.Items[0] as ComboItem;
                if (only != null)
                    return only.Port;
            }
            return null;
        }

        /// <summary>取串口对应的设备描述（去掉端口号部分），用于 COM 号变化后重新识别设备。</summary>
        private string GetPortDescription(string port)
        {
            for (int i = 0; i < _cmbPort.Items.Count; i++)
            {
                ComboItem item = _cmbPort.Items[i] as ComboItem;
                if (item != null && item.Port == port)
                {
                    string d = item.Display;
                    if (d.Length > port.Length)
                        return d.Substring(port.Length).Trim();
                    return d;
                }
            }
            return "";
        }

        private void OnReadyChanged(bool ready)
        {
            if (_quitting) return; // 退出中：忽略已入队的回调
            if (InvokeRequired)
            {
                BeginInvoke((Action)delegate { OnReadyChanged(ready); });
                return;
            }

            if (ready)
            {
                _openTimer.Stop();
                StopReconnect();
                _reconnectAttempts = 0;
                // 以真实屏幕方向作为"已应用"初值，避免启动即误转；若与传感器不符，轮询会自动纠正
                ReSyncApplied();
                SettingsStore.Port = _sensor.PortName;
                SettingsStore.Description = GetPortDescription(_sensor.PortName);
            }
            else
            {
                if (!_manualClosePending && !_reconnecting)
                    StartReconnect();
            }
            SetStatus(ready);
        }

        /// <summary>状态驱动轮询：定期按传感器当前方向校正屏幕旋转。漏一次事件也能自愈；冷却只跳过不吞。</summary>
        private void OnPollTick(object sender, EventArgs e)
        {
            if (_quitting) return; // 退出中：不再旋转屏幕
            if (!_sensor.IsOpen || !_sensor.IsReady)
                return;

            string monitor = _selectedMonitor;
            if (string.IsNullOrEmpty(monitor))
                return;

            SensorDirection dir = _sensor.LastDirection;
            if (dir == SensorDirection.Unknown)
                return; // 传感器未稳定/正在过渡：保持现状，等待去抖完成

            DisplayRotation expected;
            lock (_rotateLock)
            {
                if (!_rotateMap.TryGetValue(dir, out expected))
                    return;
            }

            if (expected == _lastApplied)
            {
                UpdateDirectionLabel(dir);
                return;
            }

            // 冷却期：跳过本次但不吞掉状态差，下一轮轮询自动重试（自愈）
            DateTime now = DateTime.UtcNow;
            if ((now - _lastRotateUtc).TotalMilliseconds < RotateCooldownMs)
            {
                UpdateDirectionLabel(dir);
                return;
            }

            try
            {
                if (DisplayRotator.Rotate(monitor, expected))
                {
                    _lastApplied = expected;
                    _lastRotateUtc = now;
                }
                // 失败不更新 _lastApplied：下一轮轮询会重试
            }
            catch (Exception ex)
            {
                Log.Error("屏幕旋转异常", ex);
            }
            UpdateDirectionLabel(dir);
        }

        /// <summary>以真实屏幕方向刷新"已应用"状态（连接成功 / 切换监视器 / 手动重新校准）。</summary>
        private void ReSyncApplied()
        {
            if (string.IsNullOrEmpty(_selectedMonitor))
            {
                _lastApplied = DisplayRotation.Default;
                return;
            }
            try
            {
                _lastApplied = DisplayRotator.GetRotation(_selectedMonitor);
            }
            catch (Exception ex)
            {
                Log.Error("读取屏幕方向失败", ex);
            }
        }

        /// <summary>按循环序建立固定映射。启动时以实测横屏基准调用一次，之后不再运行时校准。</summary>
        private void RebuildMap(SensorDirection r1, DisplayRotation r2)
        {
            SensorDirection[] dirs = new SensorDirection[]
            {
                SensorDirection.Up, SensorDirection.Right,
                SensorDirection.Down, SensorDirection.Left
            };
            DisplayRotation[] rots = new DisplayRotation[]
            {
                DisplayRotation.Default, DisplayRotation.Rotate90,
                DisplayRotation.Rotate180, DisplayRotation.Rotate270
            };
            _rotateMap.Clear();
            int i1 = Array.IndexOf(dirs, r1);
            int i2 = Array.IndexOf(rots, r2);
            if (i1 < 0 || i2 < 0)
                return;
            for (int i = 0; i < 4; i++)
                _rotateMap[dirs[(i1 + i) % 4]] = rots[(i2 + i) % 4];
        }

        private void UpdateDirectionLabel(SensorDirection dir)
        {
            string text;
            switch (dir)
            {
                case SensorDirection.Up: text = "传感器方向：上"; break;
                case SensorDirection.Right: text = "传感器方向：右"; break;
                case SensorDirection.Down: text = "传感器方向：下"; break;
                case SensorDirection.Left: text = "传感器方向：左"; break;
                default: text = "传感器方向：--"; break;
            }
            if (InvokeRequired)
            {
                BeginInvoke((Action)delegate { _lblDirection.Text = text; });
                return;
            }
            _lblDirection.Text = text;
        }

        private void SetStatus(bool connected)
        {
            if (_quitting) return; // 退出中：忽略已入队的回调
            if (InvokeRequired)
            {
                BeginInvoke((Action)delegate { SetStatus(connected); });
                return;
            }

            _picStatus.Image = connected ? _imgGreen32 : _imgRed32;
            _lblStatus.Text = connected ? "已连接" : "未连接";
            _tray.Text = connected ? "DisplayRotate " + AppVersion + " - 已连接" : "DisplayRotate " + AppVersion + " - 未连接";
            _btnOpen.Text = connected ? "关闭" : "打开";

            if (connected)
            {
                _btnOpen.BackColor = Color.FromArgb(0xE5, 0xE7, 0xEB);
                _btnOpen.ForeColor = Color.FromArgb(0x37, 0x41, 0x51);
                _btnOpen.FlatAppearance.MouseOverBackColor = Color.FromArgb(0xDC, 0xDF, 0xE4);
            }
            else
            {
                _btnOpen.BackColor = Color.FromArgb(0x3B, 0x82, 0xF6);
                _btnOpen.ForeColor = Color.White;
                _btnOpen.FlatAppearance.MouseOverBackColor = Color.FromArgb(0x2F, 0x6F, 0xE0);
            }
            SetTrayIcon(connected);
        }

        private void RefreshPorts()
        {
            string prev = GetSelectedPort();
            _cmbPort.Items.Clear();
            foreach (SerialPortInfo p in EnumeratePorts())
                _cmbPort.Items.Add(new ComboItem(p.PortName, p.DisplayName));
            if (prev != null)
                SelectPort(prev);
            else if (_cmbPort.Items.Count > 0)
                _cmbPort.SelectedIndex = 0;
        }

        private void RefreshMonitors()
        {
            string prev = _selectedMonitor;
            _cmbMonitor.Items.Clear();
            List<string> monitors = DisplayRotator.ActiveMonitors();
            for (int i = 0; i < monitors.Count; i++)
                _cmbMonitor.Items.Add(new ComboItem(monitors[i], "显示器 " + (i + 1)));

            if (prev != null)
                SelectMonitor(prev);
            else
            {
                string saved = SettingsStore.Monitor;
                if (!string.IsNullOrEmpty(saved))
                    SelectMonitor(saved);
            }
            if (_cmbMonitor.SelectedIndex < 0 && _cmbMonitor.Items.Count > 0)
                _cmbMonitor.SelectedIndex = 0;
            UpdateSelectedMonitor();
        }

        private void UpdateSelectedMonitor()
        {
            ComboItem item = _cmbMonitor.SelectedItem as ComboItem;
            _selectedMonitor = item == null ? "" : item.Port;
            if (!string.IsNullOrEmpty(_selectedMonitor))
            {
                SettingsStore.Monitor = _selectedMonitor;
                ReSyncApplied(); // 切换监视器后以真实方向为基准，避免基于旧屏幕误转
            }
        }

        private string GetSelectedPort()
        {
            ComboItem item = _cmbPort.SelectedItem as ComboItem;
            return item == null ? null : item.Port;
        }

        private void SelectPort(string port)
        {
            int i = GetPortIndex(port);
            if (i >= 0)
                _cmbPort.SelectedIndex = i;
        }

        private int GetPortIndex(string port)
        {
            for (int i = 0; i < _cmbPort.Items.Count; i++)
            {
                ComboItem item = _cmbPort.Items[i] as ComboItem;
                if (item != null && item.Port == port)
                    return i;
            }
            return -1;
        }

        private bool PortExists(string port)
        {
            return GetPortIndex(port) >= 0;
        }

        private void SelectMonitor(string monitor)
        {
            for (int i = 0; i < _cmbMonitor.Items.Count; i++)
            {
                ComboItem item = _cmbMonitor.Items[i] as ComboItem;
                if (item != null && item.Port == monitor)
                {
                    _cmbMonitor.SelectedIndex = i;
                    return;
                }
            }
        }

        private static List<SerialPortInfo> EnumeratePorts()
        {
            List<SerialPortInfo> list = new List<SerialPortInfo>();
            try
            {
                using (System.Management.ManagementObjectSearcher searcher =
                    new System.Management.ManagementObjectSearcher(
                        "SELECT Name FROM Win32_PnPEntity WHERE Name LIKE '%(COM%'"))
                {
                    using (System.Management.ManagementObjectCollection items = searcher.Get())
                    {
                        foreach (System.Management.ManagementObject o in items)
                        {
                            using (o)
                            {
                                string name = o["Name"] as string;
                                if (string.IsNullOrEmpty(name))
                                    continue;
                                int i = name.LastIndexOf("(COM");
                                if (i < 0)
                                    continue;
                                int j = name.IndexOf(')', i + 4);
                                if (j <= i)
                                    continue;
                                string port = name.Substring(i + 1, j - i - 1);
                                string display = port + "  " + name.Substring(0, i).TrimEnd(' ');
                                list.Add(new SerialPortInfo(port, display));
                            }
                        }
                    }
                }
            }
            catch
            {
            }
            list.Sort(delegate(SerialPortInfo a, SerialPortInfo b)
            {
                return string.Compare(a.PortName, b.PortName, StringComparison.Ordinal);
            });
            return list;
        }

        private void HideToTray()
        {
            Hide();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            // 系统关机/注销/任务管理器结束/Application.Exit 时放行，避免阻止关机；
            // 其余（点 ×、Alt+F4 等）一律最小化到托盘
            if (!_quitting)
            {
                if (e.CloseReason == CloseReason.WindowsShutDown ||
                    e.CloseReason == CloseReason.TaskManagerClosing ||
                    e.CloseReason == CloseReason.ApplicationExitCall)
                {
                    _quitting = true;
                }
                else
                {
                    e.Cancel = true;
                    Hide();
                    base.OnFormClosing(e);
                    return;
                }
            }

            if (_quitting)
            {
                _openTimer.Stop();
                _reconnectTimer.Stop();
                _pollTimer.Stop();
                // 先摘掉事件订阅：Dispose 串口会同步触发 ReadyChanged(false)，避免回调访问已置空的 _tray
                _sensor.ReadyChanged -= OnReadyChanged;
                if (_tray != null)
                {
                    _tray.Visible = false;
                    _tray.Dispose();
                    _tray = null;
                }
                lock (_sensorOpLock)
                {
                    try { _sensor.Dispose(); }
                    catch (Exception ex) { Log.Error("退出时释放串口", ex); }
                }
                DisposeImages();
            }

            base.OnFormClosing(e);
        }

        private void DisposeImages()
        {
            try
            {
                if (_imgGreen32 != null) { _imgGreen32.Dispose(); }
                if (_imgRed32 != null) { _imgRed32.Dispose(); }
                if (_imgGreen != null) { _imgGreen.Dispose(); }
                if (_imgRed != null) { _imgRed.Dispose(); }
                if (Icon != null)
                {
                    Icon old = Icon;
                    Icon = null;
                    old.Dispose();
                }
            }
            catch (Exception ex)
            {
                Log.Error("释放图片资源失败", ex);
            }
        }

        // 开机自启（--autostart）时拦截首次显示，只保留托盘图标，实现无感启动
        protected override void SetVisibleCore(bool value)
        {
            if (_suppressFirstShow && value)
            {
                _suppressFirstShow = false;
                value = false;
            }
            base.SetVisibleCore(value);
        }

        private void EnableTitleBarDrag()
        {
            HookDrag(_titleBar);
        }

        private void HookDrag(Control c)
        {
            c.MouseDown += OnTitleBarDragStart;
            foreach (Control child in c.Controls)
            {
                if (child is Button)
                    continue;
                HookDrag(child);
            }
        }

        private void OnTitleBarDragStart(object sender, MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left)
                return;
            int x = Cursor.Position.X;
            int y = Cursor.Position.Y;
            ReleaseCapture();
            SendMessage(Handle, WM_NCLBUTTONDOWN, new IntPtr(HTCAPTION),
                new IntPtr((y << 16) | (x & 0xFFFF)));
        }

    }
}
