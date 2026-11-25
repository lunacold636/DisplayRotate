using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

namespace DisplayRotate
{
    /// <summary>
    /// 多尺寸高清图标生成：把源图按目标尺寸单独高质量渲染，
    /// 打包成标准 .ico（含 16/24/32/48/64 等尺寸），避免小尺寸缩小发糊。
    /// </summary>
    internal static class IconFactory
    {
        public static Image Render(Image src, int size)
        {
            Bitmap bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.DrawImage(src, 0, 0, size, size);
            }
            return bmp;
        }

        public static Icon MultiSizeIcon(Image src, int[] sizes)
        {
            byte[][] datas = new byte[sizes.Length][];
            for (int i = 0; i < sizes.Length; i++)
            {
                using (Bitmap b = (Bitmap)Render(src, sizes[i]))
                using (MemoryStream png = new MemoryStream())
                {
                    b.Save(png, ImageFormat.Png);
                    datas[i] = png.ToArray();
                }
            }

            MemoryStream ms = new MemoryStream();
            BinaryWriter w = new BinaryWriter(ms);
            // ICONDIR
            w.Write((short)0);
            w.Write((short)1);
            w.Write((short)sizes.Length);

            int offset = 6 + 16 * sizes.Length;
            for (int i = 0; i < sizes.Length; i++)
            {
                int s = sizes[i];
                w.Write((byte)(s >= 256 ? 0 : s)); // width
                w.Write((byte)(s >= 256 ? 0 : s)); // height
                w.Write((byte)0);                  // palette
                w.Write((byte)0);                  // reserved
                w.Write((short)1);                 // planes
                w.Write((short)32);                // bpp
                w.Write(datas[i].Length);
                w.Write(offset);
                offset += datas[i].Length;
            }
            for (int i = 0; i < datas.Length; i++)
                w.Write(datas[i]);
            w.Flush();
            ms.Position = 0;
            // Icon 持有流数据，ms/w 保持存活以防句柄失效
            return new Icon(ms);
        }
    }
}
