// Injected by mindattic-agent-standard/shared/publish-app.ps1 for one batch build, then deleted. Builds an Android APK
// (ARM64, plus x86_64 under IL2CPP so the Android Emulator runs it natively) and writes <apk>.json with the app's
// identity for play.json. Every player setting it touches is put back before the editor exits.
#if UNITY_EDITOR
using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;

public static class MindAtticPublish
{
    static string Arg(string name)
    {
        var a = Environment.GetCommandLineArgs();
        int i = Array.IndexOf(a, name);
        return i >= 0 && i + 1 < a.Length ? a[i + 1] : null;
    }

    public static void BuildApk()
    {
        string output = Arg("-mindatticOut");
        bool dev = Environment.GetCommandLineArgs().Contains("-mindatticDev");
        int code = 1;
        var target = NamedBuildTarget.Android;
        var archs = PlayerSettings.Android.targetArchitectures;
        var backend = PlayerSettings.GetScriptingBackend(target);
        bool bundle = EditorUserBuildSettings.buildAppBundle;
        try
        {
            if (string.IsNullOrEmpty(output)) throw new Exception("-mindatticOut <path.apk> is required");
            EditorUserBuildSettings.SwitchActiveBuildTarget(BuildTargetGroup.Android, BuildTarget.Android);
            EditorUserBuildSettings.buildAppBundle = false;
            PlayerSettings.Android.targetArchitectures = backend == ScriptingImplementation.IL2CPP
                ? AndroidArchitecture.ARM64 | AndroidArchitecture.X86_64
                : archs;

            var scenes = EditorBuildSettings.scenes.Where(s => s.enabled).Select(s => s.path).ToArray();
            if (scenes.Length == 0) throw new Exception("No enabled scenes in Build Settings");
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output)));
            var report = BuildPipeline.BuildPlayer(new BuildPlayerOptions
            {
                scenes = scenes,
                locationPathName = output,
                target = BuildTarget.Android,
                targetGroup = BuildTargetGroup.Android,
                options = dev ? BuildOptions.Development : BuildOptions.None,
            });
            Debug.Log($"MindAtticPublish: {report.summary.result}, {report.summary.totalSize / 1048576} MB, {report.summary.totalErrors} errors");
            if (report.summary.result == BuildResult.Succeeded)
            {
                var o = PlayerSettings.defaultInterfaceOrientation;
                bool landscape = o == UIOrientation.LandscapeLeft || o == UIOrientation.LandscapeRight;
                File.WriteAllText(output + ".json", JsonUtility.ToJson(new Info
                {
                    name = PlayerSettings.productName,
                    package = PlayerSettings.GetApplicationIdentifier(target),
                    minSdk = (int)PlayerSettings.Android.minSdkVersion,
                    orientation = landscape ? "landscape" : "portrait",
                    version = PlayerSettings.bundleVersion,
                }, true));
                code = 0;
            }
        }
        catch (Exception e) { Debug.LogError("MindAtticPublish: " + e); }
        finally
        {
            PlayerSettings.Android.targetArchitectures = archs;
            PlayerSettings.SetScriptingBackend(target, backend);
            EditorUserBuildSettings.buildAppBundle = bundle;
        }
        EditorApplication.Exit(code);
    }

    [Serializable]
    class Info { public string name; public string package; public int minSdk; public string orientation; public string version; }
}
#endif
