import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_models.dart';
import '../../core/network/api_error_message.dart';
import '../../core/network/surf_repository.dart';

final adminUsersProvider = FutureProvider.autoDispose<List<AdminUserAccount>>(
  (ref) => ref.watch(surfRepositoryProvider).fetchAdminUsers(),
);

final adminReportsProvider =
    AsyncNotifierProvider.autoDispose<
      AdminReportsController,
      List<AdminReport>
    >(AdminReportsController.new);

/// The active queue changes only after the server confirms an admin action.
class AdminReportsController
    extends AutoDisposeAsyncNotifier<List<AdminReport>> {
  int _generation = 0;
  bool _disposed = false;

  @override
  Future<List<AdminReport>> build() {
    _generation++;
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return ref.watch(surfRepositoryProvider).fetchAdminReports();
  }

  void _checkGeneration(int generation) {
    if (_disposed || generation != _generation) {
      throw StateError('The admin session changed. Refresh and try again.');
    }
  }

  Future<void> setDismissed(String reportId, bool dismissed) async {
    final loaded = future;
    final generation = _generation;
    await loaded;
    _checkGeneration(generation);
    await ref
        .read(surfRepositoryProvider)
        .setAdminReportStatus(reportId: reportId, dismissed: dismissed);
    _checkGeneration(generation);
    state = AsyncData([
      for (final report in state.valueOrNull ?? const <AdminReport>[])
        report.id == reportId ? report.withDismissed(dismissed) : report,
    ]);
  }
}

class AdminUsersPage extends ConsumerStatefulWidget {
  const AdminUsersPage({super.key});

  @override
  ConsumerState<AdminUsersPage> createState() => _AdminUsersPageState();
}

class _AdminUsersPageState extends ConsumerState<AdminUsersPage> {
  String _query = '';
  bool _showDismissedReports = false;
  final Set<String> _pendingReports = {};

