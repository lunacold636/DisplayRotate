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

        private readonly Gy25t _sensor = new Gy25t();
        private readonly Dictionary<SensorDirection, DisplayRotation> _rotateMap =
            new Dictionary<SensorDirection, DisplayRotation>();
        private readonly object _rotateLock = new object();
        private readonly System.Windows.Forms.Timer _openTimer = new System.Windows.Forms.Timer();
        private readonly double _scale;
        private readonly Image _imgGreen;
        private readonly Image _imgRed;
        private readonly Image _imgGreen32;
        private readonly Image _imgRed32;

        private bool _firstRotation = true;
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

        public MainForm(bool autostart)
        {
            _autostart = autostart;
            _suppressFirstShow = autostart;

            uint dpi = GetDpiForSystem();
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

            _openTimer.Interval = 10000;
            _openTimer.Tick += OnOpenTimeout;

            BuildTray();
            BuildUi();

            _sensor.ReadyChanged += OnReadyChanged;
            _sensor.Rotated += OnSensorRotated;
            Load += OnLoad;
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
                    e.Graphics.DrawLine(p, 0, _titleBar.Height - 1, _titleBar.Width, _titleBar.Height - 1);
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
                _sensor.Dispose();
                Application.Exit();
            });

            _tray = new NotifyIcon
            {
                ContextMenuStrip = menu,
                Visible = true,
                Text = "DisplayRotate - 未连接"
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
            catch
            {
            }
        }

        private void OnLoad(object sender, EventArgs e)
        {
            RefreshPorts();
            RefreshMonitors();
            _chkAutoStart.Checked = GetAutoStart();

            string savedPort = SettingsStore.Port;
            if (!string.IsNullOrEmpty(savedPort))
                SelectPort(savedPort);

            if (!string.IsNullOrEmpty(savedPort) && PortExists(savedPort))
            {
                _btnOpen.Enabled = false;
                _btnOpen.Text = "连接中...";
                _openTimer.Start();
                Task.Run(delegate
                {
                    bool ok = ConnectTo(savedPort);
                    BeginInvoke((Action)delegate
                    {
                        _btnOpen.Enabled = true;
                        if (!ok)
                        {
                            _openTimer.Stop();
                            SetStatus(false);
                        }
                    });
                });
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
                    key.SetValue(RunValueName, "\"" + Application.ExecutablePath + "\" --autostart");
                else
                    key.DeleteValue(RunValueName, false);
            }
        }

        private void OnOpenClicked(object sender, EventArgs e)
        {
            if (_sensor.IsOpen)
            {
                _sensor.Close();
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

            _btnOpen.Enabled = false;
            _btnOpen.Text = "连接中...";
            _openTimer.Start();

            Task.Run(delegate
            {
                bool ok = ConnectTo(port);
                BeginInvoke((Action)delegate
                {
                    _btnOpen.Enabled = true;
                    if (!ok)
                    {
                        _openTimer.Stop();
                        SetStatus(false);
                        MessageBox.Show(this, "打开串口失败：" + port, "DisplayRotate",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
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
            _sensor.Close();
            SetStatus(false);
            MessageBox.Show(this, "打开设备失败：传感器无响应！", "DisplayRotate",
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        private void OnReadyChanged(bool ready)
        {
            if (ready)
            {
                _openTimer.Stop();
                SettingsStore.Port = _sensor.PortName;
            }
            else
            {
                _firstRotation = true;
            }
            SetStatus(ready);
        }

        private void OnSensorRotated(SensorDirection dir)
        {
            string monitor = _selectedMonitor;
            if (string.IsNullOrEmpty(monitor))
            {
                UpdateDirectionLabel(dir);
                return;
            }

            if (_firstRotation)
            {
                lock (_rotateLock)
                {
                    DisplayRotation r2 = DisplayRotator.GetRotation(monitor);
                    RebuildMap(dir, r2);
                    _firstRotation = false;
                }
            }
            else
            {
                DisplayRotation rr;
                lock (_rotateLock)
                {
                    if (!_rotateMap.TryGetValue(dir, out rr))
                    {
                        UpdateDirectionLabel(dir);
                        return;
                    }
                }
                DisplayRotator.Rotate(monitor, rr);
            }
            UpdateDirectionLabel(dir);
        }

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
            if (InvokeRequired)
            {
                BeginInvoke((Action)delegate { SetStatus(connected); });
                return;
            }

            _picStatus.Image = connected ? _imgGreen32 : _imgRed32;
            _lblStatus.Text = connected ? "已连接" : "未连接";
            _tray.Text = connected ? "DisplayRotate - 已连接" : "DisplayRotate - 未连接";
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
                SettingsStore.Monitor = _selectedMonitor;
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
            if (!_quitting)
            {
                e.Cancel = true;
                Hide();
                base.OnFormClosing(e);
                return;
            }
            base.OnFormClosing(e);
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
