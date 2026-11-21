# QuickDrop — ส่งไฟล์/รูป/ข้อความ มือถือ ↔ คอมพิวเตอร์

โค้ดเดียว (Flutter) สร้างได้ทั้ง **QuickDrop.exe (Windows)** และ **app-release.apk (Android)**

## วิธีได้ไฟล์ .exe และ .apk

### วิธี A — ให้ GitHub สร้างให้ (ไม่ต้องลงอะไรในเครื่อง)
1. สร้าง repo ใหม่บน GitHub แล้วอัปโหลดโฟลเดอร์นี้ทั้งหมด
2. แท็บ **Actions** → workflow "Build exe + apk" จะรันเอง (หรือกด Run workflow)
3. รอ ~10 นาที → เลื่อนลงล่างสุดของหน้า run → ดาวน์โหลด
   - `QuickDrop-apk` → app-release.apk
   - `QuickDrop-windows-exe` → zip (แตกแล้วเปิด `quickdrop.exe`)

### วิธี B — Build เองในเครื่อง
ติดตั้ง Flutter SDK (https://flutter.dev) แล้ว:
```bash
flutter create --platforms=android,windows --org com.quickdrop --project-name quickdrop .
dart run tool/patch_android.dart
flutter pub get
flutter build apk --release       # -> build/app/outputs/flutter-apk/app-release.apk
flutter build windows --release   # -> build/windows/x64/runner/Release/quickdrop.exe (ต้องมี Visual Studio + Desktop C++)
```

## วิธีใช้
1. เปิดโปรแกรมทั้งสองเครื่อง ต่อ Wi-Fi/LAN วงเดียวกัน
2. เครื่องหนึ่งดู Address (เช่น `1AB-C2DE`) หรือ QR
3. อีกเครื่องกรอก Address (หรือกดไอคอนสแกน QR บนมือถือ) → **เชื่อมต่อ** → เลือกไฟล์/รูป/วางข้อความ → ส่ง
4. ฝั่งรับเห็นในกล่องรับ แยกแท็บ ไฟล์ / รูปภาพ / ข้อความ โดยไม่ต้องกด Accept (ตั้งค่าปิดได้)

ครั้งแรกบน Windows จะมีหน้าต่าง Firewall ให้กด **Allow** (ต้องใช้รับข้อมูล)

## สถาปัตยกรรม
- ทุกเครื่องรัน HTTP server พอร์ต 53317 (`GET /info`, `POST /send`)
- Address = IPv4 แปลงเป็นเลขฐาน 36 (7 ตัว) → ถอดกลับเป็น IP ได้เลย ไม่ต้องมีเซิร์ฟเวอร์กลาง
- ส่งไฟล์แบบ stream (ไฟล์ใหญ่ไม่กิน RAM) พร้อม progress

## สถานะฟีเจอร์
| ฟีเจอร์ | สถานะ |
|---|---|
| PC↔PC, มือถือ↔PC ใน LAN/Wi-Fi เดียวกัน | ✅ |
| Address + QR | ✅ |
| ส่งไฟล์/รูป/วิดีโอ/ถ่ายรูป/วางข้อความ + progress + ประวัติ | ✅ |
| รับอัตโนมัติ + เลือกโฟลเดอร์ + 4 แท็บ + Copy + เปิดลิงก์ | ✅ |
| PIN, ลบ/ล้างประวัติ, ส่งหลายไฟล์, Drag & Drop | ✅ |
| ส่งข้ามเครือข่าย (Relay/Signaling) | ⏳ Phase 2 — ต้องมีเซิร์ฟเวอร์กลาง |
| รับขณะแอปมือถืออยู่เบื้องหลัง (Foreground service) | ⏳ Phase 2 |
| iOS / macOS | โค้ดรองรับ แต่ต้อง build บน Mac + ตั้งค่า Info.plist |
