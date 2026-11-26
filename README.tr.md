<div align="center">

# Lexora

[English](README.md) | **Türkçe**

Flutter ile geliştirilmiş, tamamen çevrimdışı çalışan (offline-first) İngilizce kelime öğrenme ve sözlük uygulaması. 737 binden fazla kelimelik tek dilli sözlük, aralıklı tekrar (SRS), bağlamsal Cloze testleri, çift aksan (US/UK) telaffuz desteği ve yerel Android ana ekran widget'ı içerir.

![Flutter](https://img.shields.io/badge/Flutter-02569B?style=flat&logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-0175C2?style=flat&logo=dart&logoColor=white)
![Kotlin](https://img.shields.io/badge/Kotlin-7F52FF?style=flat&logo=kotlin&logoColor=white)
![Python](https://img.shields.io/badge/Python-3776AB?style=flat&logo=python&logoColor=white)
![SQLite](https://img.shields.io/badge/SQLite-003B57?style=flat&logo=sqlite&logoColor=white)

</div>

---

## Özellikler

- **Çevrimdışı Tek Dilli Sözlük (737.261 kayıt):** Kaikki.org üzerinden derlenen İngilizce Wiktionary verisiyle hızlı yerel SQLite araması ve tanımların içindeki kelimelere tıklanabilen etkileşimli görünüm (`ClickableText`).
- **Planlı Günlük Çalışma Akışı:**
  - **Seviye Belirleme ve Kurulum:** Başlangıç CEFR seviyesini (B1–C2) ve günlük çalışma rutinini ayarlar.
  - **Sabah Oturumları:** Yeni kelimeleri tanımları, örnek cümleleri ve sesli telaffuzlarıyla tanıtır.
  - **Akşam Cloze Testleri:** Boşluk doldurma formatında bağlamsal hatırlama pratiği yaptırır.
  - **Aralıklı Tekrar Sistemi (SRS):** Hatırlama performansına göre tekrar aralıklarını otomatik planlar.
- **Çift Aksan Telaffuz Desteği:** Amerikan (US) ve İngiliz (UK) İngilizcesi fonetik gösterimi ile doğrulanmış Wikimedia Commons ses akışı ve yerel yedek seslendirme desteği sunar.
- **Yerel 2×2 Android Ana Ekran Widget'ı:** CEFR seviye rozetleriyle (`B1`, `B2`, `C1`, `C2`) kelime kartlarını doğrudan ana ekranda gösterir; arka plan senkronizasyonu ve manuel yenileme destekler.
- **Kişisel Kelime Defteri:** Sözlük aramalarından veya çalışma oturumlarından kelimeleri kaydedip düzenli olarak tekrar etme imkânı verir.
- **Gizlilik Odaklı ve Taşınabilir:** Sunucu yok, hesap yok, kullanıcı takibi yok. İlerlemeyi taşımak için şema doğrulamalı JSON yedekleme ve geri yükleme içerir.

---

## Mimari

Lexora, statik sözlük verisi ile değişken kullanıcı verisini birbirinden ayıran **çift SQLite mimarisi** kullanır:

1. **Salt Okunur Sözlük (`vocab_dict.db`):** Uygulama paketine gzip ile sıkıştırılmış olarak (`vocab_dict.db.gz`, yaklaşık 85 MB sıkıştırılmış / 266 MB açılmış) dahil edilir ve `assets/vocab_dict.meta.json` (SHA-256) ile bütünlüğü doğrulanır. İlk açılışta yerel Kotlin çıkarıcısı (`DictExtractor.kt`), Dart bellek yükünü artırmadan veritabanını doğrudan cihaz depolamasına açar.
2. **Kullanıcı Veritabanı (`user_data.db`):** SRS planlarını, oturum kayıtlarını, seviye ayarlarını ve kişisel kelime defterini yerel olarak saklar.
3. **Python ETL Boru Hattı (`tools/build_vocab_db.py`):** Ham Kaikki.org Wiktionary JSONL verisini işleyip indekslenmiş, sıkıştırılmış SQLite veritabanına dönüştürür ve bütünlük meta verisini üretir.
4. **Sertleştirilmiş Yayın Yapılandırması:** R8/ProGuard koruma kuralları, Android `network_security_config.xml`, `data_extraction_rules.xml` ve birim testlerle doğrulanan URL/yedekleme denetleyicilerini içerir.

---

## Proje Yapısı

```text
Lexora/
├── android/
│   └── app/
│       ├── proguard-rules.pro              # R8 / Gson / Bildirim koruma kuralları
│       └── src/main/kotlin/.../
│           ├── MainActivity.kt             # Platform kanalı ve deep link yöneticisi
│           ├── DictExtractor.kt            # Yerel gzip sözlük çıkarıcısı
│           └── VocabWidgetProvider.kt      # Yerel 2x2 ana ekran widget'ı
├── assets/
│   └── vocab_dict.meta.json                # Sözlük şema ve SHA-256 meta verisi
├── lib/
│   ├── main.dart                           # Uygulama giriş noktası
│   ├── core/                               # Sabitler, tarih araçları, metin normalizasyonu
│   ├── models/                             # Kelime veri modelleri
│   ├── router/                             # Sayfa yönlendirme ve deep link yapısı
│   ├── screens/                            # Ana ekran, oturumlar, cloze, sözlük, defter, ayarlar
│   ├── services/                           # SRS motoru, SQLite, ses, yedekleme, bildirim, widget senkronizasyonu
│   ├── state/                              # Uygulama durum sağlayıcıları
│   ├── theme/                              # Koyu tema odaklı Lexora arayüz teması
│   └── widgets/                            # Aksan ses satırları, tıklanabilir metin, logo bileşenleri
├── test/                                   # Birim testler (SRS, Cloze, doğrulayıcılar, deep link, normalizasyon)
└── tools/
    ├── build_vocab_db.py                   # Kaikki.org JSONL -> SQLite ETL boru hattı
    └── generate_brand_assets.py            # Uygulama ikonu ve açılış ekranı görsel üreticisi
```

---

## Kurulum ve Derleme

> **Not:** Hazır sözlük veritabanı (`assets/vocab_dict.db.gz`), GitHub'ın 100 MB tek dosya sınırı nedeniyle depoya dahil edilmemiştir. Uygulamayı derlemeden önce projedeki Python ETL script'i ile yerel olarak üretmeniz gerekir.

### Gereksinimler

- **Flutter SDK** (3.x) ve **Android SDK**
- **Python 3.10+** (sözlük veritabanını oluşturmak için)

### 1. Depoyu Klonlayın

```bash
git clone https://github.com/KeRmOdLeZ/Lexora.git
cd Lexora
```

### 2. Çevrimdışı Sözlük Veritabanını Oluşturun

İngilizce Wiktionary verisini indirip işleyerek `assets/vocab_dict.db.gz` ve `assets/vocab_dict.meta.json` dosyalarını üretmek için:

```bash
python tools/build_vocab_db.py
```

### 3. Bağımlılıkları Yükleyin ve Testleri Çalıştırın

```bash
flutter pub get
flutter test
```

### 4. Uygulamayı Çalıştırın veya Release APK Derleyin

```bash
# Bağlı Android cihazda çalıştır
flutter run

# Release APK derle
flutter build apk --release
```

---

## Veri Kaynakları ve Atıflar

- **Sözlük Verisi:** [Kaikki.org](https://kaikki.org/) aracılığıyla [Wiktionary](https://en.wiktionary.org/) projesinden alınmıştır ve [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) lisansı altındadır.
- **Telaffuz Sesleri:** Mevcut olduğu durumlarda [Wikimedia Commons](https://commons.wikimedia.org/) üzerinden ilgili Creative Commons / Kamu Malı lisansları kapsamında çevrimiçi olarak çalınır.