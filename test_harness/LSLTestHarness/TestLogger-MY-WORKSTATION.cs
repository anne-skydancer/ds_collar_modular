using System;

namespace LSLTestHarness
{
    internal static class TestLogger
    {
        private static bool? _enabled;
        private static bool Enabled
        {
            get
            {
                if (_enabled.HasValue) return _enabled.Value;
                try
                {
                    var v = Environment.GetEnvironmentVariable("YENGINE_DEBUG");
                    if (string.IsNullOrEmpty(v)) { _enabled = false; return _enabled.Value; }
                    v = v.Trim();
                    _enabled = (v == "1" || v.Equals("TRUE", StringComparison.OrdinalIgnoreCase));
                    return _enabled.Value;
                }
                catch { _enabled = false; return _enabled.Value; }
            }
        }

        public static void D(string message)
        {
            if (!Enabled) return;
            Console.WriteLine(message);
        }
    }
}
