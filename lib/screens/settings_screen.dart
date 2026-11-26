import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../services/backup_validator.dart';
import '../services/widget_sync_service.dart';
import '../state/app_providers.dart';
import '../theme/lexora_theme.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _busyBackup = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(settingsControllerProvider.notifier).refreshCacheSize();
    });
  }

  Future<void> _pickReminderTime({
    required String title,
    required String currentValue,
    required Future<void> Function(String next) onSave,
  }) async {
    final initial = _parseTimeOfDay(currentValue);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.access_time_rounded),
              title: const Text('Saat Seç'),
              onTap: () => Navigator.of(ctx).pop('pick'),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_off_outlined),
              title: const Text('Hatırlatıcıyı Kapat'),
              onTap: () => Navigator.of(ctx).pop('off'),
            ),
          ],
        ),
      ),
    );

    if (action == null || !mounted) return;
    if (action == 'off') {
      await onSave('off');
      return;
    }

    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
    );
    if (picked == null || !mounted) return;
    final hh = picked.hour.toString().padLeft(2, '0');
    final mm = picked.minute.toString().padLeft(2, '0');
    await onSave('$hh:$mm');
  }

  static TimeOfDay _parseTimeOfDay(String raw) {
    final parts = raw.split(':');
    if (parts.length == 2) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (h != null && m != null) {
        return TimeOfDay(hour: h.clamp(0, 23), minute: m.clamp(0, 59));
      }
    }
    return const TimeOfDay(hour: 9, minute: 0);
  }

  Future<void> _exportSaf() async {
    if (_busyBackup) return;
    setState(() => _busyBackup = true);
    try {
      final saved = await ref.read(backupServiceProvider).exportViaSaf();
      if (!mounted) return;
      if (saved) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('JSON yedek dosyası kaydedildi.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Yedek kaydedilemedi: $e')),
      );
    } finally {
      if (mounted) setState(() => _busyBackup = false);
    }
  }

  Future<void> _exportShare() async {
    if (_busyBackup) return;
    setState(() => _busyBackup = true);
    try {
      await ref.read(backupServiceProvider).exportViaShare();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Yedek paylaşılamadı: $e')),
      );
    } finally {
      if (mounted) setState(() => _busyBackup = false);
    }
  }

  Future<void> _importBackup() async {
    if (_busyBackup) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Yedekten Geri Yükle'),
        content: const Text(
          'Mevcut kelime ilerlemen ve bugünkü oturumun seçilen yedek dosyasıyla değiştirilecek. Devam edilsin mi?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Geri Yükle'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _busyBackup = true);
    try {
      final restoredCount =
          await ref.read(backupServiceProvider).importFromFilePicker();
      if (!mounted) return;
      if (restoredCount >= 0) {
        await ref.read(settingsControllerProvider.notifier).reload();
        await ref.read(dashboardControllerProvider.notifier).refresh();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$restoredCount kelime kaydı başarıyla geri yüklendi.'),
          ),
        );
      }
    } on BackupValidationException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Yedek reddedildi: ${e.message}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Geri yükleme hatası: $e')),
      );
    } finally {
      if (mounted) setState(() => _busyBackup = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final boot = ref.watch(bootstrapControllerProvider);
    final theme = Theme.of(context);
    final meta = boot.dictMetadata;
    final cacheMb = (settings.audioCacheBytes / (1024 * 1024)).toStringAsFixed(2);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Ayarlar',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _sectionTitle(theme, 'Çalışma & Telaffuz'),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('Varsayılan Aksan'),
                  subtitle: const Text('Otomatik oynatma ve widget IPA tercihi'),
                  trailing: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'us', label: Text('US')),
                      ButtonSegment(value: 'uk', label: Text('UK')),
                    ],
                    selected: {settings.defaultAccent},
                    onSelectionChanged: (s) => controller.setDefaultAccent(s.first),
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Otomatik Ses Oynat'),
                  subtitle: const Text('Adım 2 ve Cloze sonrasında telaffuzu çal'),
                  value: settings.autoPlayAudio,
                  onChanged: controller.setAutoPlayAudio,
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Hedef Başlangıç Seviyesi'),
                  subtitle: const Text('Yeni günlük kelimelerin seçildiği CEFR havuzu'),
                  trailing: DropdownButton<String>(
                    value: settings.targetStartLevel,
                    underline: const SizedBox.shrink(),
                    items: AppConstants.studyCefrLevels
                        .map(
                          (lvl) => DropdownMenuItem(
                            value: lvl,
                            child: Text(lvl),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (val) {
                      if (val != null) controller.setTargetStartLevel(val);
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.record_voice_over_outlined),
                  title: const Text('Android TTS Ses Paketleri'),
                  subtitle: const Text('Çevrimdışı İngilizce ses ayarlarını aç'),
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: () {
                    ref.read(dictExtractorServiceProvider).openTtsSettings();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          _sectionTitle(theme, 'Görünüm & Ana Ekran Widget\'ı'),
          Card(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Tema',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<ThemeMode>(
                          segments: const [
                            ButtonSegment(
                              value: ThemeMode.dark,
                              label: Text('Koyu'),
                            ),
                            ButtonSegment(
                              value: ThemeMode.system,
                              label: Text('Sistem'),
                            ),
                            ButtonSegment(
                              value: ThemeMode.light,
                              label: Text('Açık'),
                            ),
                          ],
                          selected: {settings.themeMode},
                          onSelectionChanged: (s) =>
                              controller.setThemeMode(s.first),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('Widget Değişim Aralığı'),
                  subtitle: const Text('Ana ekran 2x2 widget kelime döngü süresi'),
                  trailing: DropdownButton<int>(
                    value: settings.widgetIntervalHours,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: 6, child: Text('6 saat')),
                      DropdownMenuItem(value: 12, child: Text('12 saat')),
                      DropdownMenuItem(value: 24, child: Text('24 saat')),
                    ],
                    onChanged: (val) {
                      if (val != null) controller.setWidgetIntervalHours(val);
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.widgets_outlined),
                  title: const Text('Widget Kelimesini Şimdi Yenile'),
                  onTap: () async {
                    await WidgetSyncService.syncFromApp(
                      ref.read(databaseServiceProvider),
                      forceRotate: true,
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Ana ekran widget\'ı güncellendi.')),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          _sectionTitle(theme, 'Bildirimler (7 Günlük Kayan Plan)'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.wb_sunny_outlined),
                  title: const Text('Sabah Hatırlatıcısı'),
                  trailing: Text(
                    settings.morningReminder == 'off'
                        ? 'Kapalı'
                        : settings.morningReminder,
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onTap: () => _pickReminderTime(
                    title: 'Sabah Hatırlatıcısı',
                    currentValue: settings.morningReminder,
                    onSave: controller.setMorningReminder,
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.nights_stay_outlined),
                  title: const Text('Akşam Cloze Hatırlatıcısı'),
                  trailing: Text(
                    settings.eveningReminder == 'off'
                        ? 'Kapalı'
                        : settings.eveningReminder,
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onTap: () => _pickReminderTime(
                    title: 'Akşam Hatırlatıcısı',
                    currentValue: settings.eveningReminder,
                    onSave: controller.setEveningReminder,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          _sectionTitle(theme, 'Depolama & Yedekleme'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.audio_file_outlined),
                  title: const Text('Ses Önbelleği'),
                  subtitle: Text('$cacheMb MB / 50 MB LRU sınırı'),
                  trailing: TextButton(
                    onPressed: () async {
                      await controller.clearAudioCache();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Ses önbelleği temizlendi.')),
                      );
                    },
                    child: const Text('Temizle'),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.save_alt_rounded),
                  title: const Text('JSON Yedekle (Cihaza Kaydet)'),
                  subtitle: const Text('Depolama izni gerektirmeden SAF ile kaydet'),
                  enabled: !_busyBackup,
                  onTap: _exportSaf,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.share_outlined),
                  title: const Text('JSON Yedeğini Paylaş'),
                  enabled: !_busyBackup,
                  onTap: _exportShare,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.restore_rounded),
                  title: const Text('JSON Yedekten Geri Yükle'),
                  subtitle: const Text('Sertleştirilmiş şema v2 doğrulamalı içe aktarma'),
                  enabled: !_busyBackup,
                  onTap: _importBackup,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          _sectionTitle(theme, 'Sözlük Bilgisi'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Lexora v${AppConstants.appVersion}',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const Spacer(),
                      if (meta != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: (meta.isSample
                                    ? LexoraTheme.amber
                                    : LexoraTheme.emeraldBright)
                                .withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            meta.isSample ? 'Örnek Sözlük' : 'Tam Wiktionary',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: meta.isSample
                                  ? LexoraTheme.amber
                                  : LexoraTheme.emeraldBright,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (meta != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Kelime sayısı: ${meta.wordCount}  •  Şema v${meta.schemaVersion}',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Veritabanı boyutu: ${(meta.uncompressedSize / (1024 * 1024)).toStringAsFixed(2)} MB (çevrimdışı)',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w800,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
