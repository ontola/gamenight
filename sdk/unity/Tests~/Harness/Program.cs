// Orb Rush without Unity: the same rules and GameNight calls as the Unity
// demo, in a console loop at 60 frames a second. Tests start it the way
// GameNight does (scripts/test-unity-sdk.py, gamenight-certify).
//
//   orb-rush-headless                  wait for GameNight (GAMENIGHT=1 ...)
//   orb-rush-headless --sim 4000 --seed 1   bots play; check the rules, print a state hash
using System;
using System.Diagnostics;
using System.Threading;
using GameNightSdk;
using OrbRush;

static class Program
{
    static int Main(string[] args)
    {
        var sim = 0;
        var seed = 0;
        for (var i = 0; i + 1 < args.Length; i++)
        {
            if (args[i] == "--sim") sim = int.Parse(args[i + 1]);
            if (args[i] == "--seed") seed = int.Parse(args[i + 1]);
        }
        var trace = Environment.GetEnvironmentVariable("GAME_TRACE") == "1";
        if (sim > 0) return Simulate(sim, seed);

        using var client = new GameNightClient("unity-demo");
        client.DeviceInfo["cpu"] = "headless";
        client.DeviceInfo["os"] = Environment.OSVersion.Platform.ToString();
        var game = new OrbRushGame(client, null, seed, trace);
        if (!client.LaunchedByHost)
        {
            Console.Error.WriteLine("Not launched by GameNight; use --sim to play with bots.");
            return 2;
        }
        Console.Out.Flush();
        var clock = Stopwatch.StartNew();
        var last = clock.Elapsed.TotalSeconds;
        while (!client.ShouldQuit)
        {
            client.Pump();
            var now = clock.Elapsed.TotalSeconds;
            game.Tick((float)Math.Min(now - last, 0.05));
            last = now;
            Console.Out.Flush();
            Thread.Sleep(16);
        }
        if (trace) Console.WriteLine("host gone, quitting");
        return 0;
    }

    static int Simulate(int frames, int seed)
    {
        using var client = new GameNightClient("unity-demo", environment: _ => null);
        var game = new OrbRushGame(client, null, seed == 0 ? 1 : seed);
        game.StartStandalone(0, 4);
        for (var i = 0; i < frames; i++) game.Tick(1f / 60f);
        Console.WriteLine("sim: " + string.Join(", ", game.Stats) + " hash " + game.StateHash());
        foreach (var stat in game.Stats)
        {
            if (stat.Value > 0) continue;
            Console.Error.WriteLine("sim: never happened: " + stat.Key);
            return 1;
        }
        Console.WriteLine("sim: ok");
        return 0;
    }
}
