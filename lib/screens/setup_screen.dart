import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_bootstrap.dart';
import '../state/app_providers.dart';
import '../theme/lexora_theme.dart';
import '../widgets/lexora_logo.dart';

/// Lightweight boot & dictionary extraction screen (`PopScope(canPop: false)`).
class SetupScreen extends ConsumerWidget {
  const SetupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boot = ref.watch(bootstrapControllerProvider);
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      child: AnnotatedRegion(
        value: LexoraTheme.overlayStyleFor(theme.brightness),
        child: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(),
                  const Center(child: LexoraLogo(size: 96)),
                  const SizedBox(height: 24),
                  Text(
                    'Lexora',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Çevrimdışı İngilizce–İngilizce Kelime Stüdyosu',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
                    ),
                  ),
                  const SizedBox(height: 40),
                  if (boot.stage == BootstrapStage.error) ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: LexoraTheme.danger.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: LexoraTheme.danger.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                boot.isInsufficientStorage
                                    ? Icons.sd_storage_outlined
                                    : Icons.error_outline_rounded,
                                color: LexoraTheme.danger,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  boot.statusMessage,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (boot.errorMessage != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              boot.errorMessage!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: () {
                        ref.read(bootstrapControllerProvider.notifier).start();
                      },
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Tekrar Dene'),
                    ),
                  ] else ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: boot.progress > 0 ? boot.progress : null,
                        minHeight: 8,
                        backgroundColor: LexoraTheme.surfaceElevatedDark,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      boot.statusMessage,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.8),
                      ),
                    ),
                    if (boot.dictMetadata != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '${boot.dictMetadata!.wordCount} sözlük kaydı doğrulanıyor',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ],
                  const Spacer(),
                  Text(
                    'İlk kurulum yalnızca bir kez yapılır ve %100 çevrimdışı çalışır.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
