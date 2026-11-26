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

> **Arayüz Dili Notu:** Sözlük tanımları, örnek cümleler ve telaffuzlar tamamen İngilizce–İngilizce (tek dilli) olup uygulama arayüzü, bildirimler ve ana ekran widget metinleri şu an yalnızca **Türkçe**dir.

---

## Mimari

Lexora, statik sözlük verisi ile değişken kullanıcı verisini birbirinden ayıran **çift SQLite mimarisi** kullanır:

1. **Salt Okunur Sözlük (`vocab_dict.db`):** Uygulama paketine gzip ile sıkıştırılmış olarak (`vocab_dict.db.gz`, yaklaşık 85,4 MB sıkıştırılmış / 266,4 MB açılmış) dahil edilir ve `assets/vocab_dict.meta.json` (SHA-256) ile bütünlüğü doğrulanır. İlk açılışta yerel Kotlin çıkarıcısı (`DictExtractor.kt`), Dart bellek yükünü artırmadan veritabanını doğrudan cihaz depolamasına açar.
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

## İndirme (Hazır APK)

Uygulamayı kaynaktan derlemeden doğrudan Android cihazınıza (Android 7.0 / API 24+) kurmak için, 737 bin kelimelik tam sözlük gömülü hazır APK'yı [GitHub Releases](https://github.com/KeRmOdLeZ/Lexora/releases) sayfasından indirebilirsiniz.

---

## Kurulum ve Kaynaktan Derleme

> **Not:** Hazır sözlük veritabanı (`assets/vocab_dict.db.gz`, ~85,4 MB) depo geçmişini şişirmemek için Git'e dahil edilmemiştir. Derleme öncesinde [GitHub Releases](https://github.com/KeRmOdLeZ/Lexora/releases) sayfasından indirebilir veya projedeki Python ETL script'i ile yerel olarak üretebilirsiniz.

### Gereksinimler

- **Flutter SDK** `>=3.44.0` (**Dart SDK** `^3.13.5`)
- **Android SDK** (`minSdk 24`, `targetSdk 35`, `compileSdk 36`)
- **Python 3.10+** (yalnızca sözlüğü Releases'tan indirmek yerine yerel olarak üretmek isterseniz)

### 1. Depoyu Klonlayın

```bash
git clone https://github.com/KeRmOdLeZ/Lexora.git
cd Lexora
```

### 2. Çevrimdışı Sözlük Veritabanını Hazırlayın

`assets/vocab_dict.db.gz` dosyasını hazırlamak için aşağıdaki seçeneklerden birini kullanın:

- **Seçenek A — Hazır sözlüğü indirin (önerilen):**
  [GitHub Releases](https://github.com/KeRmOdLeZ/Lexora/releases) sayfasından `vocab_dict.db.gz` dosyasını indirip doğrudan `assets/vocab_dict.db.gz` konumuna yerleştirin (`assets/vocab_dict.meta.json` içindeki SHA-256 özetiyle birebir uyumludur).

- **Seçenek B — Kaikki.org üzerinden tam sözlüğü yerel olarak oluşturun:**
  ```bash
  # Sezgisel (heuristic) CEFR seviye ataması ile tam Wiktionary veritabanı
  python tools/build_vocab_db.py --full --allow-heuristic-cefr

  # Veya kendi CEFR CSV dosyanızla (sütunlar: word, level [A1..C2])
  python tools/build_vocab_db.py --full --cefr-csv path/to/cefr.csv
  ```
  > `--full` modu `--cefr-csv` veya `--allow-heuristic-cefr` olmadan çalıştırılırsa kelimelerin CEFR seviyeleri boş (`NULL`) kalır; bu durumda seviye belirleme testi, günlük çalışma havuzu ve ana ekran widget döngüsü çalışmaz.

- **Seçenek C — 120 kelimelik örnek sözlüğü oluşturun (hızlı geliştirme/test):**
  ```bash
  python tools/build_vocab_db.py --sample
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

# Yerel dosya yolu sembollerini gizleyerek release APK derle
flutter build apk --release --obfuscate --split-debug-info=build/app/outputs/symbols
```

> **İmzalama Notu:** `android/app/build.gradle.kts` yerel derlemeler için varsayılan olarak Android debug anahtarını kullanır. APK'yı herkese açık dağıtacağınız veya Google Play'de yayınlayacağınız zaman ayrı bir release keystore yapılandırın (ör. `.gitignore` ile korunan `android/key.properties` üzerinden).

---

## Veri Kaynakları ve Atıflar

- **Sözlük Verisi:** [Kaikki.org](https://kaikki.org/) aracılığıyla [Wiktionary](https://en.wiktionary.org/) projesinden alınmıştır ve [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) lisansı altındadır.
- **Telaffuz Sesleri:** Mevcut olduğu durumlarda [Wikimedia Commons](https://commons.wikimedia.org/) üzerinden ilgili Creative Commons / Kamu Malı lisansları kapsamında çevrimiçi olarak çalınır.
