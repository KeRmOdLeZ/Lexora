import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/word_entry.dart';
import '../state/app_providers.dart';
import '../theme/lexora_theme.dart';

/// Full-width vertically stacked US & UK pronunciation rows with >= 48dp x 48dp
/// touch targets, IPA fallback typography, and gentle offline TTS settings prompt.
class AccentAudioRows extends ConsumerWidget {
  const AccentAudioRows({
    super.key,
    required this.word,
    this.compact = false,
  });

  final WordEntry word;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playbackAsync = ref.watch(audioPlaybackStateProvider);
    final playback = playbackAsync.valueOrNull ??
        ref.read(audioServiceProvider).currentState;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AccentRow(
          label: 'US',
          badgeColor: LexoraTheme.sapphire,
          ipa: word.ipaUs,
          isLoading: playback.activeWordKey == word.wordKey &&
              playback.activeAccent == 'us' &&
              playback.isLoading,
          isPlaying: playback.activeWordKey == word.wordKey &&
              playback.activeAccent == 'us' &&
              playback.isPlaying,
          compact: compact,
          onTap: () => ref.read(audioServiceProvider).playWord(word, accent: 'us'),
        ),
        SizedBox(height: compact ? 8 : 10),
        _AccentRow(
          label: 'UK',
          badgeColor: LexoraTheme.emerald,
          ipa: word.ipaUk,
          isLoading: playback.activeWordKey == word.wordKey &&
              playback.activeAccent == 'uk' &&
              playback.isLoading,
          isPlaying: playback.activeWordKey == word.wordKey &&
              playback.activeAccent == 'uk' &&
              playback.isPlaying,
          compact: compact,
          onTap: () => ref.read(audioServiceProvider).playWord(word, accent: 'uk'),
        ),
      ],
    );
  }
}

class _AccentRow extends StatelessWidget {
  const _AccentRow({
    required this.label,
    required this.badgeColor,
    required this.ipa,
    required this.isLoading,
    required this.isPlaying,
    required this.compact,
    required this.onTap,
  });

  final String label;
  final Color badgeColor;
  final String? ipa;
  final bool isLoading;
  final bool isPlaying;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: isDark
          ? LexoraTheme.surfaceElevatedDark
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: compact ? 4 : 6,
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: badgeColor.withValues(alpha: 0.65),
                    ),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : badgeColor,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    (ipa != null && ipa!.trim().isNotEmpty)
                        ? ipa!
                        : 'Telaffuzu dinle ($label)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (ipa != null && ipa!.trim().isNotEmpty)
                        ? LexoraTheme.ipaTextStyle(context, fontSize: 15)
                        : theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.65),
                          ),
                  ),
                ),
                SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          )
                        : Icon(
                            isPlaying
                                ? Icons.graphic_eq_rounded
                                : Icons.volume_up_rounded,
                            color: isPlaying
                                ? LexoraTheme.emeraldBright
                                : theme.colorScheme.primary,
                            size: 24,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
