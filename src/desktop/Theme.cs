using System.Windows.Media;

namespace NetCrate
{
    internal static class Theme
    {
        public const string Background = "#070D17";
        public const string Surface = "#0C1524";
        public const string Raised = "#111F32";
        public const string Border = "#22334A";
        public const string Text = "#EDF4FF";
        public const string Muted = "#9BAFC9";
        public const string Accent = "#62AAFF";
        public const string Primary = "#1E64C8";
        public const string Hover = "#183151";
        public const string Selected = "#132C4A";
        public const string Warning = "#F3C17B";

        public static SolidColorBrush Brush(string value)
        {
            SolidColorBrush brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(value));
            brush.Freeze();
            return brush;
        }
    }
}
