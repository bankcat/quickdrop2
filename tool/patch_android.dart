import 'dart:io';

const marker = '// quickdrop-compileSdk-fix';

const kotlinFix = r'''
subprojects {
    if (!project.state.executed) {
        project.afterEvaluate {
            val appExt = rootProject.findProject(":app")
                ?.extensions?.findByName("android") as? com.android.build.gradle.BaseExtension
            val myExt = project.extensions.findByName("android") as? com.android.build.gradle.BaseExtension
            val sdk = appExt?.compileSdkVersion
            if (myExt != null && sdk != null) {
                myExt.compileSdkVersion(sdk)
            }
        }
    }
}

subprojects {
    tasks.configureEach {
        if (name.contains("lintVital")) enabled = false
    }
}
''';

const groovyFix = r'''
subprojects {
    if (!project.state.executed) {
        project.afterEvaluate {
            def app = rootProject.findProject(":app")
            if (project.hasProperty("android") && app != null && app.hasProperty("android")) {
                project.android.compileSdkVersion(app.android.compileSdkVersion)
            }
        }
    }
}

subprojects {
    tasks.configureEach { t ->
        if (t.name.contains("lintVital")) t.enabled = false
    }
}
''';

void main() {
  final f = File('android/app/src/main/AndroidManifest.xml');
  var s = f.readAsStringSync();
  if (!s.contains('usesCleartextTraffic')) {
    s = s.replaceFirst('<application', '''<uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.CAMERA"/>
    <application
        android:usesCleartextTraffic="true"''');
    f.writeAsStringSync(s);
    print('AndroidManifest patched');
  }

  final kts = File('android/build.gradle.kts');
  final groovy = File('android/build.gradle');
  if (kts.existsSync()) {
    final t = kts.readAsStringSync();
    if (!t.contains(marker)) {
      kts.writeAsStringSync('$t\n$marker\n$kotlinFix');
      print('build.gradle.kts patched');
    }
  } else if (groovy.existsSync()) {
    final t = groovy.readAsStringSync();
    if (!t.contains(marker)) {
      groovy.writeAsStringSync('$t\n$marker\n$groovyFix');
      print('build.gradle patched');
    }
  } else {
    print('WARNING: android/build.gradle(.kts) not found');
  }
}
