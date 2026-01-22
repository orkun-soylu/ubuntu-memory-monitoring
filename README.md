# Memory Monitor for Linux

Ubuntu/Debian sistemlerde memory leak, cache buildup, session birikimi ve genel memory sorunlarını tespit etmek için bash tabanlı monitoring scripti.

## Özellikler

- **Memory Leak Tespiti** - Process bazlı memory artışını izler, uzun süre çalışan processlerdeki anormal artışları tespit eder
- **Process Memory Takibi** - Her çalışmada memory değerlerini CSV'ye kaydeder, zaman içindeki değişimi analiz eder
- **Cache/Buffer Analizi** - Kernel slab cache dahil detaylı memory dağılımını gösterir
- **File Descriptor Kontrolü** - Açık FD sayısını izler, leak göstergesi olabilecek artışları tespit eder
- **Session/Bağlantı Durumu** - TCP bağlantı durumları, TIME_WAIT birikimi, ESTABLISHED bağlantı sayıları
- **Swap Analizi** - Hangi processler swap kullanıyor, memory pressure var mı
- **Uygulama Spesifik Kontroller** - Java, .NET Core, web server processlerini ayrıca analiz eder
- **Trend Analizi** - Biriken verilerden memory trendlerini çıkarır
- **Otomatik Öneriler** - Tespit edilen sorunlara göre aksiyon önerileri sunar

## Gereksinimler

- Ubuntu 20.04+ veya Debian 11+
- Bash 4.0+
- Root veya sudo yetkisi (bazı metrikler için)

## Kurulum

```bash
# Scripti indir
curl -O https://raw.githubusercontent.com/orkun-soylu/memory-monitor/main/memory_monitor.sh

# Çalıştırılabilir yap
chmod +x memory_monitor.sh

# (Opsiyonel) /usr/local/bin'e taşı
sudo mv memory_monitor.sh /usr/local/bin/memory_monitor
```

## Kullanım

### Tek Seferlik Tam Rapor

```bash
sudo ./memory_monitor.sh
```

Çıktı hem ekrana yazılır hem de `/var/log/memory_monitor/` altına loglanır.

### Sadece Loglama (Cron için)

```bash
sudo ./memory_monitor.sh --log-only
```

Sessiz çalışır, sadece log dosyasına yazar.

### Cron ile Otomatik İzleme

```bash
# Her 5 dakikada bir çalıştır
echo "*/5 * * * * root /usr/local/bin/memory_monitor --log-only" | sudo tee /etc/cron.d/memory-monitor

# Veya crontab'a ekle
sudo crontab -e
# Ekle: */5 * * * * /path/to/memory_monitor.sh --log-only >> /var/log/memory_monitor/cron.log 2>&1
```

## Örnek Çıktı

```
===============================================================================
 MEMORY MONITORING REPORT - 2026-01-22 14:30:00
 Hostname: server01 | Uptime: up 2 weeks, 3 days
===============================================================================

[1] GENEL MEMORY DURUMU
-------------------------------------------------------------------------------
              total        used        free      shared  buff/cache   available
Mem:           47Gi        12Gi       8.0Gi       1.2Gi        27Gi        33Gi
Swap:         2.0Gi          0B       2.0Gi

✓ Memory kullanımı: %25

[2] MEMORY LEAK ANALİZİ - EN ÇOK MEMORY KULLANAN PROCESSLER
-------------------------------------------------------------------------------
PID        %MEM     RSS (MB)     RUNTIME    COMMAND
-------------------------------------------------------------------------------
1234       8.5%     4096.0       5-02:30:15 java
5678       3.2%     1536.0       5-02:30:10 dotnet
...

[6] NETWORK BAĞLANTILARI VE SESSION DURUMU
-------------------------------------------------------------------------------
TCP bağlantı durumları:
  ESTABLISHED     245
  TIME-WAIT       89
  LISTEN          12

✓ TIME_WAIT: 89

[10] ÖZET VE ÖNERİLER
===============================================================================
Memory Durumu: %25 kullanımda, 33.0 GB kullanılabilir

Kontrol Edilmesi Gerekenler:
  ✓ Sistem genel olarak sağlıklı görünüyor
```

## Log Dosyaları

| Dosya | Açıklama |
|-------|----------|
| `/var/log/memory_monitor/memory_YYYYMMDD.log` | Günlük detaylı raporlar |
| `/var/log/memory_monitor/process_tracking.csv` | Process memory geçmişi (trend analizi için) |
| `/var/log/memory_monitor/cron.log` | Cron çalışma logları |

## Trend Analizi

Script birkaç kez çalıştırıldıktan sonra `process_tracking.csv` dosyasında yeterli veri birikir. Bu veriler üzerinden hangi processlerin memory kullanımının arttığı tespit edilebilir:

```bash
# Manuel trend kontrolü
cat /var/log/memory_monitor/process_tracking.csv | column -t -s','

# Son 100 kaydı göster
tail -100 /var/log/memory_monitor/process_tracking.csv | column -t -s','
```

## Yapılandırma

Script içindeki değişkenler düzenlenebilir:

```bash
LOG_DIR="/var/log/memory_monitor"  # Log dizini
ALERT_THRESHOLD=80                  # Memory uyarı eşiği (%)
TOP_PROCESSES=10                    # İzlenecek top process sayısı
```

## Sorun Giderme

### "Permission denied" hatası

Bazı metrikler root yetkisi gerektirir:

```bash
sudo ./memory_monitor.sh
```

### Log dizini oluşturulamıyor

Manuel oluşturun:

```bash
sudo mkdir -p /var/log/memory_monitor
sudo chown $USER:$USER /var/log/memory_monitor
```

### Trend analizi "yeterli veri yok" diyor

Script'i birkaç kez çalıştırın veya cron'a ekleyip bekleyin. En az 10 kayıt gerekli.

## Tespit Edilebilecek Sorunlar

| Sorun | Gösterge | Script Bölümü |
|-------|----------|---------------|
| Memory Leak | RSS sürekli artıyor, runtime uzun | Bölüm 2, 3, 9 |
| Cache Buildup | Slab/cache oranı yüksek | Bölüm 4 |
| FD Leak | Açık FD sayısı sürekli artıyor | Bölüm 5 |
| Session Birikimi | TIME_WAIT çok yüksek | Bölüm 6 |
| Memory Pressure | Swap kullanımı yüksek | Bölüm 7 |
| GC Sorunu | Java/dotnet memory dalgalanması | Bölüm 8 |

## Katkıda Bulunma

1. Fork edin
2. Feature branch oluşturun (`git checkout -b feature/yeni-ozellik`)
3. Commit edin (`git commit -am 'Yeni özellik eklendi'`)
4. Push edin (`git push origin feature/yeni-ozellik`)
5. Pull Request açın

## Lisans

MIT License - Detaylar için [LICENSE](LICENSE) dosyasına bakın.

## İlgili Projeler

- [htop](https://htop.dev/) - Interactive process viewer
- [glances](https://nicolargo.github.io/glances/) - System monitoring tool
- [netdata](https://www.netdata.cloud/) - Real-time performance monitoring
