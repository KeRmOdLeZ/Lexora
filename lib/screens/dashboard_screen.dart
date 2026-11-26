import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/word_entry.dart';
import '../state/app_providers.dart';
import '../theme/lexora_theme.dart';
import '../widgets/lexora_logo.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(dashboardControllerProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final dash = ref.watch(dashboardControllerProvider);
    final theme = Theme.of(context);
    final session = dash.session;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const LexoraLogo(size: 30),
            const SizedBox(width: 10),
            const Text(
              'Lexora',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: LexoraTheme.cefrColor(dash.targetStartLevel)
                    .withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: LexoraTheme.cefrColor(dash.targetStartLevel)
                      .withValues(alpha: 0.55),
                ),
              ),
              child: Text(
                dash.targetStartLevel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: LexoraTheme.cefrColor(dash.targetStartLevel),
                ),
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Chip(
              avatar: const Icon(
                Icons.local_fire_department_rounded,
                size: 18,
                color: LexoraTheme.amber,
              ),
              label: Text(
                '${dash.currentStreak} gün',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () =>
            ref.read(dashboardControllerProvider.notifier).refresh(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            if (session?.isReviewOnly == true) ...[
              Container(
                padding: const EdgeInsets.all(14),
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: LexoraTheme.amber.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: LexoraTheme.amber.withValues(alpha: 0.55),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.layers_rounded,
                      color: LexoraTheme.amber,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Yalnızca Tekrar Günü Aktif',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: LexoraTheme.amber,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '20 veya daha fazla bekleyen tekrarın olduğu için bugün yeni kelime eklenmedi ve Akşam Cloze testi atlandı.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Morning Session Card
            _SessionActionCard(
              icon: Icons.wb_sunny_rounded,
              accentColor: LexoraTheme.sapphireBright,
              title: 'Sabah Oturumu',
              subtitle: _morningSubtitle(session),
              progress: _morningProgress(session),
              completed: session?.morningCompleted ?? false,
              buttonLabel: _morningButtonLabel(session),
              onPressed: session == null || !session.hasMorningWork
                  ? null
                  : () => context.push('/morning'),
            ),
            const SizedBox(height: 14),

            // Evening Cloze Card
            _SessionActionCard(
              icon: Icons.nights_stay_rounded,
              accentColor: LexoraTheme.emeraldBright,
              title: 'Akşam Cloze Testi',
              subtitle: _eveningSubtitle(session),
              progress: _eveningProgress(session),
              completed: session?.eveningCompleted ?? false,
              buttonLabel: _eveningButtonLabel(session),
              onPressed: session == null || !session.hasEveningWork
                  ? null
                  : () => context.push('/evening'),
            ),
            const SizedBox(height: 14),

            // Extra Practice Card (never touches daily_session / streak / next_review_date)
            Card(
              child: ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: LexoraTheme.violet.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.bolt_rounded,
                    color: LexoraTheme.violet,
                  ),
                ),
                title: const Text(
                  'Ekstra Pratik',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: const Text(
                  'Günlük seriyi ve tekrar tarihlerini etkilemeden serbest çalış',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push('/morning?extra=1'),
              ),
            ),

            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Kelime Defterim',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                TextButton(
                  onPressed: () => context.push('/notebook?bucket=all'),
                  child: Text('Tümü (${dash.masteryCounts.total})'),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Clickable Mastery Cards -> Kelime Defterim
            Row(
              children: [
                Expanded(
                  child: _MasteryCard(
                    title: 'Öğreniliyor',
                    rangeLabel: '< 50',
                    count: dash.masteryCounts.learning,
                    color: LexoraTheme.amber,
                    onTap: () => context.push('/notebook?bucket=learning'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MasteryCard(
                    title: 'Pekiştiriliyor',
                    rangeLabel: '50–84',
                    count: dash.masteryCounts.consolidating,
                    color: LexoraTheme.sapphireBright,
                    onTap: () => context.push('/notebook?bucket=consolidating'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MasteryCard(
                    title: 'Ustalaşıldı',
                    rangeLabel: '≥ 85',
                    count: dash.masteryCounts.mastered,
                    color: LexoraTheme.emeraldBright,
                    onTap: () => context.push('/notebook?bucket=mastered'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Streak summary strip
            Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    const Icon(
                      Icons.emoji_events_rounded,
                      color: LexoraTheme.amber,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'En uzun seri: ${dash.longestStreak} gün',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      'Aktif: ${dash.currentStreak} gün',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: LexoraTheme.emeraldBright,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _morningSubtitle(DailySession? s) {
    if (s == null) return 'Oturum hazırlanıyor...';
    if (!s.hasMorningWork) return 'Bugün için planlanmış kelime yok.';
    if (s.morningCompleted) {
      return 'Tamamlandı • ${s.morningKnownCount}/${s.morningWordKeys.length} anlam bilindi';
    }
    return '${s.reviewWordKeys.length} tekrar + ${s.newWordKeys.length} yeni kelime (${s.morningIndex}/${s.morningWordKeys.length})';
  }

  static double _morningProgress(DailySession? s) {
    if (s == null || s.morningWordKeys.isEmpty) return 0;
    return (s.morningIndex / s.morningWordKeys.length).clamp(0.0, 1.0);
  }

  static String _morningButtonLabel(DailySession? s) {
    if (s == null || !s.hasMorningWork) return 'Kelime Yok';
    if (s.morningCompleted) return 'Tamamlandı';
    return s.morningIndex > 0 ? 'Devam Et' : 'Sabah Oturumuna Başla';
  }

  static String _eveningSubtitle(DailySession? s) {
    if (s == null) return 'Oturum hazırlanıyor...';
    if (s.isReviewOnly) return 'Yalnızca tekrar günü olduğu için atlandı.';
    if (s.eveningWordKeys.isEmpty) return 'Bugün yeni kelime bulunmuyor.';
    if (s.eveningCompleted) {
      return 'Tamamlandı • ${s.eveningCorrectCount}/${s.eveningWordKeys.length} doğru';
    }
    return '${s.eveningWordKeys.length} yeni kelime cümle içi Cloze testi (${s.eveningIndex}/${s.eveningWordKeys.length})';
  }

  static double _eveningProgress(DailySession? s) {
    if (s == null || s.eveningWordKeys.isEmpty) return 0;
    return (s.eveningIndex / s.eveningWordKeys.length).clamp(0.0, 1.0);
  }

  static String _eveningButtonLabel(DailySession? s) {
    if (s == null || s.isReviewOnly || s.eveningWordKeys.isEmpty) {
      return 'Bugün Yok';
    }
    if (s.eveningCompleted) return 'Tamamlandı';
    return s.eveningIndex > 0 ? 'Teste Devam Et' : 'Akşam Cloze Testine Başla';
  }
}

class _SessionActionCard extends StatelessWidget {
  const _SessionActionCard({
    required this.icon,
    required this.accentColor,
    required this.title,
    required this.subtitle,
    required this.progress,
    required this.completed,
    required this.buttonLabel,
    required this.onPressed,
  });

  final IconData icon;
  final Color accentColor;
  final String title;
  final String subtitle;
  final double progress;
  final bool completed;
  final String buttonLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: accentColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.72),
                        ),
                      ),
                    ],
                  ),
                ),
                if (completed)
                  const Icon(
                    Icons.check_circle_rounded,
                    color: LexoraTheme.emeraldBright,
                  ),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: completed ? 1.0 : progress,
                minHeight: 6,
                color: accentColor,
                backgroundColor: accentColor.withValues(alpha: 0.14),
              ),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: completed ? null : onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: accentColor,
                foregroundColor: const Color(0xFF0A1018),
              ),
              child: Text(buttonLabel),
            ),
          ],
        ),
      ),
    );
  }
}

class _MasteryCard extends StatelessWidget {
  const _MasteryCard({
    required this.title,
    required this.rangeLabel,
    required this.count,
    required this.color,
    required this.onTap,
  });

  final String title;
  final String rangeLabel;
  final int count;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$count',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: color,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'Skor $rangeLabel',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
