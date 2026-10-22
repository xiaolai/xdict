// The IPC conformance gate: the real service, started by the production client over the production pipes, answers the
// contract's handshake and its typed refusals. `plan-windows-v1` WI-3; WI-4 adds conformance/'s fixtures through the
// service's dictionary operations.
using XDict.Client;
using XDict.Contract;
using System.Runtime.InteropServices;

namespace XDict.Conformance;

public static class Program
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteFile(IntPtr handle, byte[] buffer, uint count, out uint written, IntPtr overlapped);

    public static int Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--outside-handle")
        {
            // Knowing a handle's numeric value grants no access in another process. The positive control explicitly
            // duplicates the endpoint into this process, which is exactly the authority the production spawn grants.
            ulong handle = ulong.Parse(Console.ReadLine()!, System.Globalization.CultureInfo.InvariantCulture);
            byte[] body = System.Text.Encoding.UTF8.GetBytes("{\"contract\":1,\"id\":18446744073709551615,\"op\":\"versions\",\"files\":[],\"operation\":null}");
            byte[] frame = BitConverter.GetBytes((uint)body.Length).Concat(new byte[] { 1 }).Concat(body).ToArray();
            return WriteFile(new IntPtr(unchecked((long)handle)), frame, (uint)frame.Length, out uint written, IntPtr.Zero)
                && written == frame.Length ? 1 : 0;
        }
        string? service = null, generated = null, expected = null;
        for (int i = 0; i + 1 < args.Length; i++)
        {
            if (args[i] == "--service") service = args[i + 1];
            else if (args[i] == "--generated") generated = args[i + 1];
            else if (args[i] == "--expected") expected = args[i + 1];
        }
        service ??= Environment.GetEnvironmentVariable("XDICT_SERVICE");
        if (service is null || !File.Exists(service))
        {
            Console.Error.WriteLine("--service or XDICT_SERVICE must name the built xdict-service.exe");
            return 2;
        }

        using var client = new ServiceClient(service, new ServiceClientOptions { Storage = "conformance-" + Guid.NewGuid().ToString("N") });
        int failures = 0;

        void Check(string name, Func<object?> action)
        {
            try
            {
                action();
                Console.WriteLine("ok   " + name);
            }
            catch (Exception error)
            {
                failures++;
                Console.WriteLine("FAIL " + name + ": " + error);
            }
        }

        Versions? versions = null;
        Reply? mismatch = null;
        Reply? unknown = null;

        Check("the handshake answers through the pipe", () => versions = client.Handshake());
        Check("the core speaks protocol 1", () => Equal(1u, versions!.Protocol, "protocol"));
        Check("the core names its version", () =>
        {
            if (string.IsNullOrWhiteSpace(versions!.Core)) throw new InvalidOperationException("the core version is empty");
            return null;
        });
        Check("the index format is a known version", () => AtLeast(1u, versions!.IndexFormat, "index format"));
        Check("normalization is a known version", () => AtLeast(1u, versions!.Normalization, "normalization"));
        Check("a contract other than 1 is answered contractMismatch", () => mismatch = client.CallWithContract(999, "versions", null));
        Check("the mismatch names both contracts", () =>
        {
            Json(mismatch!, "error");
            Equal("contractMismatch", mismatch!.Error!.Value.GetProperty("type").GetString()!, "error type");
            Equal(999u, mismatch.Error.Value.GetProperty("contract").GetUInt32(), "the client's contract");
            Equal(Wire.Version, mismatch.Error.Value.GetProperty("service").GetUInt32(), "the service's contract");
            return null;
        });
        Check("the reply echoes the request id", () =>
            Equal(client.LastRequestId, mismatch!.Id, "reply id"));
        Check("the service answers again after a mismatch", () => client.Handshake());
        Check("an unknown operation is a typed malformed", () => unknown = client.Call("surelyNotAnOperation", null));
        Check("the refusal names the operation", () =>
        {
            Json(unknown!, "error");
            Equal("malformed", unknown!.Error!.Value.GetProperty("type").GetString()!, "error type");
            if (!unknown.Error.Value.GetProperty("detail").GetString()!.Contains("surelyNotAnOperation"))
                throw new InvalidOperationException("the detail does not name the operation");
            return null;
        });

        if (generated is not null && expected is not null)
        {
            Check("the tiny fixture answers as expected", () =>
            {
                Fixtures.Tiny(client, generated, expected);
                return null;
            });
            Check("every matrix variant answers as expected", () =>
            {
                Fixtures.Matrix(client, generated, expected);
                return null;
            });
        }

        Console.WriteLine(failures == 0 ? "conformance: pass" : $"conformance: {failures} failed");
        return failures == 0 ? 0 : 1;
    }

    private static object? Equal<T>(T expected, T actual, string what)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"{what}: expected {expected}, got {actual}");
        return null;
    }

    private static object? AtLeast(uint floor, uint actual, string what)
    {
        if (actual < floor) throw new InvalidOperationException($"{what}: {actual} is below {floor}");
        return null;
    }

    private static void Json(Reply reply, string what)
    {
        if (reply.Error is null) throw new InvalidOperationException($"the {what} is not an error: {reply.Ok}");
    }
}
