import 'dart:io';

void main() {
  final f = File('android/app/src/main/AndroidManifest.xml');
  var s = f.readAsStringSync();
  if (s.contains('usesCleartextTraffic')) return;
  s = s.replaceFirst('<application', '''<uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.CAMERA"/>
    <application
        android:usesCleartextTraffic="true"''');
  f.writeAsStringSync(s);
  print('AndroidManifest patched');
}
