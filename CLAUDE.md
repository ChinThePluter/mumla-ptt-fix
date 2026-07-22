บริบท:
ผมใช้แอป Mumla (Mumble client บน Android, GPLv3) บนอุปกรณ์ Hytera POC radio 
(Android-based PTT device) โคลนโค้ดจาก https://github.com/quite/mumla 
(mirror ของ https://gitlab.com/quite/mumla)

ปัญหา:
ปุ่ม PTT ฮาร์ดแวร์ของเครื่องใช้งานได้ปกติเมื่อแอป Mumla อยู่ foreground 
(หน้าจอเปิด) แต่พอจอดับ กดปุ่ม PTT แล้วไม่มีอะไรเกิดขึ้น คาดว่าสาเหตุคือ
แอปรับ key event ผ่าน onKeyDown/onKeyUp ของ Activity เท่านั้น ซึ่งจะไม่ทำงาน
เมื่อ Activity ไม่ได้อยู่ foreground หรือจอดับ

เป้าหมาย:
ให้ปุ่ม PTT ฮาร์ดแวร์ยังคงสั่งเปิด/ปิดไมโครโฟนของ Mumla ได้ แม้จอดับหรือ
แอปอยู่เบื้องหลัง โดยไม่กระทบการทำงานปกติของแอปตอนจอเปิด

งานที่อยากให้ช่วย:
1. สำรวจโค้ดในโปรเจกต์นี้ (และ library Humla ที่เป็น backend - 
   https://github.com/quite/humla) เพื่อหาว่าตอนนี้ปุ่ม PTT ถูก handle 
   ที่ไฟล์ไหน ผ่านกลไกอะไร (key event, service, ฯลฯ)
2. เสนอแนวทางแก้ที่เหมาะสมที่สุด โดยพิจารณาตัวเลือกเหล่านี้:
   a) เพิ่ม AccessibilityService ที่ตั้ง android:canRequestFilterKeyEvents="true" 
      เพื่อดักจับ key event แบบ global แม้จอดับ (มีตัวอย่าง reference 
      implementation ที่ทำแบบนี้กับอุปกรณ์ Hytera โดยเฉพาะที่ 
      https://github.com/chepil/HyTalkPTT - ลองดูโครงสร้างเป็นแนวทางได้)
   b) เปลี่ยน service ที่ดูแล mic ให้เป็น Foreground Service พร้อม 
      partial wake lock เพื่อให้ยังประมวลผล key event ได้ตอนจอดับ
   c) ถ้า Hytera มี broadcast intent เฉพาะสำหรับปุ่ม PTT (เช่น 
      android.intent.action.PTT_DOWN/PTT_UP) ให้เพิ่ม BroadcastReceiver 
      รับสัญญาณนี้แล้วเชื่อมเข้ากับฟังก์ชัน toggle mic ที่มีอยู่แล้วในแอป
3. เขียนโค้ดแก้ไข พร้อมอธิบายว่าแก้ไฟล์ไหน เพิ่มอะไร เพราะอะไร
4. บอกขั้นตอนที่ผมต้องทำเพิ่มเอง เช่น เปิดสิทธิ์ Accessibility Service 
   ในตั้งค่าเครื่อง หรือหา keycode ที่แท้จริงของปุ่ม PTT บนเครื่องผม 
   (ผมยังไม่ทราบ keycode ที่แน่นอน อาจต้อง log key event ทั้งหมดออกมาดูก่อน)
5. Build APK ทดสอบให้ ถ้าเป็นไปได้ในสภาพแวดล้อมนี้

ข้อจำกัด:
- อยากให้เป็น minimal, clean patch ที่ยังอัปเดตตาม upstream ได้ง่ายในอนาคต 
  (แยกโค้ดที่เพิ่มให้ชัดเจน ไม่ปนกับ logic เดิมของแอป)
- ใช้เพื่อส่วนตัวบนอุปกรณ์ของผมเอง ไม่ได้เผยแพร่ต่อ