  Future<void> _setReportDismissed(String reportId, bool dismissed) async {
    if (_pendingReports.contains(reportId)) return;
    setState(() => _pendingReports.add(reportId));
    try {
      await ref
          .read(adminReportsProvider.notifier)
          .setDismissed(reportId, dismissed);
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            dismissed
                ? 'Report dismissed. Post and accounts unchanged.'
                : 'Report restored to active reports.',
          ),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => _setReportDismissed(reportId, !dismissed),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not ${dismissed ? 'dismiss' : 'restore'} report. ${friendlyErrorMessage(error)}',
          ),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => _setReportDismissed(reportId, dismissed),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _pendingReports.remove(reportId));
    }
  }

  Future<void> _updateUser(String userId, {bool? premium, bool? banned}) async {
    try {
      await ref
          .read(surfRepositoryProvider)
          .updateAdminUserAccess(
            userId: userId,
            premium: premium,
            banned: banned,
          );
      ref.invalidate(adminUsersProvider);
      ref.invalidate(adminReportsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            banned == true
                ? 'Account banned.'
                : banned == false
                ? 'Account ban removed.'
                : premium == true
                ? 'Premium granted.'
                : 'Premium removed.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Bad state: ', '')),
        ),
      );
    }
  }

  Future<void> _confirmBan(String userId, String label) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Ban $label?'),
        content: const Text(
          'This immediately signs the account out and prevents it from signing in. You can reverse the ban later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB3261E),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Ban account'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _updateUser(userId, banned: true);
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(adminUsersProvider);
    final reports = ref.watch(adminReportsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('TYDES admin'),
        actions: [
          IconButton(
            tooltip: 'Refresh accounts',
            onPressed: () {
              ref.invalidate(adminUsersProvider);
              ref.invalidate(adminReportsProvider);
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: users.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _AdminError(
          message: error.toString().replaceFirst('Bad state: ', ''),
          onRetry: () => ref.invalidate(adminUsersProvider),
        ),
        data: (accounts) {
          final query = _query.trim().toLowerCase();
          final filtered = accounts.where((account) {
            if (query.isEmpty) return true;
            return account.email.toLowerCase().contains(query) ||
                account.displayName.toLowerCase().contains(query) ||
                account.handle.toLowerCase().contains(query);
          }).toList();
          final verified = accounts.where((user) => user.emailVerified).length;
          final premium = accounts.where((user) => user.premium).length;
          return RefreshIndicator.adaptive(
            onRefresh: () async {
              await Future.wait([
                ref.refresh(adminUsersProvider.future),
                ref.refresh(adminReportsProvider.future),
              ]);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                Text(
                  'Moderation',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Review reports and take action without exposing passwords.',
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Reports',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    reports.when(
                      data: (items) => Badge(
                        isLabelVisible: items.any((item) => !item.isDismissed),
                        label: Text(
                          '${items.where((item) => !item.isDismissed).length}',
                        ),
                        child: const Icon(Icons.flag_outlined),
                      ),
                      loading: () => const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      error: (_, _) => const Icon(Icons.error_outline),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Newest reports appear first. Dismissing a report does not remove its post or ban anyone.',
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      key: const ValueKey('report-filter-open'),
                      label: const Text('Active'),
                      selected: !_showDismissedReports,
                      onSelected: (_) =>
                          setState(() => _showDismissedReports = false),
                    ),
                    ChoiceChip(
                      key: const ValueKey('report-filter-dismissed'),
                      label: const Text('Dismissed'),
                      selected: _showDismissedReports,
                      onSelected: (_) =>
                          setState(() => _showDismissedReports = true),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                reports.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (error, _) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.error_outline),
                      title: const Text('Could not load reports'),
                      subtitle: Text(
                        error.toString().replaceFirst('Bad state: ', ''),
                      ),
                      trailing: IconButton(
                        tooltip: 'Retry',
                        onPressed: () => ref.invalidate(adminReportsProvider),
                        icon: const Icon(Icons.refresh),
                      ),
                    ),
                  ),
                  data: (items) {
                    final visibleReports = items
                        .where(
                          (report) =>
                              report.isDismissed == _showDismissedReports,
                        )
                        .toList();
                    return visibleReports.isEmpty
                        ? Card(
                            child: ListTile(
                              leading: const Icon(Icons.check_circle_outline),
                              title: Text(
                                _showDismissedReports
                                    ? 'No dismissed reports'
                                    : 'No active reports',
                              ),
                            ),
                          )
                        : Column(
                            children: visibleReports
                                .map(
                                  (report) => _ReportCard(
                                    key: ValueKey('report-card-${report.id}'),
                                    report: report,
                                    busy: _pendingReports.contains(report.id),
                                    onSetDismissed: () => _setReportDismissed(
                                      report.id,
                                      !report.isDismissed,
                                    ),
                                    onOpenTarget:
                                        report.targetType == 'post' &&
                                            report.targetAvailable
                                        ? () => context.push(
                                            '/post/${report.targetId}',
                                          )
                                        : null,
                                    onBanReporter: () => _confirmBan(
                                      report.reporterUserId,
                                      report.reporterHandle.isEmpty
                                          ? 'reporter'
                                          : '@${report.reporterHandle}',
                                    ),
                                    onBanReported: report.reportedUserId == null
                                        ? null
                                        : () => _confirmBan(
                                            report.reportedUserId!,
                                            report.reportedHandle.isEmpty
                                                ? 'reported account'
                                                : '@${report.reportedHandle}',
                                          ),
                                  ),
                                )
                                .toList(),
                          );
                  },
                ),
                const SizedBox(height: 26),
                Text(
                  'User accounts',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _Metric(label: 'Accounts', value: accounts.length),
                    _Metric(label: 'Verified', value: verified),
                    _Metric(label: 'Premium', value: premium),
                  ],
                ),
                const SizedBox(height: 18),
                TextField(
                  onChanged: (value) => setState(() => _query = value),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search email, name, or @handle',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${filtered.length} ${filtered.length == 1 ? 'account' : 'accounts'}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (filtered.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: Text('No matching accounts.')),
                  )
                else
                  ...filtered.map(
                    (account) => _AccountCard(
                      account: account,
                      onTogglePremium: () => _updateUser(
                        account.userId,
                        premium: !account.premium,
                      ),
                      onToggleBan: account.banned
                          ? () => _updateUser(account.userId, banned: false)
                          : () => _confirmBan(
                              account.userId,
                              account.handle.isEmpty
                                  ? account.email
                                  : '@${account.handle}',
                            ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({
    super.key,
    required this.report,
    required this.onOpenTarget,
    required this.onBanReporter,
    required this.onBanReported,
    required this.onSetDismissed,
    required this.busy,
  });

  final AdminReport report;
  final VoidCallback? onOpenTarget;
  final VoidCallback onBanReporter;
  final VoidCallback? onBanReported;
  final VoidCallback onSetDismissed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final created = report.createdAt?.toLocal();
    final dateLabel = created == null
        ? ''
        : '${created.year}-${created.month.toString().padLeft(2, '0')}-${created.day.toString().padLeft(2, '0')} '
              '${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')}';
    final reporter = report.reporterHandle.isEmpty
        ? (report.reporterDisplayName.isEmpty
              ? 'Unknown account'
              : report.reporterDisplayName)
        : '@${report.reporterHandle}';
    final reported = report.reportedHandle.isEmpty
        ? report.reportedDisplayName
        : '@${report.reportedHandle}';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(child: Icon(Icons.flag_outlined)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        report.reason.isEmpty
                            ? '${report.targetType} report'
                            : report.reason,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        'Reported by $reporter${reported.isEmpty ? '' : ' • Against $reported'}',
                      ),
                      if (dateLabel.isNotEmpty) Text(dateLabel),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: ValueKey('report-status-${report.id}'),
                  onPressed: busy ? null : onSetDismissed,
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          report.isDismissed
                              ? Icons.undo_rounded
                              : Icons.check_circle_outline,
                        ),
                  label: Text(
                    report.isDismissed ? 'Restore report' : 'Dismiss report',
                  ),
                ),
                if (onOpenTarget != null)
                  FilledButton.tonalIcon(
                    onPressed: onOpenTarget,
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('View post'),
                  ),
                OutlinedButton.icon(
                  onPressed: onBanReporter,
                  icon: const Icon(Icons.gavel_outlined),
                  label: Text('Ban $reporter'),
                ),
                if (onBanReported != null)
                  OutlinedButton.icon(
                    onPressed: onBanReported,
                    icon: const Icon(Icons.block_outlined),
                    label: Text(
                      reported.isEmpty ? 'Ban reported user' : 'Ban $reported',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 118),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    decoration: BoxDecoration(
      color: Theme.of(context).brightness == Brightness.dark
          ? Theme.of(context).colorScheme.surfaceContainerHigh
          : const Color(0xFFE4F7F5),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$value', style: Theme.of(context).textTheme.headlineSmall),
        Text(label),
      ],
    ),
  );
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.account,
    required this.onTogglePremium,
    required this.onToggleBan,
  });

  final AdminUserAccount account;
  final VoidCallback onTogglePremium;
  final VoidCallback onToggleBan;

  @override
  Widget build(BuildContext context) {
    final title = account.displayName.trim().isEmpty
        ? account.email.split('@').first
        : account.displayName;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  child: Text(title.isEmpty ? '?' : title[0].toUpperCase()),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(account.email),
                      if (account.handle.isNotEmpty) Text('@${account.handle}'),
                    ],
                  ),
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    if (account.emailVerified)
                      const Tooltip(
                        message: 'Email verified',
                        child: Icon(Icons.mark_email_read_outlined),
                      ),
                    if (account.premium)
                      const Tooltip(
                        message: 'Premium',
                        child: Icon(Icons.verified, color: Color(0xFF009FA5)),
                      ),
                    if (account.banned)
                      const Tooltip(
                        message: 'Banned',
                        child: Icon(Icons.block, color: Color(0xFFB3261E)),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: onTogglePremium,
                    icon: Icon(
                      account.premium
                          ? Icons.remove_moderator_outlined
                          : Icons.workspace_premium_outlined,
                    ),
                    label: Text(
                      account.premium ? 'Remove premium' : 'Give premium',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onToggleBan,
                    icon: Icon(
                      account.banned
                          ? Icons.lock_open_outlined
                          : Icons.block_outlined,
                    ),
                    label: Text(account.banned ? 'Unban' : 'Ban'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminError extends StatelessWidget {
  const _AdminError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 44),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}
