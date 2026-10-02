# loopback_capture.ps1
#
# Captures whatever is playing through the current default Windows audio
# output device (system audio) using WASAPI loopback mode, and writes it
# to a WAV file. This is the same technique OBS/Audacity use for
# "record what you hear" and needs NO Stereo Mix, NO virtual audio
# cable, and NO extra install — it's a documented Win32 API
# (AUDCLNT_STREAMFLAGS_LOOPBACK) that's been in Windows since Vista.
#
# Usage: powershell -ExecutionPolicy Bypass -File loopback_capture.ps1 <output.wav> <stopflag.path> [<readyflag.path>]
# Stops as soon as <stopflag.path> exists on disk, then exits 0.
# If <readyflag.path> is given, that file is created the instant WASAPI
# capture actually starts (after client.Start() succeeds) — callers should
# wait for it before starting a parallel video recording, to keep the two
# in sync (see start_screen_recording() in main.py).

param(
    [Parameter(Mandatory = $true)][string]$OutputWav,
    [Parameter(Mandatory = $true)][string]$StopFlag,
    [Parameter(Mandatory = $false)][string]$ReadyFlag
)

$ErrorActionPreference = "Stop"

Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace LoopbackCap
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        int NotImpl1();
        [PreserveSig]
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig]
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct WAVEFORMATEX
    {
        public short wFormatTag;
        public short nChannels;
        public int nSamplesPerSec;
        public int nAvgBytesPerSec;
        public short nBlockAlign;
        public short wBitsPerSample;
        public short cbSize;
    }

    [Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient
    {
        [PreserveSig]
        int Initialize(int shareMode, int streamFlags, long hnsBufferDuration, long hnsPeriodicity, IntPtr pFormat, IntPtr audioSessionGuid);
        [PreserveSig]
        int GetBufferSize(out uint pNumBufferFrames);
        [PreserveSig]
        int GetStreamLatency(out long phnsLatency);
        [PreserveSig]
        int GetCurrentPadding(out uint pNumPaddingFrames);
        [PreserveSig]
        int IsFormatSupported(int shareMode, IntPtr pFormat, out IntPtr ppClosestMatch);
        [PreserveSig]
        int GetMixFormat(out IntPtr ppDeviceFormat);
        int NotImpl2();
        [PreserveSig]
        int Start();
        [PreserveSig]
        int Stop();
        int NotImpl3();
        int NotImpl4();
        [PreserveSig]
        int GetService(ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
    }

    [Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient
    {
        [PreserveSig]
        int GetBuffer(out IntPtr ppData, out uint pNumFramesToRead, out uint pdwFlags, out long pu64DevicePosition, out long pu64QPCPosition);
        [PreserveSig]
        int ReleaseBuffer(uint numFramesWritten);
        [PreserveSig]
        int GetNextPacketSize(out uint pNumFramesInNextPacket);
    }

    public static class LoopbackRecorder
    {
        const int eRender = 0;
        const int eConsole = 0;
        const int CLSCTX_ALL = 1 | 2 | 4 | 16;
        const int AUDCLNT_SHAREMODE_SHARED = 0;
        const int AUDCLNT_STREAMFLAGS_LOOPBACK = 0x00020000;

        public static void Run(string outputWav, string stopFlagPath, string readyFlagPath)
        {
            var enumerator = (IMMDeviceEnumerator)(object)new MMDeviceEnumeratorComObject();
            IMMDevice device;
            int hr = enumerator.GetDefaultAudioEndpoint(eRender, eConsole, out device);
            if (hr != 0) throw new Exception("GetDefaultAudioEndpoint failed: 0x" + hr.ToString("X"));

            Guid iidAudioClient = typeof(IAudioClient).GUID;
            object clientObj;
            hr = device.Activate(ref iidAudioClient, CLSCTX_ALL, IntPtr.Zero, out clientObj);
            if (hr != 0) throw new Exception("Activate(IAudioClient) failed: 0x" + hr.ToString("X"));
            var client = (IAudioClient)clientObj;

            IntPtr pFormat;
            hr = client.GetMixFormat(out pFormat);
            if (hr != 0) throw new Exception("GetMixFormat failed: 0x" + hr.ToString("X"));
            WAVEFORMATEX fmt = (WAVEFORMATEX)Marshal.PtrToStructure(pFormat, typeof(WAVEFORMATEX));

            // 200ms buffer, hns units (100ns each)
            long bufferDuration = 200 * 10000;
            hr = client.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, bufferDuration, 0, pFormat, IntPtr.Zero);
            if (hr != 0) throw new Exception("Initialize failed: 0x" + hr.ToString("X"));

            Guid iidCapture = typeof(IAudioCaptureClient).GUID;
            object captureObj;
            hr = client.GetService(ref iidCapture, out captureObj);
            if (hr != 0) throw new Exception("GetService(IAudioCaptureClient) failed: 0x" + hr.ToString("X"));
            var capture = (IAudioCaptureClient)captureObj;

            int channels = fmt.nChannels;
            int sampleRate = fmt.nSamplesPerSec;
            int bitsPerSample = fmt.wBitsPerSample;
            int blockAlign = fmt.nBlockAlign;
            bool isFloat = fmt.wFormatTag == 3 /* WAVE_FORMAT_IEEE_FLOAT */ || fmt.wFormatTag == unchecked((short)0xFFFE) /* EXTENSIBLE, assume float, common on Windows */;

            using (var fs = new FileStream(outputWav, FileMode.Create, FileAccess.Write))
            using (var bw = new BinaryWriter(fs))
            {
                // Write a placeholder WAV header (16-bit PCM container regardless
                // of the source format — we convert float32 -> int16 below so any
                // player can open the result without special codecs).
                WriteWavHeaderPlaceholder(bw, channels, sampleRate);

                hr = client.Start();
                if (hr != 0) throw new Exception("Start failed: 0x" + hr.ToString("X"));

                // Signal the caller (Python) that WASAPI capture is ACTUALLY
                // running now, not just that the process was launched. The
                // C# JIT/Add-Type compile + COM setup above can take anywhere
                // from ~50ms (warm, cached assembly) to 1-2s (cold, first run
                // ever) — without this signal the video recorder was started
                // blindly right after Popen(), so audio would start noticeably
                // late relative to video. The caller waits on this file
                // (with a timeout fallback) before starting the video capture.
                if (!string.IsNullOrEmpty(readyFlagPath))
                {
                    try { File.WriteAllText(readyFlagPath, "1"); } catch { }
                }

                long totalDataBytes = 0;
                int silenceSpins = 0;

                while (!File.Exists(stopFlagPath))
                {
                    uint packetSize;
                    capture.GetNextPacketSize(out packetSize);
                    if (packetSize == 0)
                    {
                        Thread.Sleep(10);
                        silenceSpins++;
                        continue;
                    }

                    IntPtr pData;
                    uint numFrames, flags;
                    long devPos, qpcPos;
                    hr = capture.GetBuffer(out pData, out numFrames, out flags, out devPos, out qpcPos);
                    if (hr != 0) break;

                    if (numFrames > 0)
                    {
                        bool silent = (flags & 0x2) != 0; // AUDCLNT_BUFFERFLAGS_SILENT
                        byte[] pcm16 = ConvertToInt16(pData, numFrames, channels, bitsPerSample, isFloat, silent);
                        bw.Write(pcm16);
                        totalDataBytes += pcm16.Length;
                    }

                    capture.ReleaseBuffer(numFrames);
                }

                client.Stop();
                PatchWavHeader(bw, channels, sampleRate, totalDataBytes);
            }
        }

        static byte[] ConvertToInt16(IntPtr pData, uint numFrames, int channels, int bitsPerSample, bool isFloat, bool silent)
        {
            int samples = (int)numFrames * channels;
            byte[] outBytes = new byte[samples * 2];
            if (silent)
            {
                return outBytes; // already zeroed = silence
            }
            if (isFloat && bitsPerSample == 32)
            {
                float[] src = new float[samples];
                Marshal.Copy(pData, src, 0, samples);
                for (int i = 0; i < samples; i++)
                {
                    float v = src[i];
                    if (v > 1f) v = 1f;
                    if (v < -1f) v = -1f;
                    short s = (short)(v * short.MaxValue);
                    outBytes[i * 2] = (byte)(s & 0xFF);
                    outBytes[i * 2 + 1] = (byte)((s >> 8) & 0xFF);
                }
            }
            else if (bitsPerSample == 16)
            {
                Marshal.Copy(pData, outBytes, 0, outBytes.Length);
            }
            else
            {
                // Unexpected format — leave silence rather than write garbage noise.
            }
            return outBytes;
        }

        static void WriteWavHeaderPlaceholder(BinaryWriter bw, int channels, int sampleRate)
        {
            int bitsPerSample = 16;
            int byteRate = sampleRate * channels * bitsPerSample / 8;
            short blockAlign = (short)(channels * bitsPerSample / 8);

            bw.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
            bw.Write((int)0); // placeholder for total size
            bw.Write(System.Text.Encoding.ASCII.GetBytes("WAVE"));
            bw.Write(System.Text.Encoding.ASCII.GetBytes("fmt "));
            bw.Write((int)16);
            bw.Write((short)1); // PCM
            bw.Write((short)channels);
            bw.Write((int)sampleRate);
            bw.Write((int)byteRate);
            bw.Write(blockAlign);
            bw.Write((short)bitsPerSample);
            bw.Write(System.Text.Encoding.ASCII.GetBytes("data"));
            bw.Write((int)0); // placeholder for data size
        }

        static void PatchWavHeader(BinaryWriter bw, int channels, int sampleRate, long dataBytes)
        {
            bw.Flush();
            var fs = (FileStream)bw.BaseStream;
            long riffSize = 36 + dataBytes;
            fs.Seek(4, SeekOrigin.Begin);
            bw.Write((int)riffSize);
            fs.Seek(40, SeekOrigin.Begin);
            bw.Write((int)dataBytes);
            fs.Seek(0, SeekOrigin.End);
        }
    }
}
"@

try {
    [LoopbackCap.LoopbackRecorder]::Run($OutputWav, $StopFlag, $ReadyFlag)
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
