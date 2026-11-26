import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/constants.dart';
import '../core/date_utils.dart';
import 'backup_validator.dart';
import 'database_service.dart';
import 'notification_service.dart';
import 'widget_sync_service.dart';

/// Hardened JSON export (SAF primary + optional share) & import service.
class BackupService {
  BackupService(this._db);

  final DatabaseService _db;

  /// Builds deterministic v2 backup JSON payload containing only allowed meta keys + progress.
  Future<String> buildBackupJson() async {
    final progressRows = await _db.getAllProgress();
    final allMeta = await _db.getAllMeta();

    final exportedMeta = <String, String>{};
    for (final key in BackupValidator.allowedImportMetaKeys) {
      final val = allMeta[key];
      if (val != null) {
        exportedMeta[key] = val;
      }
    }

    final payload = <String, Object?>{
      'schema_version': 2,
      'app_version': AppConstants.appVersion,
      'exported_at': DateTime.now().toIso8601String(),
      'app_meta': exportedMeta,
      'user_progress': progressRows.map((e) => e.toMap()).toList(growable: false),
    };

    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  String _defaultBackupFileName() {
    final today = LexoraDateUtils.todayLocalKey();
    return '${AppConstants.backupFilePrefix}$today.json';
  }

  /// Primary SAF export using `FilePicker.platform.saveFile` (zero storage permissions).
  Future<bool> exportViaSaf() async {
    final jsonStr = await buildBackupJson();
    final bytes = utf8.encode(jsonStr);
    final savedPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Lexora Yedeğini Kaydet',
      fileName: _defaultBackupFileName(),
      type: FileType.custom,
      allowedExtensions: const ['json'],
      bytes: bytes,
    );
    return savedPath != null && savedPath.isNotEmpty;
  }

  /// Optional share export via temporary `exports/` folder + `share_plus`.
  Future<void> exportViaShare() async {
    final jsonStr = await buildBackupJson();
    final tempDir = await getTemporaryDirectory();
    final exportsDir = Directory(p.join(tempDir.path, 'exports'));
    if (!await exportsDir.exists()) {
      await exportsDir.create(recursive: true);
    }

    final outFile = File(p.join(exportsDir.path, _defaultBackupFileName()));
    await outFile.writeAsString(jsonStr, encoding: utf8, flush: true);

    await Share.shareXFiles(
      [XFile(outFile.path, mimeType: 'application/json')],
      subject: 'Lexora Yedek (${LexoraDateUtils.todayLocalKey()})',
    );
  }

  /// Hardened JSON import with <= 10 MB pre-read size guard, depth <= 16 scan,
  /// strict validation, single SQLite transaction, and guaranteed temporary file cleanup.
  Future<int> importFromFilePicker() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: 'Lexora Yedek Dosyası Seç',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: false,
      );
      if (picked == null || picked.files.isEmpty) {
        return -1; // User cancelled
      }

      final filePath = picked.files.first.path;
      if (filePath == null || filePath.isEmpty) {
        throw const BackupValidationException('Seçilen dosya yolu okunamadı.');
      }

      final file = File(filePath);
      if (!await file.exists()) {
        throw const BackupValidationException('Seçilen yedek dosyası bulunamadı.');
      }

      // Enforce <= 10 MB strictly BEFORE reading into memory.
      final sizeBytes = await file.length();
      if (sizeBytes <= 0) {
        throw const BackupValidationException('Yedek dosyası boş.');
      }
      if (sizeBytes > AppConstants.maxBackupBytes) {
        throw const BackupValidationException(
          'Yedek dosyası 10 MB güvenlik sınırını aşıyor.',
        );
      }

      final rawText = await file.readAsString(encoding: utf8);
      final validated = BackupValidator.parseAndValidate(rawText);

      await _db.applyValidatedBackupAtomic(
        progressRows: validated.progressRows,
        meta: validated.meta,
      );

      // Full resync after restore
      try {
        await NotificationService.syncSevenDaySchedule(_db);
      } catch (e) {
        lexoraLog('Backup restore notification sync error: $e');
      }
      await WidgetSyncService.syncFromApp(_db, forceRotate: true);

      return validated.progressRows.length;
    } finally {
      try {
        await FilePicker.platform.clearTemporaryFiles();
      } catch (_) {}
    }
  }

  /// Cleans stale temporary files (> 1 hour old) from `getTemporaryDirectory()/exports/`.
  static Future<void> cleanupStaleExports() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final exportsDir = Directory(p.join(tempDir.path, 'exports'));
      if (!await exportsDir.exists()) return;

      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      await for (final entity in exportsDir.list()) {
        if (entity is File) {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete();
          }
        }
      }
    } catch (e) {
      lexoraLog('cleanupStaleExports error: $e');
    }
  }
}
