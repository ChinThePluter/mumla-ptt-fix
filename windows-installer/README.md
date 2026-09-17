# Mumla POC Installer (Windows GUI)

โปรแกรม GUI สำหรับ Windows ที่ลง **S12 Mumla** ลงวิทยุ Hytera PNC380 (POC) ผ่าน adb
— พอร์ตมาจาก `setup-device.sh` ทั้งหมด ทำงานเหมือนกันทุกขั้นตอน

## ได้ไฟล์ .exe มาจากไหน

Build อัตโนมัติด้วย GitHub Actions (ไม่ต้องมีเครื่อง Windows ตอน build):

1. ไปที่ repo บน GitHub → แท็บ **Actions**
2. เลือก workflow **"Build Windows POC Installer (.exe)"**
3. กด **Run workflow** (หรือมันจะรันเองเมื่อมีการแก้ไฟล์ใน `windows-installer/`)
4. เมื่อรันเสร็จ โหลดไฟล์จาก **Artifacts → `MumlaPOCInstaller-exe`**
   → ได้ `MumlaPOCInstaller.exe`

> adb.exe + DLL ที่จำเป็นถูกฝังอยู่ในตัว .exe แล้ว ไม่ต้องติดตั้ง adb แยก

## การใช้งาน

1. วางไฟล์ **`mumla-foss-debug.apk`** ไว้ใน**โฟลเดอร์เดียวกับ .exe**
   (หรือกดปุ่ม "เลือกไฟล์..." ในโปรแกรมเพื่อชี้ไปที่ APK เอง)
   — APK สร้างจากการ build โปรเจกต์ (`./gradlew :app:assembleFossDebug`)
2. เปิด `MumlaPOCInstaller.exe`
3. เสียบวิทยุผ่าน USB → เปิด **USB debugging** บนเครื่อง → กด **Allow**
   (ครั้งแรกต้องลง **ADB USB driver** ของ Windows ให้เจอเครื่องก่อน)
4. กด **รีเฟรช** ให้ขึ้นชื่ออุปกรณ์
5. ใส่ **เลขเครื่อง** เอง หรือกด **อ่านเลขเดิม** (ดึงจากแอพ S12 เดิมในเครื่อง)
6. ปรับตั้งค่าในแท็บต่างๆ ได้ (ไมค์ / volume / handset / PTT / ตัวเลือกอื่น)
7. กด **ติดตั้งลงเครื่อง** แล้วดู log

## ค่าเริ่มต้น (ตรงกับ setup-device.sh)

| ตั้งค่า | ค่า |
|---|---|
| ไมโครโฟน | ไมค์สื่อสาร (ลดเสียงรบกวน / VOICE_COMMUNICATION) |
| ระดับเสียงไมค์ | 100% |
| PTT keycode | 142 (F12) |
| โหมดโทรศัพท์ (handset) | เปิด |
| บังคับลำโพงนอก | เปิด |
| ซ่อนปุ่ม PTT บนจอ | เปิด |
| ปิด lock screen | เปิด |
| background PTT | เปิด |
| clean reinstall | เปิด |
| จัดการแอพคู่แข่ง | เปิด (restrict + stop) |

## ข้อควรรู้

- **lock screen**: ถ้าเครื่องตั้ง PIN/pattern ไว้ โปรแกรมปิดให้อัตโนมัติไม่ได้
  ต้องปลดเองที่ Settings > Security > Screen lock > None
- **background PTT**: การติดตั้งจะ revoke accessibility เสมอ โปรแกรม rebind ให้แล้ว
  ในขั้นตอนติดตั้ง (toggle + verify)

## รันจากซอร์ส (ไม่ต้องใช้ .exe)

ต้องมี Python 3 + adb บน PATH:

```
python windows-installer/mumla_installer.py
```

## Build .exe เองบนเครื่อง Windows (ถ้าไม่ใช้ Actions)

```
pip install pyinstaller
cd windows-installer
:: วาง adb.exe + AdbWinApi.dll + AdbWinUsbApi.dll ไว้ในโฟลเดอร์ adb\
pyinstaller --onefile --windowed --name MumlaPOCInstaller ^
  --add-binary "adb\adb.exe;." ^
  --add-binary "adb\AdbWinApi.dll;." ^
  --add-binary "adb\AdbWinUsbApi.dll;." ^
  mumla_installer.py
```
