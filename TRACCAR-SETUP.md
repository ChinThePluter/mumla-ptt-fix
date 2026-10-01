# GPS tracking ด้วย Traccar (สำหรับ S12 Mumla)

วิทยุ PNC380 มี GPS/GLONASS/BeiDou อยู่แล้ว แอป S12 Mumla มีตัวส่งพิกัดไป
**Traccar** server แบบประหยัดแบต (ดู `TraccarReporter.java`): จะขอ GPS fix
**ครั้งเดียวทุกๆ ช่วงเวลา** (ค่าเริ่มต้น 60 วิ = 1 นาที) แล้วปิด GPS ระหว่างรอบ
ไม่เปิดค้างตลอด — เบาแบตมาก

- ส่งด้วย **OsmAnd protocol** (HTTP ไปพอร์ต 5055 ของ Traccar)
- **device ID = เลขเครื่อง** (username ที่ตั้งไว้ เช่น 065)
- ทำงานเฉพาะตอน**เชื่อมต่อ Mumble อยู่** และเปิดสวิตช์ในตั้งค่าเท่านั้น (opt-in)

## 1) ติดตั้ง Traccar server

วิธีที่ง่ายสุดคือ Docker (รันบนเครื่อง server ของคุณ เช่นตัวเดียวกับ Mumble 174.138.20.49):

```bash
docker run -d --name traccar --restart unless-stopped \
  -p 8082:8082 \
  -p 5055:5055 \
  traccar/traccar:latest
```

- **8082** = หน้าเว็บ/แผนที่ (เปิดด้วย browser: `http://<server-ip>:8082`)
- **5055** = พอร์ตรับพิกัดจากวิทยุ (OsmAnd protocol)

เปิด firewall ให้ทั้งสองพอร์ต (ตัวอย่าง ufw):

```bash
sudo ufw allow 8082/tcp
sudo ufw allow 5055/tcp
```

> ไม่ใช้ Docker ก็ได้ — โหลด installer จาก https://www.traccar.org/download/ (Linux/Windows)
> พอร์ต OsmAnd 5055 เป็นค่า default เหมือนกัน

## 2) สร้างบัญชี + เพิ่มอุปกรณ์

1. เปิด `http://<server-ip>:8082` → สมัคร admin ครั้งแรก
2. เมนู **Devices → +** เพิ่มอุปกรณ์ทีละเครื่อง
   - **Name**: อะไรก็ได้ (เช่น "วิทยุ 065")
   - **Identifier**: ใส่ **เลขเครื่องให้ตรงกับ username** (เช่น `065`)
     ← สำคัญมาก ต้องตรงกับ device ID ที่แอปส่งมา ไม่งั้นแผนที่ไม่ขึ้น

ทำครบทุกเครื่อง แล้วตำแหน่งจะเด้งขึ้นแผนที่เองเมื่อวิทยุเริ่มส่ง

## 3) เปิดใช้งานบนวิทยุ

### ผ่าน setup-device.sh
```bash
GPS_TRACKING=true TRACCAR_HOST=174.138.20.49 TRACCAR_PORT=5055 GPS_INTERVAL=60 \
  SERVER_USERNAME=065 ./setup-device.sh
```
สคริปต์จะ: เขียน prefs (gps_tracking/traccar_host/port/interval), grant สิทธิ์
Location, และเปิด GPS ของเครื่องให้อัตโนมัติ

### ผ่าน Windows installer (GUI)
แท็บ **GPS / Traccar** → ติ๊ก "ส่งพิกัด GPS ไป Traccar" → ใส่ host/port/วินาที

### ตั้งเองในแอป
⚙ ตั้งค่า → **ตำแหน่ง (GPS)** → เปิด "ส่งพิกัด GPS ไป Traccar" + ใส่ server

## หมายเหตุ

- **ความถี่**: ต่ำสุด/ค่าเริ่มต้น 60 วิ (1 นาที); ตั้งมากขึ้นได้ถ้าอยากประหยัดแบต
  ถ้าต้องการตามรถ/คนที่เคลื่อนเร็วค่อยลดลง (แต่กินแบตมากขึ้น)
- ต้องอยู่ใน**ที่โล่ง**ช่วงแรกเพื่อจับดาวเทียมครั้งแรก (ถ้าในตึกอาจไม่ได้ fix)
- ถ้าเครื่องมี PIN ล็อก location อาจถูกปิด — setup-device.sh เปิด location_mode ให้แล้ว
- พิกัดส่งผ่าน **HTTP** (ไม่เข้ารหัส) — ถ้าต้องการความปลอดภัยให้วาง Traccar
  หลัง reverse proxy TLS หรือใช้ VPN
